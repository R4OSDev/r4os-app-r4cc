pub const max_source_bytes: usize = 8192;
pub const max_code_bytes: usize = 4096;
pub const max_literal_bytes: usize = 512;

pub const CompileError = enum {
    MissingInclude,
    MissingTextMacro,
    MissingNamedTextMacro,
    BadTextMacro,
    TextLiteralTooLong,
    MissingMain,
    MissingWriteCall,
    MissingStdioLoop,
    MissingGuiInit,
    MissingGuiDrawCall,
    MissingGuiEventLoop,
    MissingOkButton,
    TextSymbolMismatch,
    CodeBufferTooSmall,
};

pub const CompileResult = struct {
    ok: bool,
    generation: u8 = 1,
    stdio: bool = false,
    code: []const u8 = "",
    text: []const u8 = "",
    detail: []const u8 = "",
    err: ?CompileError = null,
    line: u32 = 0,
};

const TextMacro = struct {
    name: []const u8,
    text: []const u8,
    line: u32,
};

const WriteCall = struct {
    name: []const u8,
    line_output: bool,
    line: u32,
};

pub fn errorMessage(err: CompileError) []const u8 {
    return switch (err) {
        .MissingInclude => "missing #include <r4os/r4os.h>",
        .MissingTextMacro => "missing R4OS_TEXT(name, \"literal\")",
        .MissingNamedTextMacro => "missing required R4OS_TEXT symbol",
        .BadTextMacro => "invalid R4OS_TEXT macro",
        .TextLiteralTooLong => "R4OS_TEXT literal is too long",
        .MissingMain => "missing int32_t r4_app_main with the selected App generation",
        .MissingWriteCall => "missing supported text output call",
        .MissingStdioLoop => "generation2 stdio requires the complete checked write loop",
        .MissingGuiInit => "missing R4DESK/R4DRAW init calls",
        .MissingGuiDrawCall => "missing supported R4DESK/R4DRAW GUI calls",
        .MissingGuiEventLoop => "missing supported GUI event loop",
        .MissingOkButton => "missing OK button close path",
        .TextSymbolMismatch => "write call must use the R4OS_TEXT symbol",
        .CodeBufferTooSmall => "generated code buffer is too small",
    };
}

pub fn compileConsole(source_raw: []const u8, code_out: []u8, literal_out: []u8) CompileResult {
    return compileConsoleGeneration(1, source_raw, code_out, literal_out);
}

pub fn compileConsole2(source_raw: []const u8, code_out: []u8, literal_out: []u8) CompileResult {
    return compileConsoleGeneration(2, source_raw, code_out, literal_out);
}

fn compileConsoleGeneration(comptime generation: u8, source_raw: []const u8, code_out: []u8, literal_out: []u8) CompileResult {
    const source = stripUtf8Bom(source_raw);
    if (indexOf(source, "#include <r4os/r4os.h>") == null) {
        return fail(.MissingInclude, lineOf(source, 0));
    }
    if (!hasAppMainShape(generation, source)) return fail(.MissingMain, lineOf(source, 0));

    const macro = parseTextMacro(source, literal_out) orelse {
        if (indexOf(source, "R4OS_TEXT") == null) return fail(.MissingTextMacro, lineOf(source, 0));
        return fail(.BadTextMacro, lineOf(source, indexOf(source, "R4OS_TEXT") orelse 0));
    };
    if (generation == 2 and indexOf(source, "R4SdkStdioWrite") != null) {
        const call = parseStdioCall(source) orelse return fail(.MissingWriteCall, lineOf(source, 0));
        if (!equals(macro.name, call.name)) return fail(.TextSymbolMismatch, call.line);
        if (indexOf(source, "R4SdkStdio2") == null or indexOf(source, "progress.bytes") == null or
            indexOf(source, "R4OS_BYTE_PIPE_WOULD_BLOCK") == null or indexOf(source, "r4_app2_should_close") == null or
            indexOf(source, "r4sys_sleep_ticks") == null) return fail(.MissingStdioLoop, call.line);
        const code = emitStdioConsole2(code_out, macro.text) orelse return fail(.CodeBufferTooSmall, macro.line);
        return .{ .ok = true, .generation = 2, .stdio = true, .code = code, .text = macro.text };
    }
    const call = parseWriteCall(source) orelse return fail(.MissingWriteCall, lineOf(source, 0));
    if (!equals(macro.name, call.name)) return fail(.TextSymbolMismatch, call.line);

    const code = emitConsoleCode(generation, code_out, macro.text, call.line_output) orelse return fail(.CodeBufferTooSmall, macro.line);
    return .{ .ok = true, .generation = generation, .code = code, .text = macro.text };
}

pub fn compileDesktopOk(source_raw: []const u8, code_out: []u8, literal_out: []u8) CompileResult {
    return compileDesktopGeneration(1, source_raw, code_out, literal_out);
}

pub fn compileDesktopOk2(source_raw: []const u8, code_out: []u8, literal_out: []u8) CompileResult {
    return compileDesktopGeneration(2, source_raw, code_out, literal_out);
}

fn compileDesktopGeneration(comptime generation: u8, source_raw: []const u8, code_out: []u8, literal_out: []u8) CompileResult {
    const source = stripUtf8Bom(source_raw);
    if (indexOf(source, "#include <r4os/r4os.h>") == null) {
        return fail(.MissingInclude, lineOf(source, 0));
    }
    if (!hasAppMainShape(generation, source)) return fail(.MissingMain, lineOf(source, 0));
    if (literal_out.len < 3 * max_literal_bytes / 4) return fail(.TextLiteralTooLong, lineOf(source, 0));

    const title_buffer = literal_out[0..160];
    const ok_buffer = literal_out[160..224];
    const message_buffer = literal_out[224..literal_out.len];
    const title = parseNamedTextMacro(source, "window_title", title_buffer) orelse return fail(.MissingNamedTextMacro, lineOf(source, 0));
    const ok_label = parseNamedTextMacro(source, "ok_label", ok_buffer) orelse return fail(.MissingNamedTextMacro, lineOf(source, 0));
    const message = parseNamedTextMacro(source, "message", message_buffer) orelse return fail(.MissingNamedTextMacro, lineOf(source, 0));

    if (indexOf(source, "r4_window_open") == null) {
        return fail(.MissingGuiInit, lineOf(source, 0));
    }
    if (indexOf(source, "r4_window_set_title") == null or
        indexOf(source, "r4_window_begin_paint") == null or
        indexOf(source, "r4_canvas_clear") == null or
        indexOf(source, "r4_canvas_rect") == null or
        indexOf(source, "r4_canvas_text") == null or
        indexOf(source, "r4_paint_present") == null)
    {
        return fail(.MissingGuiDrawCall, lineOf(source, 0));
    }
    if (indexOf(source, "r4_window_wait_message") == null or
        indexOf(source, "r4_timeout_forever") == null)
    {
        return fail(.MissingGuiEventLoop, lineOf(source, 0));
    }
    if (indexOf(source, "R4_MESSAGE_MOUSE") == null or indexOf(source, "R4_MOUSE_UP") == null or indexOf(source, "ok_label") == null) {
        return fail(.MissingOkButton, lineOf(source, 0));
    }

    const code = emitDesktopOkCode(generation, code_out, title.text, ok_label.text, message.text) orelse return fail(.CodeBufferTooSmall, title.line);
    return .{ .ok = true, .generation = generation, .code = code, .text = message.text, .detail = if (generation == 2) "R4X_C_App2_Desktop" else "R4X_C_App_Desktop" };
}

fn fail(err: CompileError, line: u32) CompileResult {
    return .{ .ok = false, .err = err, .line = line };
}

fn hasAppMainShape(comptime generation: u8, source: []const u8) bool {
    return indexOf(source, "int32_t") != null and
        indexOf(source, "r4_app_main") != null and
        indexOf(source, if (generation == 2) "R4App2" else "R4App") != null;
}

fn parseTextMacro(source: []const u8, literal_out: []u8) ?TextMacro {
    const macro_pos = indexOf(source, "R4OS_TEXT") orelse return null;
    return parseTextMacroAt(source, macro_pos, literal_out);
}

fn parseNamedTextMacro(source: []const u8, expected_name: []const u8, literal_out: []u8) ?TextMacro {
    var start: usize = 0;
    while (start < source.len) {
        const rel = indexOf(source[start..], "R4OS_TEXT") orelse return null;
        const macro_pos = start + rel;
        if (parseTextMacroAt(source, macro_pos, literal_out)) |macro| {
            if (equals(macro.name, expected_name)) return macro;
        }
        start = macro_pos + "R4OS_TEXT".len;
    }
    return null;
}

fn parseTextMacroAt(source: []const u8, macro_pos: usize, literal_out: []u8) ?TextMacro {
    var i = macro_pos + "R4OS_TEXT".len;
    i = skipSpaces(source, i);
    if (i >= source.len or source[i] != '(') return null;
    i += 1;
    i = skipSpaces(source, i);
    const name_start = i;
    if (i >= source.len or !isIdentStart(source[i])) return null;
    while (i < source.len and isIdent(source[i])) : (i += 1) {}
    const name = source[name_start..i];
    i = skipSpaces(source, i);
    if (i >= source.len or source[i] != ',') return null;
    i += 1;
    i = skipSpaces(source, i);
    if (i >= source.len or source[i] != '"') return null;
    i += 1;

    var literal_len: usize = 0;
    while (i < source.len) : (i += 1) {
        const ch = source[i];
        if (ch == '"') {
            const text = literal_out[0..literal_len];
            i += 1;
            i = skipSpaces(source, i);
            if (i >= source.len or source[i] != ')') return null;
            return .{ .name = name, .text = text, .line = lineOf(source, macro_pos) };
        }
        var out_ch = ch;
        if (ch == '\\') {
            i += 1;
            if (i >= source.len) return null;
            out_ch = switch (source[i]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '"' => '"',
                '\\' => '\\',
                else => return null,
            };
        }
        if (literal_len >= literal_out.len) return null;
        literal_out[literal_len] = out_ch;
        literal_len += 1;
    }
    return null;
}

fn parseWriteCall(source: []const u8) ?WriteCall {
    if (parseNamedWriteCall(source, "r4sys_write_line", true)) |call| return call;
    if (parseNamedWriteCall(source, "r4sys_write_cstr", false)) |call| return call;
    return null;
}

fn parseStdioCall(source: []const u8) ?WriteCall {
    const call = indexOf(source, "R4SdkStdioWrite") orelse return null;
    var cursor = call + "R4SdkStdioWrite".len;
    for ([_][]const u8{ "(", "&", "io", ",", "1", ",", "(", "const", "uint8_t", "*", ")" }) |token| {
        cursor = skipSpaces(source, cursor);
        if (!startsWith(source[cursor..], token)) return null;
        cursor += token.len;
    }
    cursor = skipSpaces(source, cursor);
    const start = cursor;
    if (cursor >= source.len or !isIdentStart(source[cursor])) return null;
    while (cursor < source.len and isIdent(source[cursor])) : (cursor += 1) {}
    return .{ .name = source[start..cursor], .line_output = false, .line = lineOf(source, call) };
}

fn parseNamedWriteCall(source: []const u8, function_name: []const u8, line_output: bool) ?WriteCall {
    const call_pos = indexOf(source, function_name) orelse return null;
    var i = call_pos + function_name.len;
    i = skipSpaces(source, i);
    if (i >= source.len or source[i] != '(') return null;
    i += 1;
    i = skipSpaces(source, i);
    if (startsWith(source[i..], "&app->system")) {
        i += "&app->system".len;
    } else {
        return null;
    }
    i = skipSpaces(source, i);
    if (i >= source.len or source[i] != ',') return null;
    i += 1;
    i = skipSpaces(source, i);
    const name_start = i;
    if (i >= source.len or !isIdentStart(source[i])) return null;
    while (i < source.len and isIdent(source[i])) : (i += 1) {}
    return .{ .name = source[name_start..i], .line_output = line_output, .line = lineOf(source, call_pos) };
}

fn emitConsoleCode(comptime generation: u8, out: []u8, text: []const u8, line_output: bool) ?[]const u8 {
    var e = Emitter{ .out = out };

    e.codeBytes(&.{ 0x55, 0x48, 0x89, 0xE5, 0x53, 0x48, 0x83, 0xEC, 0x08 });
    e.codeBytes(&.{ 0x48, 0x85, 0xFF });
    const jz_null = e.jcc(0x84);
    e.codeBytes(&.{ 0x81, 0x3F });
    e.emitU32(if (generation == 2) @import("r4os").platform2.abi.start_magic else 0x53583452);
    const jne_magic = e.jcc(0x85);
    e.codeBytes(&.{ 0x66, 0x83, 0x7F, 0x04 });
    e.byte(generation);
    const jne_abi = e.jcc(0x85);
    e.codeBytes(&.{ 0x81, 0x7F, 0x08 });
    e.emitU32(if (generation == 2) @sizeOf(@import("r4os").platform2.abi.R4XStartContext2) else 128);
    const jb_size = e.jcc(0x82);
    e.codeBytes(&.{ 0xF7, 0x47, 0x0C, 0x01, 0x00, 0x00, 0x00 });
    const jz_import_flag = e.jcc(0x84);
    e.codeBytes(&.{ 0x4C, 0x8B, 0x4F, 0x38, 0x8B, 0x4F, 0x40, 0x4D, 0x85, 0xC9 });
    const jz_import_ptr = e.jcc(0x84);
    e.codeBytes(&.{ 0x85, 0xC9 });
    const jz_import_count = e.jcc(0x84);

    const loop_label = e.pos();
    e.codeBytes(&.{ 0x41, 0x83, 0x39, 0x01 });
    const jne_next_group = e.jcc(0x85);
    const jne_next_version: ?usize = if (generation == 2) version: {
        e.codeBytes(&.{ 0x41, 0x83, 0x79, 0x04, 0x02 });
        break :version e.jcc(0x85);
    } else null;
    e.codeBytes(&.{ 0x41, 0xF7, 0x41, 0x0C, 0x01, 0x00, 0x00, 0x00 });
    const jz_next_flags = e.jcc(0x84);
    e.codeBytes(&.{ 0x49, 0x8B, 0x59, 0x20, 0x48, 0x85, 0xDB });
    const jz_next_table = e.jcc(0x84);
    const jmp_found = e.jmp();

    const next_label = e.pos();
    e.codeBytes(&.{ 0x49, 0x83, 0xC1, 0x28, 0xFF, 0xC9 });
    const jnz_loop = e.jcc(0x85);
    const jmp_no_import = e.jmp();

    const found_label = e.pos();
    e.codeBytes(&.{ 0x81, 0x3B });
    e.emitU32(if (generation == 2) (@import("r4os").platform2.abi.R4XStartR4Sys2{}).magic else 0x31595352);
    const jne_table_magic = e.jcc(0x85);
    e.codeBytes(&.{ 0x83, 0x7B, 0x04 });
    e.byte(if (generation == 2) 1 else 2);
    const jb_table_version = e.jcc(0x82);
    e.codeBytes(&.{ 0x81, 0x7B, 0x08 });
    e.emitU32(if (generation == 2) @offsetOf(@import("r4os").platform2.abi.R4XStartR4Sys2, "putc") + 8 else 224);
    const jb_table_size = e.jcc(0x82);
    e.codeBytes(&.{ 0x48, 0x8B, 0x43, 0x10, 0x48, 0x85, 0xC0 });
    const jz_write = e.jcc(0x84);
    e.codeBytes(&.{ 0x48, 0x8D, 0x3D });
    const lea_disp = e.reserve(4);
    e.codeBytes(&.{0xBE});
    e.emitU32(@intCast(text.len));
    e.codeBytes(&.{ 0xFF, 0xD0, 0x85, 0xC0 });
    const js_write_failed = e.jcc(0x88);
    if (line_output) {
        e.codeBytes(&.{ 0x48, 0x8B, 0x43, 0x18, 0x48, 0x85, 0xC0 });
        const jz_putc_cr = e.jcc(0x84);
        e.codeBytes(&.{ 0xBF, 0x0D, 0x00, 0x00, 0x00, 0xFF, 0xD0 });
        e.codeBytes(&.{ 0x48, 0x8B, 0x43, 0x18, 0x48, 0x85, 0xC0 });
        const jz_putc_lf = e.jcc(0x84);
        e.codeBytes(&.{ 0xBF, 0x0A, 0x00, 0x00, 0x00, 0xFF, 0xD0 });
        const success_after_putc = e.pos();
        e.patch(jz_putc_cr, success_after_putc);
        e.patch(jz_putc_lf, success_after_putc);
    }
    e.codeBytes(&.{ 0x31, 0xC0 });
    const jmp_success = e.jmp();

    const fail51 = e.pos();
    e.codeBytes(&.{ 0xB8, 0x33, 0x00, 0x00, 0x00 });
    const jmp_fail51 = e.jmp();

    const fail52 = e.pos();
    e.codeBytes(&.{ 0xB8, 0x34, 0x00, 0x00, 0x00 });

    const epilogue = e.pos();
    e.codeBytes(&.{ 0x48, 0x83, 0xC4, 0x08, 0x5B, 0x5D, 0xC3 });

    const string_pos = e.pos();
    e.bytes(text);
    e.byte(0);

    if (!e.ok) return null;

    e.patch(jz_null, fail51);
    e.patch(jne_magic, fail51);
    e.patch(jne_abi, fail51);
    e.patch(jb_size, fail51);
    e.patch(jz_import_flag, fail52);
    e.patch(jz_import_ptr, fail52);
    e.patch(jz_import_count, fail52);
    e.patch(jne_next_group, next_label);
    if (jne_next_version) |patch| e.patch(patch, next_label);
    e.patch(jz_next_flags, next_label);
    e.patch(jz_next_table, next_label);
    e.patch(jmp_found, found_label);
    e.patch(jnz_loop, loop_label);
    e.patch(jmp_no_import, fail52);
    e.patch(jne_table_magic, fail52);
    e.patch(jb_table_version, fail52);
    e.patch(jb_table_size, fail52);
    e.patch(jz_write, fail52);
    e.patch(js_write_failed, epilogue);
    e.patch(jmp_success, epilogue);
    e.patch(jmp_fail51, epilogue);
    e.patchI32(lea_disp, @as(i64, @intCast(string_pos)) - @as(i64, @intCast(lea_disp + 4)));
    if (!e.ok) return null;
    return out[0..e.len];
}

fn emitStdioConsole2(out: []u8, text: []const u8) ?[]const u8 {
    const r = @import("r4os");
    const a = r.abi;
    const p = r.platform2.abi;
    const snapshot: u32 = (@sizeOf(a.BytePipeEnd) + 15) & ~@as(u32, 15);
    const deadline: u32 = snapshot + @sizeOf(a.LaunchIo);
    const progress: u32 = deadline + @sizeOf(a.WaitSetDeadline);
    const frame_bytes: u32 = ((progress + @sizeOf(a.BytePipeProgress) + 15) & ~@as(u32, 15)) + 8;
    const binding = snapshot + @offsetOf(a.LaunchIo, "stdout_binding");
    const pipe_end = binding + @offsetOf(a.LaunchIoBinding, "end");
    var e = Emitter{ .out = out };
    var invalid_context: [8]usize = undefined;
    var context_count: usize = 0;
    var invalid_provider: [48]usize = undefined;
    var provider_count: usize = 0;
    var success: [8]usize = undefined;
    var success_count: usize = 0;
    var api_failure: [8]usize = undefined;
    var api_count: usize = 0;

    // The outgoing24-byte by-value pipe end occupies the first stack32bytes.
    // The remaining locals hold the copied stdio snapshot and private records.
    e.codeBytes(&.{ 0x55, 0x48, 0x89, 0xE5, 0x53, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57, 0x48, 0x81, 0xEC });
    e.emitU32(frame_bytes);
    e.codeBytes(&.{ 0x49, 0x89, 0xFD, 0x49, 0x89, 0xFF, 0x48, 0x85, 0xFF });
    notePatchJcc(&e, &invalid_context, &context_count, 0x84);
    e.codeBytes(&.{ 0x81, 0x3F });
    e.emitU32(p.start_magic);
    notePatchJcc(&e, &invalid_context, &context_count, 0x85);
    e.codeBytes(&.{ 0x66, 0x83, 0x7F, 0x04, 0x02 });
    notePatchJcc(&e, &invalid_context, &context_count, 0x85);
    e.codeBytes(&.{ 0x81, 0x7F, 0x08 });
    e.emitU32(@sizeOf(p.R4XStartContext2));
    notePatchJcc(&e, &invalid_context, &context_count, 0x82);
    e.codeBytes(&.{ 0xF7, 0x47, 0x0C, 0x01, 0x00, 0x00, 0x00 });
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x84);
    emitFindImportInto(2, &e, 1, .rbx, &invalid_provider, &provider_count);
    emitFindImportInto(2, &e, 2, .r12, &invalid_provider, &provider_count);

    e.codeBytes(&.{ 0x81, 0x3B });
    e.emitU32((p.R4XStartR4Sys2{}).magic);
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x85);
    e.codeBytes(&.{ 0x83, 0x7B, 0x04, 0x01 });
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x82);
    e.codeBytes(&.{ 0x81, 0x7B, 0x08 });
    e.emitU32(@offsetOf(p.R4XStartR4Sys2, "program_stdio") + 8);
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x82);
    e.codeBytes(&.{ 0x41, 0x81, 0x3C, 0x24 });
    e.emitU32((p.R4XStartR4Desk2{}).magic);
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x85);
    e.codeBytes(&.{ 0x41, 0x83, 0x7C, 0x24, 0x04, 0x01 });
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x82);
    e.codeBytes(&.{ 0x41, 0x81, 0x7C, 0x24, 0x08 });
    e.emitU32(@offsetOf(p.R4XStartR4Desk2, "console_write") + 8);
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x82);

    e.codeBytes(&.{ 0x31, 0xC0 });
    for (0..(@sizeOf(a.LaunchIo) + @sizeOf(a.WaitSetDeadline) + @sizeOf(a.BytePipeProgress)) / 8) |index| e.storeStackRax(snapshot + @as(u32, @intCast(index * 8)));
    e.codeBytes(&.{0xB8});
    e.emitU32(1);
    e.storeStackRax(deadline);
    e.codeBytes(&.{0xB8});
    e.emitU32(@sizeOf(a.WaitSetDeadline));
    e.storeStackRax(deadline + 4);
    emitRaxFromRbx(&e, @offsetOf(p.R4XStartR4Sys2, "program_stdio"));
    e.codeBytes(&.{ 0x48, 0x85, 0xC0 });
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x84);
    e.codeBytes(&.{ 0x48, 0x8D, 0xBC, 0x24 });
    e.emitU32(snapshot);
    e.codeBytes(&.{ 0xFF, 0xD0, 0x85, 0xC0 });
    notePatchJcc(&e, &api_failure, &api_count, 0x85);
    e.compareStack32(snapshot, 1);
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x85);
    e.compareStack32(snapshot + 4, @sizeOf(a.LaunchIo));
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x85);
    e.compareStack32(binding + @offsetOf(a.LaunchIoBinding, "reserved"), 0);
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x85);
    e.compareStack32(binding, a.launch_io_pipe);
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x87);
    e.codeBytes(&.{ 0x4C, 0x8D, 0x2D });
    const text_reference = e.reserve(4);
    e.codeBytes(&.{ 0x41, 0xBE });
    e.emitU32(@intCast(text.len));

    const loop = e.pos();
    e.codeBytes(&.{ 0x4D, 0x85, 0xF6 });
    notePatchJcc(&e, &success, &success_count, 0x84);
    e.codeBytes(&.{ 0x41, 0xF7, 0x47, 0x0C, 0x04, 0x00, 0x00, 0x00 });
    const no_close_flag = e.jcc(0x84);
    e.codeBytes(&.{ 0x49, 0x8B, 0x47, 0x60, 0x48, 0x85, 0xC0 });
    const no_close_callback = e.jcc(0x84);
    e.codeBytes(&.{ 0x4C, 0x89, 0xFF, 0xFF, 0xD0, 0x85, 0xC0 });
    notePatchJcc(&e, &success, &success_count, 0x85);
    const select = e.pos();
    e.patch(no_close_flag, select);
    e.patch(no_close_callback, select);
    e.compareStack32(binding, a.launch_io_pipe);
    const pipe = e.jcc(0x84);

    // Default console writes retain the public synchronous handoff count.
    emitRaxFromR12(&e, @offsetOf(p.R4XStartR4Desk2, "console_write"));
    e.codeBytes(&.{ 0x48, 0x85, 0xC0 });
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x84);
    emitMovEdi(&e, 1);
    e.codeBytes(&.{ 0x4C, 0x89, 0xEE, 0x4C, 0x89, 0xF2, 0xFF, 0xD0, 0x85, 0xC0 });
    notePatchJcc(&e, &api_failure, &api_count, 0x88);
    e.codeBytes(&.{ 0x89, 0xC0, 0x4C, 0x39, 0xF0 });
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x87);
    e.codeBytes(&.{ 0x48, 0x85, 0xC0 });
    const console_blocked = e.jcc(0x84);
    const console_progress = e.jmp();

    e.patch(pipe, e.pos());
    for (0..@sizeOf(a.BytePipeEnd) / 8) |index| {
        e.loadStackRax(pipe_end + @as(u32, @intCast(index * 8)));
        e.storeStackRax(@intCast(index * 8));
    }
    e.codeBytes(&.{ 0x31, 0xC0 });
    for (0..@sizeOf(a.BytePipeProgress) / 8) |index| e.storeStackRax(progress + @as(u32, @intCast(index * 8)));
    e.codeBytes(&.{0xB8});
    e.emitU32(1);
    e.storeStackRax(progress);
    e.codeBytes(&.{0xB8});
    e.emitU32(@sizeOf(a.BytePipeProgress));
    e.storeStackRax(progress + 4);
    emitRaxFromRbx(&e, @offsetOf(p.R4XStartR4Sys2, "byte_pipe_write"));
    e.codeBytes(&.{ 0x48, 0x85, 0xC0 });
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x84);
    e.codeBytes(&.{ 0x4C, 0x89, 0xEF, 0x4C, 0x89, 0xF6, 0x48, 0x8D, 0x94, 0x24 });
    e.emitU32(deadline);
    e.codeBytes(&.{ 0x48, 0x8D, 0x8C, 0x24 });
    e.emitU32(progress);
    e.codeBytes(&.{ 0xFF, 0xD0, 0x85, 0xC0 });
    notePatchJcc(&e, &api_failure, &api_count, 0x85);
    e.compareStack32(progress, 1);
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x85);
    e.compareStack32(progress + 4, @sizeOf(a.BytePipeProgress));
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x85);
    e.compareStack32(progress + @offsetOf(a.BytePipeProgress, "flags"), 0);
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x85);
    e.loadStackRax(progress + @offsetOf(a.BytePipeProgress, "bytes"));
    e.codeBytes(&.{ 0x4C, 0x39, 0xF0 });
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x87);
    e.compareStack32(progress + @offsetOf(a.BytePipeProgress, "state"), a.byte_pipe_ready);
    const ready = e.jcc(0x84);
    e.compareStack32(progress + @offsetOf(a.BytePipeProgress, "state"), a.byte_pipe_would_block);
    const io_failure = e.jcc(0x85);
    e.codeBytes(&.{ 0x48, 0x85, 0xC0 });
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x85);
    const pipe_blocked = e.jmp();

    e.patch(ready, e.pos());
    e.codeBytes(&.{ 0x48, 0x85, 0xC0 });
    const empty_ready = e.jcc(0x84);
    e.patch(console_progress, e.pos());
    e.codeBytes(&.{ 0x49, 0x01, 0xC5, 0x49, 0x29, 0xC6 });
    const advanced = e.jmp();
    e.patch(advanced, loop);
    const blocked = e.pos();
    e.patch(console_blocked, blocked);
    e.patch(pipe_blocked, blocked);
    e.patch(empty_ready, blocked);
    emitRaxFromRbx(&e, @offsetOf(p.R4XStartR4Sys2, "sleep_ticks"));
    e.codeBytes(&.{ 0x48, 0x85, 0xC0 });
    notePatchJcc(&e, &invalid_provider, &provider_count, 0x84);
    emitMovEdi(&e, 1);
    e.codeBytes(&.{ 0xFF, 0xD0 });
    const slept = e.jmp();
    e.patch(slept, loop);

    const success_label = e.pos();
    e.codeBytes(&.{ 0x31, 0xC0 });
    const successful_return = e.jmp();
    const invalid_context_label = e.pos();
    emitMovEax(&e, 51);
    const context_return = e.jmp();
    const invalid_provider_label = e.pos();
    emitMovEax(&e, 52);
    const provider_return = e.jmp();
    const io_failure_label = e.pos();
    emitMovEax(&e, 1);
    const epilogue = e.pos();
    e.codeBytes(&.{ 0x48, 0x81, 0xC4 });
    e.emitU32(frame_bytes);
    e.codeBytes(&.{ 0x41, 0x5F, 0x41, 0x5E, 0x41, 0x5D, 0x41, 0x5C, 0x5B, 0x5D, 0xC3 });
    const text_position = e.pos();
    e.bytes(text);
    e.byte(0);
    patchList(&e, invalid_context[0..context_count], invalid_context_label);
    patchList(&e, invalid_provider[0..provider_count], invalid_provider_label);
    patchList(&e, success[0..success_count], success_label);
    patchList(&e, api_failure[0..api_count], epilogue);
    e.patch(io_failure, io_failure_label);
    e.patch(successful_return, epilogue);
    e.patch(context_return, epilogue);
    e.patch(provider_return, epilogue);
    e.patchI32(text_reference, @as(i64, @intCast(text_position)) - @as(i64, @intCast(text_reference + 4)));
    return if (e.ok) out[0..e.len] else null;
}

fn emitRaxFromRbx(e: *Emitter, offset: u32) void {
    e.codeBytes(&.{ 0x48, 0x8B, 0x83 });
    e.emitU32(offset);
}
fn emitMovEax(e: *Emitter, value: u32) void {
    e.byte(0xB8);
    e.emitU32(value);
}

fn emitDesktopOkCode(comptime generation: u8, out: []u8, title: []const u8, ok_label: []const u8, message: []const u8) ?[]const u8 {
    var e = Emitter{ .out = out };
    var fail51_patches: [8]usize = undefined;
    var fail51_count: usize = 0;
    var fail52_patches: [32]usize = undefined;
    var fail52_count: usize = 0;
    var fail63_patches: [4]usize = undefined;
    var fail63_count: usize = 0;
    var success_patches: [8]usize = undefined;
    var success_count: usize = 0;

    e.codeBytes(&.{ 0x55, 0x48, 0x89, 0xE5, 0x53, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x48, 0x83, 0xEC, 0x40 });
    e.codeBytes(&.{ 0x49, 0x89, 0xFD });
    e.codeBytes(&.{ 0x48, 0x85, 0xFF });
    notePatchJcc(&e, fail51_patches[0..], &fail51_count, 0x84);
    e.codeBytes(&.{ 0x41, 0x81, 0x7D, 0x00 });
    e.emitU32(if (generation == 2) @import("r4os").platform2.abi.start_magic else 0x53583452);
    notePatchJcc(&e, fail51_patches[0..], &fail51_count, 0x85);
    e.codeBytes(&.{ 0x66, 0x41, 0x83, 0x7D, 0x04 });
    e.byte(generation);
    notePatchJcc(&e, fail51_patches[0..], &fail51_count, 0x85);
    e.codeBytes(&.{ 0x41, 0x81, 0x7D, 0x08 });
    e.emitU32(if (generation == 2) @sizeOf(@import("r4os").platform2.abi.R4XStartContext2) else 128);
    notePatchJcc(&e, fail51_patches[0..], &fail51_count, 0x82);
    e.codeBytes(&.{ 0x41, 0xF7, 0x45, 0x0C, 0x01, 0x00, 0x00, 0x00 });
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x84);

    emitFindImportInto(generation, &e, 1, .rbx, fail52_patches[0..], &fail52_count);
    e.codeBytes(&.{ 0x81, 0x3B });
    e.emitU32(if (generation == 2) (@import("r4os").platform2.abi.R4XStartR4Sys2{}).magic else 0x31595352);
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x85);
    e.codeBytes(&.{ 0x83, 0x7B, 0x04 });
    e.byte(if (generation == 2) 1 else 2);
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x82);
    e.codeBytes(&.{ 0x81, 0x7B, 0x08 });
    e.emitU32(if (generation == 2) @offsetOf(@import("r4os").platform2.abi.R4XStartR4Sys2, "program_should_close") + 8 else 224);
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x82);

    emitFindImportInto(generation, &e, 2, .r12, fail52_patches[0..], &fail52_count);
    e.codeBytes(&.{ 0x41, 0x81, 0x3C, 0x24 });
    e.emitU32(if (generation == 2) (@import("r4os").platform2.abi.R4XStartR4Desk2{}).magic else 0x31454452);
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x85);
    e.codeBytes(&.{ 0x41, 0x83, 0x7C, 0x24, 0x04, 0x01 });
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x82);
    e.codeBytes(&.{ 0x41, 0x81, 0x7C, 0x24, 0x08 });
    e.emitU32(if (generation == 2) @offsetOf(@import("r4os").platform2.abi.R4XStartR4Desk2, "desktop_activity_wait") + 8 else 384);
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x82);
    emitRaxFromR12(&e, if (generation == 2) @offsetOf(@import("r4os").platform2.abi.R4XStartR4Desk2, "program_window_id") else 104);
    e.codeBytes(&.{ 0x48, 0x85, 0xC0 });
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x84);
    emitRaxFromR12(&e, if (generation == 2) @offsetOf(@import("r4os").platform2.abi.R4XStartR4Desk2, "gui_poll_event") else 128);
    e.codeBytes(&.{ 0x48, 0x85, 0xC0 });
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x84);
    emitRaxFromR12(&e, if (generation == 2) @offsetOf(@import("r4os").platform2.abi.R4XStartR4Desk2, "desktop_activity_wait") else 376);
    e.codeBytes(&.{ 0x48, 0x85, 0xC0 });
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x84);

    emitFindImportInto(generation, &e, 3, .r14, fail52_patches[0..], &fail52_count);
    e.codeBytes(&.{ 0x41, 0x81, 0x3E });
    e.emitU32(if (generation == 2) (@import("r4os").platform2.abi.R4XStartR4Draw2{}).magic else 0x31574452);
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x85);
    e.codeBytes(&.{ 0x41, 0x83, 0x7E, 0x04, 0x01 });
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x82);
    e.codeBytes(&.{ 0x41, 0x81, 0x7E, 0x08 });
    e.emitU32(if (generation == 2) @offsetOf(@import("r4os").platform2.abi.R4XStartR4Draw2, "gui_present") + 8 else 216);
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x82);
    emitRaxFromR14(&e, if (generation == 2) @offsetOf(@import("r4os").platform2.abi.R4XStartR4Draw2, "gui_clear") else 96);
    e.codeBytes(&.{ 0x48, 0x85, 0xC0 });
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x84);
    emitRaxFromR14(&e, if (generation == 2) @offsetOf(@import("r4os").platform2.abi.R4XStartR4Draw2, "gui_rect") else 104);
    e.codeBytes(&.{ 0x48, 0x85, 0xC0 });
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x84);
    emitRaxFromR14(&e, if (generation == 2) @offsetOf(@import("r4os").platform2.abi.R4XStartR4Draw2, "gui_draw_text") else 112);
    e.codeBytes(&.{ 0x48, 0x85, 0xC0 });
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x84);
    emitRaxFromR14(&e, if (generation == 2) @offsetOf(@import("r4os").platform2.abi.R4XStartR4Draw2, "gui_present") else 144);
    e.codeBytes(&.{ 0x48, 0x85, 0xC0 });
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x84);

    emitRaxFromR12(&e, if (generation == 2) @offsetOf(@import("r4os").platform2.abi.R4XStartR4Desk2, "program_window_id") else 104);
    e.codeBytes(&.{ 0xFF, 0xD0, 0x85, 0xC0 });
    notePatchJcc(&e, fail63_patches[0..], &fail63_count, 0x8C);

    emitRaxFromR12(&e, if (generation == 2) @offsetOf(@import("r4os").platform2.abi.R4XStartR4Desk2, "gui_set_title") else 176);
    e.codeBytes(&.{ 0x48, 0x8D, 0x3D });
    const title_ref = e.reserve(4);
    e.codeBytes(&.{ 0xFF, 0xD0 });
    emitRaxFromR12(&e, if (generation == 2) @offsetOf(@import("r4os").platform2.abi.R4XStartR4Desk2, "gui_set_min_size") else 192);
    e.codeBytes(&.{ 0xBF, 0x04, 0x01, 0x00, 0x00, 0xBE, 0x8C, 0x00, 0x00, 0x00, 0xFF, 0xD0 });

    emitGuiClear(&e, 0x00C0C0C0);
    emitGuiRect(&e, 44, 36, 172, 72, 0x00808080);
    emitGuiRect(&e, 45, 37, 170, 70, 0x00FFFFFF);
    emitGuiRect(&e, 46, 38, 168, 68, 0x00FFFFFF);
    emitGuiRect(&e, 84, 78, 72, 24, 0x00808080);
    emitGuiRect(&e, 84, 78, 71, 23, 0x00FFFFFF);
    emitGuiRect(&e, 86, 80, 68, 21, 0x00C0C0C0);
    const message_ref = emitGuiText(&e, 58, 50, 0x000000, 0x00FFFFFF);
    const ok_ref = emitGuiText(&e, 112, 86, 0x000000, 0x00C0C0C0);
    emitRaxFromR14(&e, if (generation == 2) @offsetOf(@import("r4os").platform2.abi.R4XStartR4Draw2, "gui_present") else 144);
    e.codeBytes(&.{ 0xFF, 0xD0 });

    e.codeBytes(&.{ 0x48, 0xC7, 0x45, 0xA8, 0x00, 0x00, 0x00, 0x00 });
    const loop_label = e.pos();
    e.codeBytes(&.{ 0x41, 0xF7, 0x45, 0x0C, 0x04, 0x00, 0x00, 0x00 });
    const no_ctx_close_flag = e.jcc(0x84);
    e.codeBytes(&.{ 0x49, 0x8B, 0x45, 0x60, 0x48, 0x85, 0xC0 });
    const no_ctx_close_ptr = e.jcc(0x84);
    e.codeBytes(&.{ 0x4C, 0x89, 0xEF, 0xFF, 0xD0, 0x85, 0xC0 });
    notePatchJcc(&e, success_patches[0..], &success_count, 0x85);
    const table_close = e.pos();
    e.patch(no_ctx_close_flag, table_close);
    e.patch(no_ctx_close_ptr, table_close);
    e.codeBytes(&.{ 0x48, 0x8B, 0x43, 0x40, 0x48, 0x85, 0xC0 });
    const no_table_close = e.jcc(0x84);
    e.codeBytes(&.{ 0xFF, 0xD0, 0x85, 0xC0 });
    notePatchJcc(&e, success_patches[0..], &success_count, 0x85);

    const poll_label = e.pos();
    e.patch(no_table_close, poll_label);
    emitZeroEvent(&e);
    e.codeBytes(&.{ 0x48, 0x8D, 0x7D, 0xB0 });
    emitRaxFromR12(&e, if (generation == 2) @offsetOf(@import("r4os").platform2.abi.R4XStartR4Desk2, "gui_poll_event") else 128);
    e.codeBytes(&.{ 0xFF, 0xD0, 0x83, 0xF8, 0x00 });
    const no_event = e.jcc(0x8E);
    e.codeBytes(&.{ 0x83, 0x7D, 0xB0, 0x01 });
    notePatchJcc(&e, success_patches[0..], &success_count, 0x84);
    e.codeBytes(&.{ 0x83, 0x7D, 0xB0, 0x04 });
    const not_mouse_up = e.jcc(0x85);
    e.codeBytes(&.{ 0x81, 0x7D, 0xB8, 0x54, 0x00, 0x00, 0x00 });
    const x_too_small = e.jcc(0x8C);
    e.codeBytes(&.{ 0x81, 0x7D, 0xB8, 0x9C, 0x00, 0x00, 0x00 });
    const x_too_large = e.jcc(0x8D);
    e.codeBytes(&.{ 0x81, 0x7D, 0xBC, 0x4E, 0x00, 0x00, 0x00 });
    const y_too_small = e.jcc(0x8C);
    e.codeBytes(&.{ 0x81, 0x7D, 0xBC, 0x66, 0x00, 0x00, 0x00 });
    const y_too_large = e.jcc(0x8D);
    notePatchJmp(&e, success_patches[0..], &success_count);
    e.patch(not_mouse_up, poll_label);
    e.patch(x_too_small, poll_label);
    e.patch(x_too_large, poll_label);
    e.patch(y_too_small, poll_label);
    e.patch(y_too_large, poll_label);

    const wait_label = e.pos();
    e.patch(no_event, wait_label);
    emitRaxFromR12(&e, if (generation == 2) @offsetOf(@import("r4os").platform2.abi.R4XStartR4Desk2, "desktop_activity_wait") else 376);
    // Wait against the sequence returned by the previous observation.
    e.codeBytes(&.{ 0x48, 0x8B, 0x7D, 0xA8, 0x48, 0xC7, 0xC6, 0xFF, 0xFF, 0xFF, 0xFF, 0x48, 0x8D, 0x55, 0xA8, 0xFF, 0xD0, 0x85, 0xC0 });
    notePatchJcc(&e, fail52_patches[0..], &fail52_count, 0x88);
    const loop_after_wait = e.jmp();

    const success_label = e.pos();
    e.codeBytes(&.{ 0x31, 0xC0 });
    const jmp_success = e.jmp();
    const fail51_label = e.pos();
    e.codeBytes(&.{ 0xB8, 0x33, 0x00, 0x00, 0x00 });
    const jmp_fail51 = e.jmp();
    const fail52_label = e.pos();
    e.codeBytes(&.{ 0xB8, 0x34, 0x00, 0x00, 0x00 });
    const jmp_fail52 = e.jmp();
    const fail63_label = e.pos();
    e.codeBytes(&.{ 0xB8, 0x3F, 0x00, 0x00, 0x00 });
    const jmp_fail63 = e.jmp();
    const epilogue = e.pos();
    e.codeBytes(&.{ 0x48, 0x83, 0xC4, 0x40, 0x41, 0x5E, 0x41, 0x5D, 0x41, 0x5C, 0x5B, 0x5D, 0xC3 });

    const title_pos = e.pos();
    e.bytes(title);
    e.byte(0);
    const message_pos = e.pos();
    e.bytes(message);
    e.byte(0);
    const ok_pos = e.pos();
    e.bytes(ok_label);
    e.byte(0);

    patchList(&e, fail51_patches[0..fail51_count], fail51_label);
    patchList(&e, fail52_patches[0..fail52_count], fail52_label);
    patchList(&e, fail63_patches[0..fail63_count], fail63_label);
    patchList(&e, success_patches[0..success_count], success_label);
    e.patch(loop_after_wait, loop_label);
    e.patch(jmp_success, epilogue);
    e.patch(jmp_fail51, epilogue);
    e.patch(jmp_fail52, epilogue);
    e.patch(jmp_fail63, epilogue);
    e.patchI32(title_ref, @as(i64, @intCast(title_pos)) - @as(i64, @intCast(title_ref + 4)));
    e.patchI32(message_ref, @as(i64, @intCast(message_pos)) - @as(i64, @intCast(message_ref + 4)));
    e.patchI32(ok_ref, @as(i64, @intCast(ok_pos)) - @as(i64, @intCast(ok_ref + 4)));

    if (!e.ok) return null;
    return out[0..e.len];
}

const ImportDest = enum {
    rbx,
    r12,
    r14,
};

fn notePatch(e: *Emitter, patches: []usize, count: *usize, patch_pos: usize) void {
    if (count.* >= patches.len) {
        e.ok = false;
        return;
    }
    patches[count.*] = patch_pos;
    count.* += 1;
}

fn notePatchJcc(e: *Emitter, patches: []usize, count: *usize, condition: u8) void {
    const patch_pos = e.jcc(condition);
    notePatch(e, patches, count, patch_pos);
}

fn notePatchJmp(e: *Emitter, patches: []usize, count: *usize) void {
    const patch_pos = e.jmp();
    notePatch(e, patches, count, patch_pos);
}

fn patchList(e: *Emitter, patches: []const usize, target: usize) void {
    for (patches) |patch_pos| e.patch(patch_pos, target);
}

fn emitFindImportInto(comptime generation: u8, e: *Emitter, group: u8, dest: ImportDest, fail_patches: []usize, fail_count: *usize) void {
    e.codeBytes(&.{ 0x4D, 0x8B, 0x4D, 0x38, 0x41, 0x8B, 0x4D, 0x40, 0x85, 0xC9 });
    notePatchJcc(e, fail_patches, fail_count, 0x84);

    const loop_label = e.pos();
    e.codeBytes(&.{ 0x41, 0x83, 0x39 });
    e.byte(group);
    const jne_next_group = e.jcc(0x85);
    const jne_next_version: ?usize = if (generation == 2) version: {
        e.codeBytes(&.{ 0x41, 0x83, 0x79, 0x04, 0x02 });
        break :version e.jcc(0x85);
    } else null;
    e.codeBytes(&.{ 0x41, 0xF7, 0x41, 0x0C, 0x01, 0x00, 0x00, 0x00 });
    const jz_next_flags = e.jcc(0x84);
    switch (dest) {
        .rbx => e.codeBytes(&.{ 0x49, 0x8B, 0x59, 0x20, 0x48, 0x85, 0xDB }),
        .r12 => e.codeBytes(&.{ 0x4D, 0x8B, 0x61, 0x20, 0x4D, 0x85, 0xE4 }),
        .r14 => e.codeBytes(&.{ 0x4D, 0x8B, 0x71, 0x20, 0x4D, 0x85, 0xF6 }),
    }
    const jz_next_table = e.jcc(0x84);
    const jmp_found = e.jmp();

    const next_label = e.pos();
    e.patch(jne_next_group, next_label);
    if (jne_next_version) |patch| e.patch(patch, next_label);
    e.patch(jz_next_flags, next_label);
    e.patch(jz_next_table, next_label);
    e.codeBytes(&.{ 0x49, 0x83, 0xC1, 0x28, 0xFF, 0xC9 });
    const jnz_loop = e.jcc(0x85);
    e.patch(jnz_loop, loop_label);
    notePatchJmp(e, fail_patches, fail_count);

    const found_label = e.pos();
    e.patch(jmp_found, found_label);
}

fn emitRaxFromR12(e: *Emitter, offset: u32) void {
    e.codeBytes(&.{ 0x49, 0x8B, 0x84, 0x24 });
    e.emitU32(offset);
}

fn emitRaxFromR14(e: *Emitter, offset: u32) void {
    e.codeBytes(&.{ 0x49, 0x8B, 0x86 });
    e.emitU32(offset);
}

fn emitMovEdi(e: *Emitter, value: u32) void {
    e.byte(0xBF);
    e.emitU32(value);
}

fn emitMovEsi(e: *Emitter, value: u32) void {
    e.byte(0xBE);
    e.emitU32(value);
}

fn emitMovEdx(e: *Emitter, value: u32) void {
    e.byte(0xBA);
    e.emitU32(value);
}

fn emitMovEcx(e: *Emitter, value: u32) void {
    e.byte(0xB9);
    e.emitU32(value);
}

fn emitMovR8d(e: *Emitter, value: u32) void {
    e.codeBytes(&.{ 0x41, 0xB8 });
    e.emitU32(value);
}

fn emitGuiClear(e: *Emitter, rgb: u32) void {
    emitRaxFromR14(e, 96);
    emitMovEdi(e, rgb);
    e.codeBytes(&.{ 0xFF, 0xD0 });
}

fn emitGuiRect(e: *Emitter, x: u32, y: u32, w: u32, h: u32, rgb: u32) void {
    emitRaxFromR14(e, 104);
    emitMovEdi(e, x);
    emitMovEsi(e, y);
    emitMovEdx(e, w);
    emitMovEcx(e, h);
    emitMovR8d(e, rgb);
    e.codeBytes(&.{ 0xFF, 0xD0 });
}

fn emitGuiText(e: *Emitter, x: u32, y: u32, fg: u32, bg: u32) usize {
    emitRaxFromR14(e, 112);
    emitMovEdi(e, x);
    emitMovEsi(e, y);
    e.codeBytes(&.{ 0x48, 0x8D, 0x15 });
    const text_ref = e.reserve(4);
    emitMovEcx(e, fg);
    emitMovR8d(e, bg);
    e.codeBytes(&.{ 0xFF, 0xD0 });
    return text_ref;
}

fn emitZeroEvent(e: *Emitter) void {
    e.codeBytes(&.{ 0x48, 0xC7, 0x45, 0xB0, 0x00, 0x00, 0x00, 0x00 });
    e.codeBytes(&.{ 0x48, 0xC7, 0x45, 0xB8, 0x00, 0x00, 0x00, 0x00 });
    e.codeBytes(&.{ 0x48, 0xC7, 0x45, 0xC0, 0x00, 0x00, 0x00, 0x00 });
    e.codeBytes(&.{ 0x48, 0xC7, 0x45, 0xC8, 0x00, 0x00, 0x00, 0x00 });
    e.codeBytes(&.{ 0x48, 0xC7, 0x45, 0xD0, 0x00, 0x00, 0x00, 0x00 });
}

const Emitter = struct {
    out: []u8,
    len: usize = 0,
    ok: bool = true,

    fn storeStackRax(self: *Emitter, offset: u32) void {
        self.codeBytes(&.{ 0x48, 0x89, 0x84, 0x24 });
        self.emitU32(offset);
    }
    fn loadStackRax(self: *Emitter, offset: u32) void {
        self.codeBytes(&.{ 0x48, 0x8B, 0x84, 0x24 });
        self.emitU32(offset);
    }
    fn compareStack32(self: *Emitter, offset: u32, value: u32) void {
        self.codeBytes(&.{ 0x81, 0xBC, 0x24 });
        self.emitU32(offset);
        self.emitU32(value);
    }

    fn pos(self: *const Emitter) usize {
        return self.len;
    }

    fn byte(self: *Emitter, value: u8) void {
        if (self.len >= self.out.len) {
            self.ok = false;
            self.len += 1;
            return;
        }
        self.out[self.len] = value;
        self.len += 1;
    }

    fn bytes(self: *Emitter, value: []const u8) void {
        for (value) |ch| self.byte(ch);
    }

    fn codeBytes(self: *Emitter, comptime value: []const u8) void {
        inline for (value) |ch| self.byte(ch);
    }

    fn reserve(self: *Emitter, count: usize) usize {
        const start = self.len;
        var i: usize = 0;
        while (i < count) : (i += 1) self.byte(0);
        return start;
    }

    fn emitU32(self: *Emitter, value: u32) void {
        self.byte(@intCast(value & 0xff));
        self.byte(@intCast((value >> 8) & 0xff));
        self.byte(@intCast((value >> 16) & 0xff));
        self.byte(@intCast((value >> 24) & 0xff));
    }

    fn jcc(self: *Emitter, cc: u8) usize {
        self.byte(0x0F);
        self.byte(cc);
        return self.reserve(4);
    }

    fn jmp(self: *Emitter) usize {
        self.byte(0xE9);
        return self.reserve(4);
    }

    fn patch(self: *Emitter, imm_pos: usize, target: usize) void {
        self.patchI32(imm_pos, @as(i64, @intCast(target)) - @as(i64, @intCast(imm_pos + 4)));
    }

    fn patchI32(self: *Emitter, imm_pos: usize, value: i64) void {
        if (imm_pos + 4 > self.out.len or value < -2147483648 or value > 2147483647) {
            self.ok = false;
            return;
        }
        const raw: u32 = @bitCast(@as(i32, @intCast(value)));
        self.out[imm_pos + 0] = @intCast(raw & 0xff);
        self.out[imm_pos + 1] = @intCast((raw >> 8) & 0xff);
        self.out[imm_pos + 2] = @intCast((raw >> 16) & 0xff);
        self.out[imm_pos + 3] = @intCast((raw >> 24) & 0xff);
    }
};

fn skipSpaces(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len and isSpace(source[i])) : (i += 1) {}
    return i;
}

fn lineOf(source: []const u8, pos: usize) u32 {
    var line: u32 = 1;
    var i: usize = 0;
    while (i < source.len and i < pos) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

fn stripUtf8Bom(bytes: []const u8) []const u8 {
    if (bytes.len >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF) return bytes[3..];
    return bytes;
}

fn indexOf(value: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > value.len) return null;
    var i: usize = 0;
    while (i + needle.len <= value.len) : (i += 1) {
        if (equals(value[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn startsWith(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and equals(value[0..prefix.len], prefix);
}

fn equals(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn isIdentStart(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or ch == '_';
}

fn isIdent(ch: u8) bool {
    return isIdentStart(ch) or (ch >= '0' and ch <= '9');
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

test "desktop profile accepts the current GUI facade and emits an activity wait" {
    const source =
        \\#include <r4os/r4os.h>
        \\R4OS_TEXT(window_title, "Test");
        \\R4OS_TEXT(ok_label, "OK");
        \\R4OS_TEXT(message, "Hello");
        \\int32_t r4_app_main(R4App *app) {
        \\ R4Timer timers[1]; R4Window window; R4PaintContext paint;
        \\ if (!r4_window_open(app, timers, 1, &window)) return -1;
        \\ r4_window_set_title(&window, window_title);
        \\ r4_window_begin_paint(&window, &paint); R4Canvas canvas = r4_paint_canvas(&paint);
        \\ r4_canvas_clear(canvas, 0); r4_canvas_rect(canvas, 0, 0, 1, 1, 0);
        \\ r4_canvas_text(canvas, 0, 0, message, 0, 0); r4_paint_present(&paint);
        \\ R4MessageNext next = r4_window_wait_message(&window, r4_timeout_forever());
        \\ if (next.message.kind == R4_MESSAGE_MOUSE && next.message.value.mouse.action == R4_MOUSE_UP) return 0;
        \\ return 0; }
    ;
    var code: [max_code_bytes]u8 = undefined;
    var literals: [max_literal_bytes]u8 = undefined;
    const result = compileDesktopOk(source, code[0..], literals[0..]);
    try @import("std").testing.expect(result.ok);
    try @import("std").testing.expect(result.code.len > 0);
    try @import("std").testing.expect(indexOf(result.code, &.{ 0x48, 0x8B, 0x7D, 0xA8, 0x48, 0xC7, 0xC6 }) != null);
    const std = @import("std");
    const work = try std.mem.replaceOwned(u8, std.testing.allocator, source, "r4_app_main(R4App *app)", "work(R4App *app)");
    defer std.testing.allocator.free(work);
    const source2 = try std.mem.concat(std.testing.allocator, u8, &.{
        "#include <r4os/app2.h>\n",
        work,
        "\nint32_t r4_app_main(R4App2 *app2) { R4App app; int32_t rc=r4_app2_facade(app2,&app); return rc<0?rc:work(&app); }\n",
    });
    defer std.testing.allocator.free(source2);
    const next = compileDesktopOk2(source2, &code, &literals);
    try @import("std").testing.expect(next.ok and next.generation == 2);
    try @import("std").testing.expect(indexOf(next.code, &.{ 0x48, 0x8B, 0x7D, 0xA8, 0x48, 0xC7, 0xC6 }) != null);
}

test "console profile accepts only the current App facade" {
    const source =
        \\#include <r4os/r4os.h>
        \\R4OS_TEXT(message, "Hello");
        \\int32_t r4_app_main(R4App *app) {
        \\ return r4sys_write_line(&app->system, message); }
    ;
    const legacy_source =
        \\#include <r4os/r4os.h>
        \\R4OS_TEXT(message, "Legacy");
        \\int32_t r4_main(const R4XStartContext *ctx, R4Sys *sys) {
        \\ return r4sys_write_line(sys, message); }
    ;
    var code: [max_code_bytes]u8 = undefined;
    var literals: [max_literal_bytes]u8 = undefined;
    const current = compileConsole(source, code[0..], literals[0..]);
    try @import("std").testing.expect(current.ok);
    try @import("std").testing.expect(current.code.len > 0);
    const legacy = compileConsole(legacy_source, code[0..], literals[0..]);
    try @import("std").testing.expect(!legacy.ok);
    try @import("std").testing.expectEqual(CompileError.MissingMain, legacy.err.?);
    const wrong_generation = compileConsole2(source, &code, &literals);
    try @import("std").testing.expectEqual(CompileError.MissingMain, wrong_generation.err.?);
}

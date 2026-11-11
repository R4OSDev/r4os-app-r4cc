const std = @import("std");
const r4os = @import("r4os");
const r4cc_core = @import("r4code_cc_core");

const log_capacity: usize = 8192;
const path_capacity: usize = 192;

const version_text = "R4CC 0.1.4";
const toolchain_root = "C:\\R4OS\\SDK\\Toolchains\\C";
const log_dir = "C:\\R4OS\\SDK\\Toolchains\\C";
const log_path = "C:\\R4OS\\SDK\\Toolchains\\C\\R4CC.LOG";
const status_path = "C:\\R4OS\\SDK\\Toolchains\\C\\R4CC.STATUS";
const self_path = "C:\\R4OS\\SDK\\Toolchains\\C\\bin\\R4CC.R4X";

pub fn r4_app_main(root: *r4os.App2) i32 {
    var output: r4os.launch_io.Output = undefined;
    if (r4os.launch_io.Output.init(root, &output) != 0) return 1;
    var app = App{ .root = root, .sys = root.system(), .output = &output };
    app.records = r4os.diagnostics.core.BoundedDiagnosticBuffer.init(&app.record_storage) catch {
        _ = output.close();
        return 1;
    };
    const code = app.run(trim(root.args()));
    _ = app.flushLog();
    const close = output.close();
    if (root.shouldClose()) return 0;
    return if (code == 0 and (output.failed or close != 0)) 1 else code;
}

const Token = struct {
    token: []const u8,
    rest: []const u8,
};

const App = struct {
    root: *r4os.App2,
    sys: r4os.r4sys.Context,
    output: *r4os.launch_io.Output,
    record_storage: [log_capacity + 8]u8 = undefined,
    records: r4os.diagnostics.core.BoundedDiagnosticBuffer = undefined,
    source_buffer: [r4cc_core.max_source_bytes]u8 = undefined,
    code_buffer: [r4cc_core.max_code_bytes]u8 = undefined,
    literal_buffer: [r4cc_core.max_literal_bytes]u8 = undefined,
    log_buffer: [log_capacity]u8 = .{0} ** log_capacity,
    log_len: usize = 0,
    log_overflow: bool = false,

    fn run(self: *App, args: []const u8) i32 {
        self.resetLog();
        var failure: r4os.arguments.Failure = .{};
        var cursor = r4os.arguments.ArgCursor.init(args, .{}, &failure) catch {
            self.logLine("error: invalid UTF8 command line");
            return 1;
        };
        while (cursor.next() catch {
            self.logLine("error: invalid complete argument grammar");
            return 1;
        }) |_| {}

        self.logLine(version_text);
        if (args.len == 0 or equalsIgnoreCase(args, "HELP") or equalsIgnoreCase(args, "/?")) {
            self.printUsage();
            return 0;
        }
        if (equalsIgnoreCase(args, "VERSION") or equalsIgnoreCase(args, "--version") or equalsIgnoreCase(args, "-v")) {
            self.logLine("abi: R4XStart2 + R4SYS/R4DESK/R4DRAW Query2");
            self.logLine("language: R4CC C current App console + desktop subset");
            return 0;
        }
        if (equalsIgnoreCase(args, "STATUS")) return self.status();
        if (equalsIgnoreCase(args, "/SELFTEST") or equalsIgnoreCase(args, "SELFTEST")) return self.selfTest();

        const parsed = takeToken(args);
        if (parsed) |command| {
            if (equalsIgnoreCase(command.token, "COMPILE") or equalsIgnoreCase(command.token, "BUILD")) {
                return self.compileCommand(command.rest);
            }
        }

        self.logLine("error: unknown command");
        self.printUsage();
        return 1;
    }

    fn printUsage(self: *App) void {
        self.logLine("usage:");
        self.logLine("  R4CC.R4X STATUS");
        self.logLine("  R4CC.R4X VERSION");
        self.logLine("  R4CC.R4X COMPILE [--profile R4X_C2_Console|R4X_C2_Desktop_OK] <source.c> <out-code.bin>");
        self.logLine("  R4CC.R4X /SELFTEST");
    }

    fn status(self: *App) i32 {
        self.logLine("toolchain: C");
        self.logLine("compiler: R4CC");
        self.logLine("stage: r4mf-v2-generation2-console-desktop");
        self.logLine("target: x86_64-r4os-r4xstart2");
        self.logLine("source: R4OS-owned C subset compiler");
        self.logLine("license: R4OS repository source, no external compiler source");
        self.logLine("compile: R4X_C2_Console,R4X_C2_Desktop_OK");
        self.logLine("host fallback: disabled");
        self.logLine("status: OK");
        return 0;
    }

    fn compileCommand(self: *App, rest_raw: []const u8) i32 {
        var rest = rest_raw;
        var profile: []const u8 = "R4X_C2_Console";
        if (takeToken(rest)) |maybe_profile| {
            if (equalsIgnoreCase(maybe_profile.token, "--profile")) {
                const profile_token = takeToken(maybe_profile.rest) orelse {
                    self.logLine("error: --profile needs value");
                    return 1;
                };
                profile = profile_token.token;
                rest = profile_token.rest;
            }
        }
        const source_token = takeToken(rest) orelse {
            self.logLine("error: COMPILE needs <source.c> <out-code.bin>");
            return 1;
        };
        const out_token = takeToken(source_token.rest) orelse {
            self.logLine("error: COMPILE needs output path");
            return 1;
        };
        if (trim(out_token.rest).len != 0) {
            self.logLine("error: too many COMPILE arguments");
            return 1;
        }

        return if (self.compileFile(profile, source_token.token, out_token.token)) 0 else 1;
    }

    fn compileFile(self: *App, profile: []const u8, source_path: []const u8, out_path: []const u8) bool {
        self.logPair("source", source_path);
        self.logPair("output", out_path);
        const source = self.readFile(source_path, self.source_buffer[0..]) orelse {
            self.logLine("R4CC error: source file missing, empty or too large");
            return false;
        };
        const generation2 = equalsIgnoreCase(profile, "R4X_C2_Console") or equalsIgnoreCase(profile, "R4X_C2_Desktop_OK");
        const is_desktop_ok = equalsIgnoreCase(profile, "R4X_C_App_Desktop") or equalsIgnoreCase(profile, "R4X_C2_Desktop_OK");
        if (!generation2 and !is_desktop_ok and !equalsIgnoreCase(profile, "R4X_C_App_Console")) {
            self.logLine("R4CC error: unsupported profile");
            return false;
        }
        const compiled = if (generation2)
            (if (is_desktop_ok) r4cc_core.compileDesktopOk2(source, &self.code_buffer, &self.literal_buffer) else r4cc_core.compileConsole2(source, &self.code_buffer, &self.literal_buffer))
        else
            (if (is_desktop_ok) r4cc_core.compileDesktopOk(source, &self.code_buffer, &self.literal_buffer) else r4cc_core.compileConsole(source, &self.code_buffer, &self.literal_buffer));
        if (!compiled.ok) {
            self.logWrite("R4CC error");
            if (compiled.line != 0) {
                self.logWrite(" line ");
                self.logU32(compiled.line);
            }
            self.logWrite(": ");
            self.logLine(r4cc_core.errorMessage(compiled.err.?));
            return false;
        }
        if (!self.writeFile(out_path, compiled.code)) {
            self.logLine("R4CC error: output write failed");
            return false;
        }

        self.logPair("profile", profile);
        self.logWrite("code bytes: ");
        self.logUsize(compiled.code.len);
        self.logWrite("\r\n");
        self.logPair("compiled text", compiled.text);
        self.logLine("R4CC compile: OK");
        return true;
    }

    fn selfTest(self: *App) i32 {
        self.logLine("selftest");
        var ok = true;
        ok = self.expectDir("C:\\R4OS\\SDK") and ok;
        ok = self.expectDir("C:\\R4OS\\SDK\\Include\\C") and ok;
        ok = self.expectDir("C:\\R4OS\\SDK\\Startup\\C") and ok;
        ok = self.expectDir(toolchain_root) and ok;
        ok = self.expectDir("C:\\R4OS\\SDK\\Toolchains\\C\\bin") and ok;
        ok = self.expectDir("C:\\R4OS\\SDK\\Toolchains\\C\\lib") and ok;
        ok = self.expectDir("C:\\R4OS\\SDK\\Toolchains\\C\\include-extra") and ok;
        ok = self.expectFile(self_path) and ok;
        ok = self.expectFile(status_path) and ok;
        if (!ok) {
            self.logLine("R4CC result: FAILED");
            return 1;
        }

        _ = self.status();
        _ = self.ensureDirectory("C:\\TEMP");
        _ = self.ensureDirectory("C:\\TEMP\\R4CC");
        if (!self.writeFile("C:\\TEMP\\R4CC\\SELFTEST.C", selftest_source)) {
            self.logLine("R4CC result: FAILED");
            self.logLine("selftest source write failed");
            return 1;
        }
        if (!self.compileFile("R4X_C2_Console", "C:\\TEMP\\R4CC\\SELFTEST.C", "C:\\TEMP\\R4CC\\HELLOC.CODE")) {
            self.logLine("R4CC result: FAILED");
            return 1;
        }
        if (!self.expectFile("C:\\TEMP\\R4CC\\HELLOC.CODE")) {
            self.logLine("R4CC result: FAILED");
            return 1;
        }
        if (!self.writeFile("C:\\TEMP\\R4CC\\SELFTESTGUI.C", selftest_desktop_source)) {
            self.logLine("R4CC result: FAILED");
            self.logLine("selftest desktop source write failed");
            return 1;
        }
        if (!self.compileFile("R4X_C2_Desktop_OK", "C:\\TEMP\\R4CC\\SELFTESTGUI.C", "C:\\TEMP\\R4CC\\HELLOGUI.CODE")) {
            self.logLine("R4CC result: FAILED");
            return 1;
        }
        if (!self.expectFile("C:\\TEMP\\R4CC\\HELLOGUI.CODE")) {
            self.logLine("R4CC result: FAILED");
            return 1;
        }
        self.logLine("R4CC result: OK");
        return 0;
    }

    fn expectFile(self: *App, path: []const u8) bool {
        if (self.fileExists(path)) {
            self.logPair("file OK", path);
            return true;
        }
        self.logPair("file missing", path);
        return false;
    }

    fn expectDir(self: *App, path: []const u8) bool {
        if (self.dirExists(path)) {
            self.logPair("dir OK", path);
            return true;
        }
        self.logPair("dir missing", path);
        return false;
    }

    fn readFile(self: *App, path: []const u8, out: []u8) ?[]const u8 {
        var path_z: [path_capacity]u8 = .{0} ** path_capacity;
        if (!setZResult(path_z[0..], path)) return null;
        const name = zptr(path_z[0..]);
        var budget = r4os.rpc_budget.Budget.fromTimeout(self.output.clock.read, .{ .kind = 1, .nanoseconds = 5_000_000_000 }) catch return null;
        read_snapshot: while (true) {
            _ = budget.remainingTicks() catch return null;
            if (self.root.shouldClose()) return null;
            const before = switch (r4os.metadata2.info(&self.root.context, name)) {
                .found => |value| value,
                .failure => |code| {
                    if (code != r4os.abi.file_metadata2_error_restart) return null;
                    self.sys.sleepTicks(0);
                    continue :read_snapshot;
                },
                else => return null,
            };
            const size = r4os.metadata2.fileSize(&before) orelse return null;
            if (before.flags & r4os.abi.file_metadata2_flag_directory != 0 or size == 0 or size >= out.len) return null;
            var source = r4os.stream_transfer.adapters.FileRead.fromContext2(&self.root.context, name, 0) catch return null;
            const driver: r4os.stream_transfer.adapters.Driver = .{ .sys = self.sys, .clock = &self.output.clock, .budget = &budget };
            const progress = driver.read(out[0..@intCast(size)], 64 * 1024, r4os.stream_transfer.adapters.FileRead.step, &source, true) catch return null;
            if (progress.outcome != @intFromEnum(r4os.stream_transfer.Outcome.complete) or progress.bytes != size) return null;
            const after = switch (r4os.metadata2.info(&self.root.context, name)) {
                .found => |value| value,
                .failure => |code| {
                    if (code != r4os.abi.file_metadata2_error_restart) return null;
                    self.sys.sleepTicks(0);
                    continue :read_snapshot;
                },
                else => return null,
            };
            if (r4os.metadata2.fileSize(&after) != size or after.flags & r4os.abi.file_metadata2_flag_directory != 0) {
                self.sys.sleepTicks(0);
                continue :read_snapshot;
            }
            if (r4os.metadata2.identity(&before)) |identity| {
                const observed = r4os.metadata2.identity(&after) orelse return null;
                if (!std.meta.eql(identity.*, observed.*)) {
                    self.sys.sleepTicks(0);
                    continue :read_snapshot;
                }
            }
            if (before.flags & r4os.abi.file_metadata2_flag_content_revision_valid != 0 and
                (after.flags & r4os.abi.file_metadata2_flag_content_revision_valid == 0 or before.content_revision != after.content_revision)) return null;
            return out[0..@intCast(size)];
        }
    }

    fn writeFile(self: *App, path: []const u8, data: []const u8) bool {
        var path_z: [path_capacity]u8 = .{0} ** path_capacity;
        if (!setZResult(path_z[0..], path) or self.root.shouldClose()) return false;
        const name = zptr(path_z[0..]);
        if (self.sys.fileStreamBegin(name, r4os.abi.file_stream_open_replace) != 0) return false;
        var published = false;
        defer {
            if (!published) _ = self.sys.fileStreamAbort(name);
        }
        var target = r4os.stream_transfer.adapters.FileStream.fromContext2(&self.root.context, name, 0) catch return false;
        var budget = r4os.rpc_budget.Budget.fromTimeout(self.output.clock.read, .{ .kind = 1, .nanoseconds = 5_000_000_000 }) catch return false;
        const driver: r4os.stream_transfer.adapters.Driver = .{ .sys = self.sys, .clock = &self.output.clock, .budget = &budget };
        const progress = driver.write(data, 64 * 1024, r4os.stream_transfer.adapters.FileStream.step, &target) catch return false;
        if (progress.outcome != @intFromEnum(r4os.stream_transfer.Outcome.complete) or progress.bytes != data.len or self.root.shouldClose()) return false;
        if (self.sys.fileStreamFinish(name, data.len, 0) != 0) return false;
        published = true;
        return true;
    }

    fn fileExists(self: *App, path: []const u8) bool {
        var path_z: [path_capacity]u8 = .{0} ** path_capacity;
        if (!setZResult(path_z[0..], path)) return false;
        return switch (r4os.metadata2.info(&self.root.context, zptr(path_z[0..]))) {
            .found => |value| value.flags & r4os.abi.file_metadata2_flag_directory == 0,
            else => false,
        };
    }

    fn dirExists(self: *App, path: []const u8) bool {
        var path_z: [path_capacity]u8 = .{0} ** path_capacity;
        if (!setZResult(path_z[0..], path)) return false;
        return switch (r4os.metadata2.info(&self.root.context, zptr(path_z[0..]))) {
            .found => |value| value.flags & r4os.abi.file_metadata2_flag_directory != 0,
            else => false,
        };
    }

    fn ensureDirectory(self: *App, path: []const u8) bool {
        if (self.dirExists(path)) return true;
        var path_z: [path_capacity]u8 = .{0} ** path_capacity;
        if (!setZResult(path_z[0..], path)) return false;
        _ = self.sys.dirCreate(zptr(path_z[0..]));
        return self.dirExists(path);
    }

    fn resetLog(self: *App) void {
        self.log_len = 0;
        self.log_overflow = false;
        @memset(self.log_buffer[0..], 0);
    }

    fn logLine(self: *App, text: []const u8) void {
        self.logWrite(text);
        self.logWrite("\r\n");
    }

    fn logPair(self: *App, label: []const u8, value: []const u8) void {
        self.logWrite(label);
        self.logWrite(": ");
        self.logLine(value);
    }

    fn logWrite(self: *App, text: []const u8) void {
        if (text.len == 0) return;
        const available = self.log_buffer.len - self.log_len;
        const count = @min(text.len, available);
        @memcpy(self.log_buffer[self.log_len..][0..count], text[0..count]);
        self.log_len += count;
        self.log_overflow = self.log_overflow or count != text.len;
        if (self.output.failed) return;
        const accepted = self.records.appendRecord(text, .info) catch {
            self.output.failed = true;
            return;
        };
        if (accepted.kind != @intFromEnum(r4os.diagnostics.core.AppendKind.accepted)) {
            self.output.failed = true;
            return;
        }
        const sent = self.records.flushOnce(@intCast(text.len), r4os.launch_io.Output.recordSink, self.output) catch {
            self.output.failed = true;
            return;
        };
        if (sent.completed_records != 1) self.output.failed = true;
    }

    fn logUsize(self: *App, value: usize) void {
        self.logU64(@intCast(value));
    }

    fn logU32(self: *App, value: u32) void {
        self.logU64(value);
    }

    fn logU64(self: *App, value: u64) void {
        var buf: [20]u8 = undefined;
        var pos = buf.len;
        var n = value;
        if (n == 0) {
            self.logWrite("0");
            return;
        }
        while (n > 0) {
            pos -= 1;
            buf[pos] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
        }
        self.logWrite(buf[pos..]);
    }

    fn flushLog(self: *App) bool {
        _ = self.ensureDirectory(log_dir);
        if (self.log_overflow and self.log_len + 17 < self.log_buffer.len) {
            @memcpy(self.log_buffer[self.log_len .. self.log_len + 17], "\r\nlog truncated\r\n");
            self.log_len += 17;
        }
        const written = self.sys.fileWrite(log_path, self.log_buffer[0..self.log_len]);
        return written >= 0 and @as(usize, @intCast(written)) == self.log_len;
    }
};

fn takeToken(raw: []const u8) ?Token {
    var failure: r4os.arguments.Failure = .{};
    var cursor = r4os.arguments.ArgCursor.init(raw, .{}, &failure) catch return null;
    const token = (cursor.next() catch return null) orelse return null;
    return .{ .token = token.bytes(raw) catch return null, .rest = cursor.remainingArguments() catch return null };
}

fn setZ(buffer: []u8, text: []const u8) void {
    @memset(buffer, 0);
    if (buffer.len == 0) return;
    const len = @min(buffer.len - 1, text.len);
    if (len > 0) @memcpy(buffer[0..len], text[0..len]);
    buffer[len] = 0;
}

fn setZResult(buffer: []u8, text: []const u8) bool {
    if (buffer.len == 0 or text.len + 1 > buffer.len) return false;
    setZ(buffer, text);
    return true;
}

fn zptr(buffer: []const u8) [*:0]const u8 {
    return @ptrCast(buffer.ptr);
}

fn zSlice(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn trim(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and isSpace(value[start])) : (start += 1) {}
    while (end > start and isSpace(value[end - 1])) : (end -= 1) {}
    return value[start..end];
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (asciiLower(a[i]) != asciiLower(b[i])) return false;
    }
    return true;
}

fn asciiLower(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + ('a' - 'A');
    return ch;
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

const selftest_source =
    \\#include <r4os/r4os.h>
    \\#include <r4os/app2.h>
    \\#include <r4os/launch_io_platform2.h>
    \\R4OS_TEXT(message, "HELLO from R4CC native C2\r\n");
    \\int32_t r4_app_main(R4App2 *app) {
    \\    R4Sys system;
    \\    R4SdkStdio io;
    \\    if (r4_app2_system(app, &system) != 0) return 1;
    \\    if (R4SdkStdio2(&app->context, &io) != 0) return 1;
    \\    R4WaitSetDeadline poll = { .version = 1, .size = sizeof(poll) };
    \\    uint64_t written = 0;
    \\    while (written < sizeof(message) - 1) {
    \\        R4BytePipeProgress progress = { .version = 1, .size = sizeof(progress) };
    \\        int32_t code = R4SdkStdioWrite(&io, 1, (const uint8_t *)message + written,
    \\            sizeof(message) - 1 - written, &poll, &progress);
    \\        if (code != 0) return code;
    \\        written += progress.bytes;
    \\        if (progress.state != R4OS_BYTE_PIPE_READY && progress.state != R4OS_BYTE_PIPE_WOULD_BLOCK) return 1;
    \\        if (r4_app2_should_close(app)) return 0;
    \\        if (written < sizeof(message) - 1) r4sys_sleep_ticks(&system, 1);
    \\    }
    \\    return 0;
    \\}
;

const selftest_desktop_source =
    \\#include <r4os/app2.h>
    \\#include <r4os/r4os.h>
    \\
    \\R4OS_TEXT(window_title, "HELLOGUI");
    \\R4OS_TEXT(ok_label, "OK");
    \\R4OS_TEXT(message, "HELLO from HELLOGUI");
    \\
    \\static int32_t draw_window(R4Window *window)
    \\{
    \\    R4PaintContext paint;
    \\    if (!r4_window_begin_paint(window, &paint)) return R4OS_ERR_NO_FN;
    \\    R4Canvas canvas = r4_paint_canvas(&paint);
    \\    r4_canvas_clear(canvas, 0x00C0C0C0);
    \\    r4_canvas_rect(canvas, 44, 36, 172, 72, 0x00808080);
    \\    r4_canvas_rect(canvas, 45, 37, 170, 70, 0x00FFFFFF);
    \\    r4_canvas_rect(canvas, 84, 78, 72, 24, 0x00C0C0C0);
    \\    r4_canvas_text(canvas, 58, 50, message, 0x000000, 0x00FFFFFF);
    \\    r4_canvas_text(canvas, 112, 86, ok_label, 0x000000, 0x00C0C0C0);
    \\    return r4_paint_present(&paint);
    \\}
    \\
    \\static int32_t work(R4App *app)
    \\{
    \\    R4Timer timers[1] = {{0}};
    \\    R4Window window;
    \\    if (!r4_window_open(app, timers, 1, &window)) return R4OS_ERR_NO_GROUP;
    \\    r4_window_set_title(&window, window_title);
    \\    r4_window_set_minimum_size(&window, 260, 140);
    \\    if (draw_window(&window) < 0) return R4OS_ERR_NO_FN;
    \\
    \\    for (;;) {
    \\        R4MessageNext next = r4_window_wait_message(&window, r4_timeout_forever());
    \\        if (next.state == R4_MESSAGE_NEXT_FAILED) return next.raw_code;
    \\        if (next.state != R4_MESSAGE_NEXT_MESSAGE) continue;
    \\        if (next.message.kind == R4_MESSAGE_CLOSE) return 0;
    \\        if (next.message.kind == R4_MESSAGE_RESIZE) draw_window(&window);
    \\        if (next.message.kind == R4_MESSAGE_MOUSE &&
    \\            next.message.value.mouse.action == R4_MOUSE_UP &&
    \\            next.message.value.mouse.x >= 84 && next.message.value.mouse.x < 156 &&
    \\            next.message.value.mouse.y >= 78 && next.message.value.mouse.y < 102) {
    \\            return 0;
    \\        }
    \\    }
    \\}
    \\
    \\int32_t r4_app_main(R4App2 *app2){
    \\ R4App app;int32_t rc=r4_app2_facade(app2,&app);if(rc<0)return rc;return work(&app);
    \\}
;

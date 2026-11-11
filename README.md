# R4CC.R4X

`R4CC.R4X` is an independent R4OS application implemented in Zig.

## Package

- Version: `0.1.4`
- Image target: `/R4OS/SDK/Toolchains/C/bin/R4CC.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux:

    ./Build.sh

The build starters verify the pinned SDK and its matched Contract, Libraries
and host tools. `build.zig.zon` records the standalone package identities.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.

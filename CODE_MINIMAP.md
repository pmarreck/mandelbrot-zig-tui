# Code Minimap

## `build.zig`
- `build()` — Zig 0.15 build config: executable, tests, ReleaseFast default

## `src/main.zig`
- `main()` — entry point (currently scaffolding placeholder)

## `flake.nix`
- `packages.default` — nix build for the mandelbrot binary
- `checks.*.test` — nix check running zig unit tests
- `devShells.default` — dev shell with zig + hyperfine

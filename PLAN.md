# Mandelbrot TUI Explorer — Plan

## Completed
- [x] Project scaffolding (build.zig, flake.nix, scripts) — ~2026-04-01 14:45 EST
- [x] Core mandelbrot computation (f128 escape-time + region fill) — ~2026-04-01 15:00 EST
- [x] Core viewport math (screen↔complex, zoom, pan, adaptive iter) — ~2026-04-01 15:15 EST
- [x] Core coloring (density chars + 256-color gradient) — ~2026-04-01 15:30 EST
- [x] TUI input parsing (keys, arrows, SGR mouse) — ~2026-04-01 15:45 EST
- [x] TUI terminal control (raw mode, mouse, SIGWINCH) — ~2026-04-01 16:00 EST
- [x] TUI renderer (pure state → ANSI buffer) — ~2026-04-01 16:15 EST
- [x] TUI app event loop + main entry point — ~2026-04-01 16:30 EST
- [x] CLI test suite — ~2026-04-01 16:40 EST
- [x] Documentation & cleanup — ~2026-04-01 16:45 EST

## Future Enhancements
- [ ] Multithreaded computation (thread pool, row-band splitting)
- [ ] Arbitrary precision (bignum) for unlimited zoom depth
- [ ] C FFI surface exposing core functions
- [ ] "i" info bar shows command to restore exact view (regardless of terminal size)
- [ ] Additional fractal types (Julia sets, Burning Ship)
- [ ] --lang / i18n support per CLI guidelines
- [ ] Cross-platform builds (5 OS/arch targets via build_all)
- [ ] Benchmark suite (./bm)
- [ ] --no-color / --no-ansi / --simple modes (wired up but need testing)

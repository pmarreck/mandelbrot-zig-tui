# Mandelbrot TUI Explorer — Plan

## In Progress
- [ ] Project scaffolding (build.zig, flake.nix, scripts)
- [ ] Core mandelbrot computation (f128 escape-time + region fill)
- [ ] Core viewport math (screen↔complex, zoom, pan, adaptive iter)
- [ ] Core coloring (density chars + 256-color gradient)
- [ ] TUI input parsing (keys, arrows, SGR mouse)
- [ ] TUI terminal control (raw mode, mouse, SIGWINCH)
- [ ] TUI renderer (pure state → ANSI buffer)
- [ ] TUI app event loop + main entry point
- [ ] CLI test suite
- [ ] Documentation

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

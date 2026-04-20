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
- [x] Progressive pre-rendering: CacheLevel + CacheStack — ~2026-04-19 18:00 EST
- [x] Parallel computeRegion (3-thread row-band split) — ~2026-04-19 18:15 EST
- [x] 3-offset doubling algorithm with generation-counter cancellation — ~2026-04-19 18:30 EST
- [x] BackgroundScheduler (coordinator + pre-computation of levels 1-4) — ~2026-04-19 18:40 EST
- [x] renderFrameFromBuffer (decoupled compute from render) — ~2026-04-19 18:45 EST
- [x] Cache-aware event loop integration — ~2026-04-19 18:55 EST
- [x] Benchmark suite (./bm) — ~2026-04-19 19:05 EST

## Future Enhancements
- [ ] **Improve parallel speedup** — currently 1.55x for 3 threads due to load imbalance (middle row-band hits interior points every pixel). Switch to interleaved/striped row assignment.
- [ ] **Double-double arithmetic for deep-zoom precision** — replace f128 soft-float fallback with DD (two f64 representing hi+lo). Uses hardware f64 throughout, expected 3-10x faster than soft-float f128 on ARM64/x86_64. Gives ~106 bits of mantissa (deep enough for ~10^30 zoom). Keep f128 impl as test ground-truth. Spec reference: docs/superpowers/specs/2026-04-19-perf-optimization-design.md (Optimization 3 section).
- [ ] **Shift-on-zoom-in optimization** — use pre-computed Level 1 as new Level 0 after zoom-at-point (currently invalidates cache). Requires sub-region extraction via `sampleStride`.
- [ ] **Pan shift-and-fill** — keep overlapping cached data on pan, only compute newly-exposed edges.
- [ ] **Benchmark regression detection** — `bm` currently only appends. Add % comparison against most recent run, fail on >10% regression.
- [ ] Arbitrary precision (bignum) for unlimited zoom depth
- [ ] C FFI surface exposing core functions
- [ ] "i" info bar shows command to restore exact view (regardless of terminal size)
- [ ] Additional fractal types (Julia sets, Burning Ship)
- [ ] --lang / i18n support per CLI guidelines
- [ ] Cross-platform builds (5 OS/arch targets via build_all)
- [ ] --no-color / --no-ansi / --simple modes (wired up but need testing)

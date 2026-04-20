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
- [x] Benchmark suite baseline (./bm) — ~2026-04-19 19:05 EST
- [x] Perf: thread count auto-detect (cap 12) — ~2026-04-19 20:45 EST
- [x] Perf: stride-based (interleaved) row assignment — ~2026-04-19 21:00 EST
- [x] Perf: f64 hot loop with f128 fallback above zoom 10^13 — ~2026-04-19 21:20 EST
- [x] Perf: --bench-zoom-sequence CLI flag + hyperfine-friendly --bench-quiet — ~2026-04-19 21:30 EST
- [x] Benchmark regression detection in bm script — ~2026-04-19 20:15 EST
- [x] Block quadrant glyph mode (2×2 sub-pixel rendering, `g` toggle, `--glyph=blocks`, `MANDELBROT_SUBBLOCK` env var) — ~2026-04-20 EST

## Performance Evidence

See `benchmarks/results.log` for full history. Summary (Apple M4 Max, 16 cores, ReleaseFast, 200x60 terminal):

| Metric | Baseline (f128, 3 threads, bands) | After f64 hot loop | Total Speedup |
|---|---|---|---|
| Shallow (zoom=1) sequential | 41.12 ms/frame | ~1.21 ms/frame | **~34x** |
| Deep (zoom=1000) sequential | 66.11 ms/frame | ~2.02 ms/frame | **~33x** |
| Shallow parallel (12 threads) | 26.61 ms/frame | ~0.58 ms/frame | **~46x** |
| Deep parallel (12 threads) | 25.61 ms/frame | ~0.35 ms/frame | **~73x** |

Key commits: `b33a57d` (threads), `40007ac` (stride), `12a4a94` (f64 hot loop).

## Future Enhancements
- [ ] **Double-double arithmetic for deep-zoom precision** — replace f128 soft-float fallback with DD (two f64 representing hi+lo). Uses hardware f64 throughout, expected 3-10x faster than soft-float f128 on ARM64/x86_64. Gives ~106 bits of mantissa (deep enough for ~10^30 zoom). Keep f128 impl as test ground-truth. Spec reference: docs/superpowers/specs/2026-04-19-perf-optimization-design.md (Optimization 3 section).
- [ ] **Cardioid/bulb early-exit** — 20-40% fewer iterations in default view (main cardioid and period-2 bulb are provably in the set, skip iteration)
- [ ] **SIMD vectorization** — 4 pixels at a time via @Vector(4, f64) in the inner loop
- [ ] **Persistent thread pool** — skip thread spawn overhead per-frame (thread spawn now dominates at sub-ms workloads)
- [ ] **Bench harness multi-sample with stats** — median/stddev to eliminate false regressions at sub-ms times (hyperfine-style)
- [ ] **Shift-on-zoom-in optimization** — use pre-computed Level 1 as new Level 0 after zoom-at-point (currently invalidates cache). Requires sub-region extraction via `sampleStride`.
- [ ] **Pan shift-and-fill** — keep overlapping cached data on pan, only compute newly-exposed edges.
- [ ] Arbitrary precision (bignum) for unlimited zoom depth
- [ ] C FFI surface exposing core functions
- [ ] "i" info bar shows command to restore exact view (regardless of terminal size)
- [ ] Braille glyph mode (2×4 sub-pixels with `\x1b[1m` bold for contrast) — deferred; compare against blocks mode
- [ ] Sextants glyph mode (2×3 sub-pixels, Unicode 13.0+) — deferred; doesn't align with 2× cache pyramid
- [ ] Additional fractal types (Julia sets, Burning Ship)
- [ ] --lang / i18n support per CLI guidelines
- [ ] Cross-platform builds (5 OS/arch targets via build_all)
- [ ] --no-color / --no-ansi / --simple modes (wired up but need testing)

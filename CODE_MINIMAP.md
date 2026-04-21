# Code Minimap

## `build.zig`
- `build()` — Zig 0.15 build config: shared module defs (cache, mandelbrot, coloring, viewport, input, terminal, renderer, pool, app), executable, 9 test targets, bench target (always ReleaseFast)

## `flake.nix`
- `packages.default` — nix build for the mandelbrot binary
- `checks.*.test` — nix check running zig unit tests
- `devShells.default` — dev shell with zig + hyperfine

## `src/main.zig`
- `main()` — entry point: arg parsing (--help, --about, --single-frame, --bench-zoom-sequence, --bench-quiet), env var injection, app launch
- `runBenchZoomSequence(allocator, state, n, quiet)` — end-to-end bench driver: N zoom-in frames with per-frame compute/render timing, prints Total/Avg summary
- `parseF128Env()` — parse f128 from environment variable (via f64)
- `parseU32Env()` — parse u32 from environment variable
- `parseU16Env()` — parse u16 from environment variable
- `parseBoolEnv(name)` — case-insensitive parse of true/1/yes/on boolean env vars (used for MANDELBROT_SUBBLOCK)
- `parseFlagF128`, `parseFlagF64`, `parseFlagU32`, `parseFlagU64`, `parseFlagU16` — CLI value parsers for --flag=VALUE and --flag VALUE syntax

## `src/core/dd.zig`
- `DD` — double-double struct: `{ hi: f64, lo: f64 }` representing `value = hi + lo` with ~106 bits mantissa (~30 decimal digits)
- `DD.fromF64(x)` — single f64 input, lo=0
- `DD.fromF64Pair(hi, lo)` — direct construction from (hi, lo)
- `DD.fromF128(x)` — **precision-preserving** f128→DD split (essential at deep zoom)
- `DD.zero()`, `DD.toF64()` — constructor + lossy conversion
- `DD.add`, `DD.sub`, `DD.neg`, `DD.mul`, `DD.mulScalar` — QD-style arithmetic (TwoSum + TwoProd via `@mulAdd`)
- `DD.gt`, `DD.lt`, `DD.eq` — lexicographic comparisons (hi first, then lo)

## `src/core/mandelbrot.zig`
- `computeIterationsT(comptime T, c_re: T, c_im: T, max_iter)` — generic smooth iteration count over T (f64, f128, or `dd.DD`); returns `INTERIOR` (-1.0) for points in the set; uses comptime operator dispatch helpers so one body works for all three types
- `computeIterations(c_re: f64, c_im: f64, max_iter)` — default hardware-fast path (f64, valid to ~10^13 zoom)
- `computeIterationsDD(c_re: dd.DD, c_im: dd.DD, max_iter)` — production precision path via double-double (~30 digits, hardware f64)
- `computeIterationsF128(c_re: f128, c_im: f128, max_iter)` — test-only ground truth for verifying DD correctness
- `computeRegion(params, out)` — sequential fill (delegates to `computeRowStride(_, _, 0, 1)` so seq and parallel share one dispatching inner loop)
- `computeRowStride(params, out, thread_idx, num_threads)` — interleaved rows with f64/DD dispatch based on `params.zoom` vs `F64_THRESHOLD`
- `parallelComputeRegion(params, out, ?num_threads)` — spawn N threads running `computeRowStride`; null = auto-detect via `autoThreadCount()` (cap 12)
- `autoThreadCount()` — `min(max(getCpuCount(), 1), MAX_THREADS=12)`
- `computeRegionDirect(level)` — fill a CacheLevel; dispatches f64/DD based on `level.step_re` vs `F64_STEP_THRESHOLD`
- `computeDoubling(parent, child, ?generation)` — 3 threads fill odd/even/odd-odd offset patterns of a 2x child; offsetWorker internally dispatches f64/DD
- `resetDispatchCounters() / f64DispatchCount() / ddDispatchCount()` — test-only observability for f64 vs DD-fallback dispatch
- Comptime helpers `opMul/opAdd/opSub/opMulScalar/opGt/opFromF64/opToF64(T, ...)` — dispatch between primitive operators and DD methods
- `F64_THRESHOLD` = 1.0e13 (zoom-based cutoff; above this, f64 is unsafe)
- `F64_STEP_THRESHOLD` = 2.0e-15 (step-based cutoff for cache levels; below this, f64 is unsafe)
- `MAX_THREADS` = 12 (cap on worker thread count)
- `RegionParams` — struct defining viewport for region computation
- `INTERIOR` — sentinel value for points in the set (-1.0)

## `src/core/cache.zig`
- `CacheLevel` — grid-indexed iteration cache
  - `.init(allocator, CacheLevelParams)` / `.deinit(allocator)`
  - `.pointAt(col, row)` — complex coordinate at grid cell (vertex semantics)
  - `.get(col, row)` / `.set(col, row, value)` — data access
  - `.containsViewport(...)` — bounds check
  - `.sampleStride(start_col, start_row, stride, w, h, out)` — extract sub-grid
  - `.inheritFromParent(parent)` — copy parent data into even-indexed child positions
- `CacheStack` — 5-level resolution pyramid (1x, 2x, 4x, 8x, 16x)
  - `.init()` / `.deinit(allocator)`
  - `.initForViewport(allocator, center, zoom, w, h, max_iter, aspect)` — create Level 0
  - `.createLevel(allocator, idx)` — create level at index (doubled from parent)
  - `.shiftOnZoomIn(allocator)` — rotate levels down on zoom (unused currently; reserved for shift-zoom-in optimization)
  - `.invalidateAll(allocator)` — free all levels
  - `.nextIncompleteLevel()` — find first level that needs computation
- `CacheLevelParams` — init params
- `ComplexPoint` — struct: re, im
- `NUM_LEVELS` — constant = 5

## `src/core/viewport.zig`
- `screenToComplex(params)` — map terminal cell to complex coordinate
- `zoomAt(state, factor, col, row, w, h, aspect)` — zoom centered on click point
- `pan(state, direction, w, h, aspect)` — shift center by 10% of visible range
- `adaptiveMaxIter(zoom, base)` — scale iterations with zoom depth (base + 50*log2(zoom))
- `ViewState` — struct: center, zoom, base_iter, max_iter
- `ComplexPoint` — struct: re, im
- `Direction` — enum: up, down, left, right

## `src/core/coloring.zig`
- `iterToCell(iter, max_iter)` — density mode: cyclic density char + palette color
- `iterToBlock(tl, tr, bl, br, max_iter)` — blocks mode: 2×2 sub-pixels → Unicode quadrant + FG/BG colors (median-split clustering)
- `iterToColor(iter, max_iter)` — shared palette primitive (Bernstein polynomial + log transform) used by both iterToCell and iterToBlock
- `Cell` — density mode result: char + color + is_interior
- `BlockCell` — blocks mode result: char_bytes (UTF-8) + fg + bg + all_interior
- `GlyphMode` — enum { density, blocks }
- `RGB` — struct: r, g, b
- `quadrant_glyphs` — 16-entry UTF-8 lookup table indexed by 4-bit fg_mask

## `src/tui/terminal.zig`
- `enterRawMode() / exitRawMode()` — termios save/restore
- `enableMouseTracking() / disableMouseTracking()` — SGR 1006 mouse protocol
- `hideCursor() / showCursor()` — cursor visibility
- `clearScreen()` — clear and home
- `setupSigwinch()` — SIGWINCH handler with atomic flag
- `checkAndClearResizeFlag()` — poll and reset resize flag
- `getTermSizePosix()` — ioctl TIOCGWINSZ (macOS + Linux)
- `TermSize` — struct: cols, rows

## `src/tui/input.zig`
- `parseEvent(bytes)` — parse raw stdin bytes into Event union
- `parseSgrMouse(bytes)` — parse SGR mouse report payload
- `Event` — tagged union: key_q, key_plus, key_minus, key_g, arrows, mouse_left_press/release, mouse_right_press/release, mouse_drag, scroll_up/down, ctrl_c, resize, unknown
- `MousePos` — struct: col, row

## `src/tui/renderer.zig`
- `renderFrame(state, width, height, allocator)` — convenience: compute + render (density mode only)
- `renderFrameFromBuffer(state, width, height, iter_buf, allocator)` — density-mode render from pre-computed buffer
- `renderFrameFromBlocksBuffer(state, width, height, iter_buf, allocator)` — blocks-mode render from 2×-resolution pre-computed buffer
- `RenderState` — struct: center, zoom, max_iter, show_info, glyph_mode

## `src/tui/pool.zig`
- `BackgroundScheduler` — long-lived coordinator thread managing progressive pre-computation
  - `.init(allocator, *CacheStack)` / `.stop()`
  - `.requestWork()` — kick coordinator (bumps generation; spawns if not running)
  - `.cancel()` — bump generation (does not join coordinator)
  - `.generation` — atomic u32 for worker cancellation checks

## `src/core/animation.zig`
- `validate(raw: RawAnimationFlags) ValidationError!AnimationConfig` — resolves defaults, returns error for bad configs
- `frameAt(cfg, frame_idx) AnimationFrame` — linear center + log zoom interpolation
- `RawAnimationFlags`, `AnimationConfig`, `AnimationFrame`, `ValidationError`

## `src/tui/app.zig`
- `run(initial_state, allocator)` — interactive event loop; owns CacheStack + BackgroundScheduler
- `runAnimation(config, initial_state, allocator)` — animation mode; detects tty/non-tty, paces frames, stats to stderr, falls through to interactive in tty mode
- `renderOneFrame(state, cache_stack, scheduler, allocator, stdout)` — shared render step used by both modes
- `processEvent(state, event)` — pure state transition function
- `viewportChanged(old, new)` — detects when cache invalidation is needed
- `defaultState()` — initial AppState with standard defaults
- `AppState` — struct: center, zoom, iters, info, dimensions, flags, drag state, glyph mode

## `tests/unit/test_mandelbrot.zig` — escape-time + region computation tests (9 tests)
## `tests/unit/test_viewport.zig` — coordinate mapping, zoom, pan, adaptive iter tests (7 tests)
## `tests/unit/test_coloring.zig` — density chars, color range, gradient smoothness tests (5 tests)
## `tests/unit/test_input.zig` — key, arrow, mouse, Ctrl-C, drag, scroll parsing tests (17 tests)
## `tests/unit/test_renderer.zig` — frame output, info bar, determinism, buffer-consistency tests (5 tests)
## `tests/unit/test_cache.zig` — CacheLevel + CacheStack structure/shift/invalidation tests (12 tests)
## `tests/unit/test_parallel.zig` — parallel compute, inheritFromParent, computeDoubling tests (8 tests)
## `tests/cli/test_cli.bash` — CLI integration tests: help, about, single-frame, determinism (7 tests)
## `tests/benchmark/bench_render.zig` — sequential vs parallel render speedup benchmark

## `bm`
- Bash script: runs `zig build bench` (ReleaseFast) and appends timestamped + SHA-stamped output to `benchmarks/results.log`

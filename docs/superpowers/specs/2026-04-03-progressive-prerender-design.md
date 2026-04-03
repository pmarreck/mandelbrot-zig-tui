# Progressive Background Pre-Rendering — Design Spec

## Overview

Add a multi-resolution cache with background thread pre-computation to the Mandelbrot TUI. While the user views the current frame, background threads progressively compute higher-resolution versions of the same viewport (2x, 4x, 8x, 16x). When the user zooms in, the pre-computed data is displayed instantly from cache. Panning reuses overlapping cached data and only computes newly-exposed edges.

## Cache Structure

Five resolution levels, all covering the same complex-plane bounding box:

```
Level 0 (display):  W × H        — currently displayed
Level 1 (2x):       2W × 2H      — pre-rendered
Level 2 (4x):       4W × 4H      — pre-rendered
Level 3 (8x):       8W × 8H      — pre-rendered
Level 4 (16x):      16W × 16H    — pre-rendered (deepest)
```

Each level is a `CacheLevel`:

```zig
const CacheLevel = struct {
    origin_re: f128,          // top-left corner in complex plane
    origin_im: f128,
    step_re: f128,            // spacing between grid points
    step_im: f128,
    width: u32,               // grid dimensions
    height: u32,
    max_iter: u32,            // iteration depth used for this level
    data: []f64,              // row-major smooth iteration values
    complete: bool,           // fully computed or partially filled
};
```

All levels share the same bounding box: `origin + step * dimensions` yields the same complex-plane extent across levels. Points at even indices in Level N+1 are identical to Level N — inherited, not recomputed.

### Memory Budget

For a 200×60 terminal (generous):
- Level 0: 12,000 × 8 bytes = 94 KB
- Level 1: 48,000 × 8 = 375 KB
- Level 2: 192,000 × 8 = 1.5 MB
- Level 3: 768,000 × 8 = 6 MB
- Level 4: 3,072,000 × 8 = 24 MB
- **Total: ~32 MB** — trivial for any modern system.

## 3-Thread Resolution Doubling

Going from Level N (W×H) to Level N+1 (2W×2H):

- **Existing points**: W×H values at even,even positions `[2i, 2j]` — inherited from Level N, zero recomputation.
- **Thread 1**: W×H new points at `[2i+1, 2j]` (odd col, even row)
- **Thread 2**: W×H new points at `[2i, 2j+1]` (even col, odd row)
- **Thread 3**: W×H new points at `[2i+1, 2j+1]` (odd col, odd row)

Each thread computes exactly W×H points. Perfectly balanced, zero overlap, zero data dependencies between threads. Same decomposition applies at every level transition.

## Thread Pool

**Pool size:** 3 threads (matches the natural 3-way decomposition).

### Foreground render (synchronous)

When `needs_redraw` is set and cache doesn't cover the viewport:
- Split the display-resolution grid into 3 row bands
- Dispatch to 3 threads, main thread waits for completion
- ~3x faster than current single-threaded render
- Result stored in cache as Level 0

### Background pre-computation (asynchronous)

When display is up-to-date and event loop is idle:
- Compute Level 1 using 3 threads (the 3-offset pattern)
- When Level 1 completes, compute Level 2
- Continue through Level 3, Level 4
- Each thread checks an atomic generation counter every row — if user acts, threads bail

### Priority order after user action:
1. Fill any gaps in Level 0 (display — e.g., pan exposed new edges)
2. Level 1 → Level 2 → Level 3 → Level 4

## Zoom Behavior

### Zoom in 2x:
1. Render first: display the frame from cache (Level 1 data, instant)
2. Then shift cache: Level 1→0, Level 2→1, Level 3→2, Level 4→3
3. Kick background threads to compute new Level 4
4. This is pointer rotation — zero data copying for the shift

After 4 consecutive zooms, the cache is exhausted. The 5th zoom requires a foreground compute (parallel, ~3x current speed), then background pre-computation restarts.

### Zoom out 2x:
- Current display covers a smaller region than the new viewport
- Cached data for the old viewport is valid for the center portion
- Border regions need computation (same shift-and-fill logic as panning)
- Background threads fill edges, then resume deepening levels

## Pan Behavior

Cache is indexed by complex-plane coordinates, so pan is a spatial shift:
- Each level checks overlap with new viewport
- Points still in-bounds are kept (index arithmetic)
- Newly-exposed edges queued for computation
- Background threads prioritize Level 0 edges (display), then deepen

This means most of the frame is a cache hit during drag-panning — only the thin edge strip needs computation.

## Cancellation

- **Zoom**: all levels invalidated (resolution hierarchy changes). Bump generation counter. Threads bail, restart from new viewport.
- **Pan**: keep overlapping data at all levels, fill edges starting from Level 0. Generation counter bumped to interrupt current background level, work requeued with new edges.
- **Resize**: Level 0 dimensions change, all levels invalidated. Same as zoom.
- **Max iterations change** (`[`/`]` keys): All levels invalidated — cached values were computed with old `max_iter`, interior/exterior classification may differ. Full recompute.

Generation counter model: `atomic(u32)`. Each worker row-loop iteration checks `if (current_gen != my_gen) return;`. Main thread bumps on any user action that changes the viewport.

## Rendering Integration

### Current flow:
```
needs_redraw → computeRegion(viewport) → colorize → ANSI buffer → display
```

### New flow:
```
needs_redraw → cache.sample(viewport, display_resolution)
  → HIT:    read from cache level → colorize → display (sub-ms)
  → PARTIAL: read cached points, parallel compute missing → display
  → MISS:   parallel foreground compute → store in cache → display
→ kick background pre-computation if idle
```

### Key function — `cache.sample(viewport, width, height) → SampleResult`:
- Finds highest-resolution cache level covering the requested viewport
- If level grid aligns (same bounding box, resolution is exact multiple), extract by striding
- If viewport shifted (pan), return cached points for in-bounds cells, mark out-of-bounds as needs-compute

The renderer itself doesn't change — it still receives `[]f64` and colorizes it. Only the source of that buffer changes.

## Synchronization

**Between background threads and main thread:**
- `atomic(u32)` generation counter — main thread bumps on user action, workers check per-row. Lock-free.
- `atomic(bool)` per-level completion flag — workers set `.release` when done, main thread reads `.acquire`. No mutex.
- Thread join for foreground parallel renders — main thread spawns 3 threads, joins all before displaying.

**Between the 3 background threads:**
- Nothing. Each writes to a disjoint set of indices (the 3 offset patterns have zero overlap).

**No mutexes at all.** The only moment of potential conflict is the zoom-shift (Level 1→Level 0), but that happens on the main thread *after* background threads have been cancelled via generation counter and confirmed stopped. Zig's `std.atomic.Value` and `std.Thread` cover everything needed.

## File Structure

```
src/
  core/
    mandelbrot.zig     — MODIFY: add parallelComputeRegion (row-band split)
    cache.zig          — NEW: CacheLevel, CacheStack, lookup/insert/shift/invalidate
  tui/
    pool.zig           — NEW: 3-thread pool, foreground dispatch, background scheduling
    renderer.zig       — MODIFY: query cache instead of always computing
    app.zig            — MODIFY: own CacheStack, kick background work when idle,
                         bump generation on user action
tests/
  unit/
    test_cache.zig     — NEW: cache structure, overlap, shift, zoom rotation
    test_pool.zig      — NEW: parallel compute correctness, cancellation
  benchmark/
    bench_render.zig   — NEW: single vs parallel, cold vs warm cache
bm                     — NEW: bash script to run benchmarks
```

`cache.zig` in `core/` (pure data structure, no I/O). `pool.zig` in `tui/` (manages threads, scheduling).

## Testing

### Unit tests

**Cache tests (`test_cache.zig`):**
- Point lookup by complex coordinate returns correct index
- Populate Level 0, derive Level 1 with 3-offset pattern, verify even-indexed points match Level 0
- Zoom shift: rotate levels, verify Level 1 data accessible as Level 0
- Pan overlap: shift viewport 25%, verify overlapping points preserved, edges marked incomplete
- Full invalidation on resize

**Thread pool tests (`test_pool.zig`):**
- Parallel `computeRegion` (3 row bands) identical to single-threaded
- Background 2x computation matches sequential: populate Level 0, run 3-thread doubling, compare against `computeRegion` at 2x
- Generation counter cancellation: start computation, bump generation, verify threads stopped early

**Integration tests (in `app.zig` inline tests):**
- `processEvent` zoom-in with populated cache: no recomputation needed (cache hit)
- 4 consecutive zoom-ins: each hits cache
- Pan then zoom: cache partially reused

### Benchmarks (`./bm`)

- Single render: `computeRegion` 200×60 max_iter=256, single-thread vs 3-thread
- Zoom latency: time from zoom event to frame displayed, cold vs warm cache
- Pre-computation throughput: time to fill all 4 levels for 200×60 terminal
- Pan responsiveness: render time after pan, partial cache vs cold

Use `hyperfine` for CLI benchmarks, `std.time.Timer` for internal microbenchmarks. Log to `benchmarks/results.log`.

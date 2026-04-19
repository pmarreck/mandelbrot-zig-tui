# Performance Optimization — Design Spec

## Overview

Three optimizations targeting the Mandelbrot render hot path, plus benchmark infrastructure to measure and protect the improvements:

1. **Thread count increase** — from fixed 3 to auto-detect (cap 12) on CPUs with many cores.
2. **Interleaved row assignment** — fix load imbalance where the middle row-band hits the Mandelbrot set's interior (max iterations every pixel).
3. **f64 hot loop** — Apple Silicon has no hardware f128; soft-float emulation is 10-50x slower than hardware f64. Make the iteration loop generic over float type, default to f64, fall back to f128 only when zoom exceeds f64's ~10^13 precision threshold.

Combined with benchmark tooling (`--bench-zoom-sequence N` CLI flag, expanded microbenchmarks, regression detection in `bm`), we expect 30-80x total speedup over the current baseline on Apple M4 Max.

## Motivation

Current state on Apple M4 Max:
- 3 threads on 16 cores (underutilized)
- Contiguous row bands cause load imbalance (middle band does ~3x work of edge bands)
- `f128` used throughout the inner iteration loop, even though zoom level never exceeds f64 precision in normal use
- Measured parallel speedup: 1.55x vs sequential (target was ~3x)

Current bench: sequential 41.12 ms/frame, parallel 26.61 ms/frame (200×60 at max_iter=256).

## Benchmark Infrastructure

### `--bench-zoom-sequence N` CLI flag

End-to-end latency benchmark driver in `src/main.zig`. When present:
1. Initialize state at seahorse valley (`-0.7435, 0.1314`), terminal 120×40 (env vars can override).
2. Render N frames, each zooming 2x from previous (starts at zoom 1.0, max_iter=256 base).
3. Time each frame individually (compute phase vs render phase).
4. Output to stderr:
   ```
   === Zoom Sequence Benchmark (120x40, base_iter=256, N=5) ===
     Frame 1 (zoom=1):    compute=18.2ms  render=0.4ms  total=18.6ms
     Frame 2 (zoom=2):    compute=22.1ms  render=0.4ms  total=22.5ms
     ...
     Total: 147.3ms  Avg/frame: 29.5ms
   ```
5. `--bench-quiet` suppresses per-frame output (but keeps totals) for clean `hyperfine` runs.
6. Exits with code 0 on success.

### Microbenchmarks (`tests/benchmark/bench_render.zig`)

Expand to three scenarios, each running sequential + parallel:

- **Shallow** (zoom=1, max_iter=256, 200×60): mostly escape-velocity points, tests iteration throughput in the common case.
- **Deep** (zoom=1000 near `-0.7435, 0.1314`, max_iter=1000): stresses the interior-check path where many points iterate all the way to max_iter.
- **Sequence** (5 zoom steps): simulates actual user interaction.

For each, report speedup ratio. Additionally, print results for multiple thread counts (1, 3, 8, auto) so we can see diminishing returns.

### `bm` script regression detection

After appending new run to `benchmarks/results.log`:
1. Parse the previous run's numbers from the log.
2. Compute % delta for each metric.
3. If any metric regressed >10%, print a red `⚠ REGRESSION: <metric> changed by X%` warning.
4. Exit code stays 0 (rerunning `bm` counts as acceptance per CLAUDE.md).

## Optimization 1 — Thread Count & Load Balancing

### Thread count auto-detection

Replace `const NUM_THREADS: u32 = 3` with a runtime value:

```zig
/// Detect optimal worker thread count. Cap at 12 to leave headroom for
/// main thread + OS + other processes on many-core machines.
pub fn autoThreadCount() u32 {
    const count = std.Thread.getCpuCount() catch 3;
    return @min(@max(count, 1), 12);
}
```

`parallelComputeRegion` takes an optional thread count parameter:
```zig
pub fn parallelComputeRegion(params: RegionParams, out: []f64, num_threads: ?u32) !void
```
`null` means auto-detect. Tests pass explicit values; app.zig uses `null`.

### Interleaved row assignment

Current `computeRowBand(params, out, start_row, end_row)` processes contiguous rows. This causes load imbalance when the fractal's high-iteration zone (the set's interior) falls within one band's rows.

New: `computeRowStride(params, out, start_row, num_threads)` processes rows `start_row`, `start_row + num_threads`, `start_row + 2*num_threads`, ... Each thread sees a statistically similar mix of interior/exterior pixels.

`parallelComputeRegion` becomes:
```zig
pub fn parallelComputeRegion(params: RegionParams, out: []f64, num_threads: ?u32) !void {
    const n = num_threads orelse autoThreadCount();
    if (params.height < n) {
        computeRegion(params, out);
        return;
    }
    const threads = try allocator.alloc(std.Thread, n);  // or fixed-size buffer with cap 12
    defer allocator.free(threads);
    for (0..n) |i| {
        threads[i] = try std.Thread.spawn(.{}, computeRowStride, .{ params, out, @as(u16, @intCast(i)), @as(u16, @intCast(n)) });
    }
    for (threads) |t| t.join();
}
```

(Or use a stack-allocated array of size 12 since that's our cap — simpler, no allocator needed.)

### Test impact
- Existing `parallelComputeRegion matches sequential` tests still pass (row assignment order doesn't change results).
- New test: `parallelComputeRegion with 1, 3, 8, 12 threads all produce identical output`.

## Optimization 2 — f64 Hot Loop

### Current state
`computeIterations(c_re: f128, c_im: f128, max_iter: u32) -> f64` uses f128 throughout the inner z iteration. On Apple Silicon (no hardware f128), this invokes soft-float library calls (`__multf3`, `__addtf3`, etc.) which are 10-50x slower than hardware f64.

### New API

Make the function comptime-generic over float type:

```zig
pub fn computeIterationsT(comptime T: type, c_re: T, c_im: T, max_iter: u32) f64 {
    var z_re: T = 0.0;
    var z_im: T = 0.0;
    var i: u32 = 0;
    while (i < max_iter) : (i += 1) {
        const z_re2 = z_re * z_re;
        const z_im2 = z_im * z_im;
        if (z_re2 + z_im2 > @as(T, BAILOUT_SQ_F64)) {
            // Smooth coloring: n + 1 - log2(log2(|z|))
            const mod_sq: f64 = @floatCast(z_re2 + z_im2);
            const log_zn = @log(mod_sq) / 2.0;
            const nu = @log(log_zn / @log(2.0)) / @log(2.0);
            return @as(f64, @floatFromInt(i)) + 1.0 - nu;
        }
        z_im = 2.0 * z_re * z_im + c_im;
        z_re = z_re2 - z_im2 + c_re;
    }
    return INTERIOR;
}

/// Default: fast f64 path. Good to ~10^13 zoom depth.
pub fn computeIterations(c_re: f64, c_im: f64, max_iter: u32) f64 {
    return computeIterationsT(f64, c_re, c_im, max_iter);
}

/// Precision path: use when zoom exceeds f64's safe range.
pub fn computeIterationsF128(c_re: f128, c_im: f128, max_iter: u32) f64 {
    return computeIterationsT(f128, c_re, c_im, max_iter);
}
```

### Call-site changes in `computeRowStride`

Current:
```zig
const c_re = start_re + @as(f128, @floatFromInt(col)) * step_re;  // f128 arithmetic
out[idx] = computeIterations(c_re, c_im, params.max_iter);        // f128 in iteration loop
```

New: auto-dispatch based on zoom threshold:
```zig
const c_re_f128: f128 = start_re + @as(f128, @floatFromInt(col)) * step_re;
const c_im_f128: f128 = start_im + @as(f128, @floatFromInt(row)) * step_im;

if (params.zoom <= F128_DISPATCH_THRESHOLD) {
    const c_re: f64 = @floatCast(c_re_f128);
    const c_im: f64 = @floatCast(c_im_f128);
    out[idx] = computeIterations(c_re, c_im, params.max_iter);
} else {
    out[idx] = computeIterationsF128(c_re_f128, c_im_f128, params.max_iter);
}
```

`F128_DISPATCH_THRESHOLD = 1.0e13` — conservative threshold derived from f64's ~2.2e-16 relative precision. Below this, pixel-spacing exceeds f64 resolution so dispatch to f64 is safe.

The cumulative state (`center_re`, `center_im`, `zoom`, `step_re`, `start_re`) remains f128 so precision doesn't drift across many pan/zoom operations. Only the per-pixel iteration loop is f64.

### Test strategy

- **`computeIterations f64 matches f128 at shallow zoom`** — 100 random points in [-2, 2]², compare smooth iteration count within 1e-10 epsilon.
- **`f64 produces plausible output near precision threshold`** — at zoom 10^12, verify output has variety (not all same value), interior detection still works.
- **`auto-dispatch uses f128 when zoom exceeds threshold`** — expose two test-only counters (`f64_dispatch_count`, `f128_dispatch_count`) as `std.atomic.Value(u64)` module-level variables in `mandelbrot.zig`, incremented in each dispatch arm. Test resets, renders at zoom 10^10 (f64 arm), asserts f64 counter increased and f128 didn't; then at zoom 10^14 (f128 arm), asserts f128 counter increased.
- All existing tests continue to pass.

## Optimization 3 — Cardioid/Bulb Early-Exit (Future)

Not in this plan. Mentioned for completeness: before the iteration loop, check if `(c_re, c_im)` lies within the main cardioid or period-2 bulb — these are provably in the set and can short-circuit the iteration. Gives 20-40% speedup in the default view. Deferred to a future spec.

## File Changes

```
src/
  core/
    mandelbrot.zig       — MODIFY: computeIterationsT, computeRowStride (replaces computeRowBand),
                           autoThreadCount, F128_DISPATCH_THRESHOLD constant, dispatch logic
  main.zig               — MODIFY: add --bench-zoom-sequence N and --bench-quiet flags
tests/
  unit/
    test_parallel.zig    — ADD: f64/f128 equivalence, thread count variations, auto-dispatch test
  benchmark/
    bench_render.zig     — MODIFY: shallow/deep/sequence scenarios, thread count sweep
  cli/
    test_cli.bash        — ADD: --bench-zoom-sequence smoke tests
bm                       — MODIFY: regression detection (>10% warning, non-fatal)
```

No new files. `computeRowBand` is renamed/replaced by `computeRowStride`; callers updated. Thread count is a runtime value, not comptime.

## Implementation Order

Each step is a separate commit with bench log update:

1. **Thread count auto-detect** (replace 3 with runtime value, no row-assignment change yet)
2. **Interleaved row assignment** (`computeRowStride` replaces `computeRowBand`)
3. **f64 hot loop** (`computeIterationsT` generic, dispatch in call sites)
4. **`--bench-zoom-sequence` + `--bench-quiet`** (new CLI flags)
5. **`bm` regression detection**

After each of 1-3, record the bench result. Expected cumulative speedups:
- After step 1: ~3x (up from 1.55x, 8 threads but still load-imbalanced)
- After step 2: ~6-8x (load balanced, threads working evenly)
- After step 3: ~30-80x total (the big one — hardware f64 beats soft-float f128 by 10x+ on Apple Silicon)

If any step falls short of target, investigate before proceeding.

## Performance Evidence

All runs logged to `benchmarks/results.log`. After implementation, we expect the log to show a clear step-function improvement at each commit. The regression check in `bm` prevents silent regressions in future work.

## Non-Goals

- SIMD vectorization (AVX/NEON in the inner loop) — possible future optimization, not in this plan.
- Work-stealing thread pool — row-stride assignment already load-balances well; overhead of a real work queue likely not worth it.
- Cardioid/bulb early-exit — deferred to a separate spec.
- Multithreaded doubling (`computeDoubling` still uses 3 threads, one per offset pattern) — not the bottleneck since the hot path is `computeIterations` itself.

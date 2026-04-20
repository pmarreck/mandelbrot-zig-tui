# Double-Double Arithmetic — Design Spec

## Overview

Replace the soft-float f128 production fallback in the Mandelbrot hot loop with a double-double (DD) implementation. DD represents a high-precision number as two f64 values (`hi + lo`) using QD-style algorithms (Dekker/Knuth TwoSum + TwoProd via `@mulAdd`). All DD arithmetic uses hardware f64 throughout.

**Expected impact**: 3-10x faster than soft-float f128 on ARM64 and x86_64. Precision ~106 bits mantissa (~30 digits), deep enough for zoom levels up to ~10^30 — well beyond any practical terminal fractal viewer.

**f128 stays in the codebase only as test ground-truth** — no production path invokes it. DD correctness is verified by cross-checking against f128 within tight epsilon.

## DD Module API

### `src/core/dd.zig`

Pure data type + arithmetic. Zero I/O, zero threading.

```zig
pub const DD = struct {
    hi: f64,
    lo: f64,

    pub fn fromF64(x: f64) DD;
    pub fn fromF64Pair(hi: f64, lo: f64) DD;  // assumes |hi| >= |lo|, lo is roundoff
    pub fn zero() DD;
    pub fn toF64(self: DD) f64;               // lossy — used for comparisons against hardware scalars and final coloring

    pub fn add(a: DD, b: DD) DD;              // TwoSum-based, no ordering assumption
    pub fn sub(a: DD, b: DD) DD;              // add + neg
    pub fn neg(a: DD) DD;
    pub fn mul(a: DD, b: DD) DD;              // TwoProd via @mulAdd
    pub fn mulScalar(a: DD, x: f64) DD;       // specialized: DD × f64

    pub fn gt(a: DD, b: DD) bool;
    pub fn lt(a: DD, b: DD) bool;
    pub fn eq(a: DD, b: DD) bool;
};
```

### Implementation notes

- `add` uses **TwoSum** (Knuth): no ordering precondition, 6 FLOPs. Returns `(s, e)` where `s = a + b` and `e` is the roundoff error: `s + e == a + b` exactly.
- `mul` uses **TwoProd** via `@mulAdd(f64, a, b, -a*b)`. With hardware FMA: 2 FLOPs. Returns the exact product as a DD.
- `mulScalar` is a specialization of `mul` that skips the f64×f64 → DD promotion cost when one operand is already a plain f64.
- `gt`/`lt`/`eq` compare `hi` first; if equal, compare `lo`.
- No `sqrt`, `div`, `log`, or trig — not needed for Mandelbrot.
- `fromF64Pair` is used internally by `add`/`mul` to construct normalized DDs; exposed publicly for testability.

## Dispatch Strategy

### Thresholds

Current dispatch (zoom-based) uses:
- `zoom <= F128_DISPATCH_THRESHOLD` (1.0e13) → f64 path
- `zoom > F128_DISPATCH_THRESHOLD` → f128 path

New dispatch:
- `zoom <= F64_THRESHOLD` (1.0e13, unchanged value) → **f64 path** (fastest, use when precision-safe)
- `zoom > F64_THRESHOLD` → **DD path** (production fallback, ~10^30 precision ceiling)
- **f128 never invoked at runtime** — only called from unit tests as ground truth

### Renamed constants (public API change)

- `F128_DISPATCH_THRESHOLD` → `F64_THRESHOLD`
- `F128_STEP_THRESHOLD` → `F64_STEP_THRESHOLD` (step-size equivalent for cache levels)

These constants name the threshold from the f64-viability perspective, which is more intuitive than the old "when f128 kicks in" name.

### Dispatch counters

- `g_f64_dispatch` → unchanged (kept)
- `g_f128_dispatch` → removed from production
- Add `g_dd_dispatch`
- `resetDispatchCounters()` resets both f64 and DD counters
- `f64DispatchCount()` unchanged
- `f128DispatchCount()` → removed from public API
- Add `ddDispatchCount()`

Tests that directly call `computeIterationsF128` do not increment any counter; they're independent invocations.

## `src/core/mandelbrot.zig` Changes

### Comptime dispatch helpers (new, at file scope)

Since Zig has no operator overloading, add small inline helpers that dispatch on the type at comptime:

```zig
const dd = @import("dd");

inline fn opMul(comptime T: type, a: T, b: T) T {
    if (T == dd.DD) return a.mul(b);
    return a * b;
}

inline fn opAdd(comptime T: type, a: T, b: T) T {
    if (T == dd.DD) return a.add(b);
    return a + b;
}

inline fn opSub(comptime T: type, a: T, b: T) T {
    if (T == dd.DD) return a.sub(b);
    return a - b;
}

inline fn opMulScalar(comptime T: type, a: T, x: f64) T {
    if (T == dd.DD) return a.mulScalar(x);
    return a * @as(T, @floatCast(x));
}

inline fn opGt(comptime T: type, a: T, b: T) bool {
    if (T == dd.DD) return a.gt(b);
    return a > b;
}

inline fn opFromF64(comptime T: type, x: f64) T {
    if (T == dd.DD) return dd.DD.fromF64(x);
    return @as(T, @floatCast(x));
}

inline fn opToF64(comptime T: type, a: T) f64 {
    if (T == dd.DD) return a.toF64();
    return @as(f64, @floatCast(a));
}
```

Each instantiation monomorphizes at compile time — branches disappear.

### `computeIterationsT` rewrite

Replace inline operator usage with helpers. The signature is unchanged; the body becomes:

```zig
pub fn computeIterationsT(comptime T: type, c_re: T, c_im: T, max_iter: u32) f64 {
    var z_re: T = opFromF64(T, 0.0);
    var z_im: T = opFromF64(T, 0.0);
    const bailout_sq: T = opFromF64(T, BAILOUT_SQ_F64);
    var i: u32 = 0;
    while (i < max_iter) : (i += 1) {
        const z_re2 = opMul(T, z_re, z_re);
        const z_im2 = opMul(T, z_im, z_im);
        const sum_sq = opAdd(T, z_re2, z_im2);
        if (opGt(T, sum_sq, bailout_sq)) {
            const mod_sq_f64: f64 = opToF64(T, sum_sq);
            const log_zn = @log(mod_sq_f64) / 2.0;
            const nu = @log(log_zn / @log(2.0)) / @log(2.0);
            return @as(f64, @floatFromInt(i)) + 1.0 - nu;
        }
        // z_im = 2.0 * z_re * z_im + c_im
        const two_z_re = opMulScalar(T, z_re, 2.0);
        const product = opMul(T, two_z_re, z_im);
        z_im = opAdd(T, product, c_im);
        // z_re = z_re2 - z_im2 + c_re
        const diff = opSub(T, z_re2, z_im2);
        z_re = opAdd(T, diff, c_re);
    }
    return INTERIOR;
}
```

### Public wrappers

```zig
pub fn computeIterations(c_re: f64, c_im: f64, max_iter: u32) f64 {
    return computeIterationsT(f64, c_re, c_im, max_iter);
}

pub fn computeIterationsDD(c_re: dd.DD, c_im: dd.DD, max_iter: u32) f64 {
    return computeIterationsT(dd.DD, c_re, c_im, max_iter);
}

pub fn computeIterationsF128(c_re: f128, c_im: f128, max_iter: u32) f64 {
    return computeIterationsT(f128, c_re, c_im, max_iter);
}
```

### Call-site updates

Three call sites dispatch on zoom/step. For each, the f128 branch is replaced with a DD branch. Example from `computeRowStride`:

```zig
if (params.zoom <= F64_THRESHOLD) {
    _ = g_f64_dispatch.fetchAdd(1, .monotonic);
    // f64 path — unchanged from current code
} else {
    _ = g_dd_dispatch.fetchAdd(1, .monotonic);
    // DD path:
    // - Convert start_re, start_im, step_re, step_im from f128 to DD once per row/region
    // - Inner loop uses DD arithmetic
    const start_re_dd = dd.DD.fromF64(@floatCast(start_re));
    const step_re_dd = dd.DD.fromF64(@floatCast(step_re));
    // ... etc for start_im, step_im
    var row: u32 = thread_idx;
    while (row < params.height) : (row += num_threads) {
        const row_f64: f64 = @floatFromInt(row);
        const c_im_dd = dd.DD.fromF64(@floatCast(start_im)).add(dd.DD.fromF64(@floatCast(step_im)).mulScalar(row_f64));
        var col: u32 = 0;
        while (col < params.width) : (col += 1) {
            const col_f64: f64 = @floatFromInt(col);
            const c_re_dd = start_re_dd.add(step_re_dd.mulScalar(col_f64));
            const idx = row * @as(u32, params.width) + col;
            out[idx] = computeIterationsDD(c_re_dd, c_im_dd, params.max_iter);
        }
    }
}
```

Note: `start_re` as f128 is converted to DD via `DD.fromF64(@floatCast(start_re))`. This loses some precision in the conversion (f128 → f64), but DD's `hi` + `lo` can hold ~30 digits of the original f128 if we carefully split it. For this first pass we accept the conversion loss since the user-supplied center is already f128 from CLI/env and f64-equivalent precision for DD's `hi` is fine — DD's job is to preserve precision *during iteration*, not to faithfully represent the input f128 literal bit-for-bit.

Analogous changes in `computeRegionDirect` (uses `level.step_re`, etc.) and `offsetWorker` (operates on a CacheLevel's points).

## Testing Strategy

### DD primitive tests (`tests/unit/test_dd.zig`)

**Round-trip & construction:**
- `DD.fromF64(x).toF64() == x` for x ∈ {0, 1, -1, π, 1e-300, 1e300, NaN, ±inf}
- `DD.fromF64(0.0)` equals `DD.zero()`

**Add:**
- Exactly-representable: `DD.fromF64(1.0).add(DD.fromF64(2.0)).toF64() == 3.0`
- **Catastrophic cancellation** — critical test: subtract two close f64s, assert DD preserves the difference in `lo`. Construct a DD representing `1.0 - (1.0 - 1e-20)` and assert result is non-zero near 1e-20.
- Associativity (approximate): `(a + b) + c ≈ a + (b + c)` within 1e-30 relative error for random inputs

**Multiply:**
- Exactly-representable: `DD.fromF64(3.0).mul(DD.fromF64(7.0)).toF64() == 21.0`
- **Precision vs f128**: 100 random f64 pairs, assert `DD(a).mul(DD(b)).toF64() ≈ (@as(f128, a) * @as(f128, b)).toF64()` within `|result| * 2e-31`
- Large × small: `DD.fromF64(1e20).mul(DD.fromF64(1e-20)).toF64() ≈ 1.0` within 1e-30 relative

**mulScalar:**
- Matches `mul(a, DD.fromF64(x))` for various scalars — specialization must give equivalent results

**Comparison:**
- `gt`: `DD{hi: 1.0, lo: 1e-20}.gt(DD{hi: 1.0, lo: 0.0}) == true` (only `lo` differs)
- Trichotomy: exactly one of `lt/eq/gt` is true for any pair (a, b)

### Mandelbrot integration tests (`tests/unit/test_mandelbrot_dd.zig` — new file)

**Cross-type equivalence:**

```zig
test "f64 and DD agree at shallow zoom" {
    const points = [_][2]f64{ .{0.25, 0.5}, .{-0.5, 0.6}, .{-0.7435, 0.1314}, .{-2.0, 0.0} };
    for (points) |p| {
        const r_f64 = mandelbrot.computeIterations(p[0], p[1], 256);
        const r_dd = mandelbrot.computeIterationsDD(
            dd.DD.fromF64(p[0]),
            dd.DD.fromF64(p[1]),
            256,
        );
        try expectApproxEqAbs(r_f64, r_dd, 1e-9);
    }
}

test "DD and f128 agree across zoom depths" {
    const zooms = [_]f64{ 1.0, 1e4, 1e8, 1e12, 1e16, 1e20, 1e28 };
    for (zooms) |z| {
        const c_re_f64 = -0.7435 + 0.1 / z;
        const c_im_f64 = 0.1314 + 0.05 / z;
        const r_dd = mandelbrot.computeIterationsDD(
            dd.DD.fromF64(c_re_f64),
            dd.DD.fromF64(c_im_f64),
            500,
        );
        const r_f128 = mandelbrot.computeIterationsF128(
            @as(f128, c_re_f64),
            @as(f128, c_im_f64),
            500,
        );
        if (r_dd == mandelbrot.INTERIOR) {
            try expectEqual(mandelbrot.INTERIOR, r_f128);
        } else {
            try expectApproxEqRel(r_dd, r_f128, 1e-10);
        }
    }
}

test "DD dispatches when zoom exceeds F64_THRESHOLD" {
    mandelbrot.resetDispatchCounters();
    const params = mandelbrot.RegionParams{
        .center_re = -0.7435,
        .center_im = 0.1314,
        .zoom = 1.0e14,
        .width = 20,
        .height = 10,
        .max_iter = 50,
        .aspect_ratio = 0.5,
    };
    const size: usize = 20 * 10;
    var buf: [200]f64 = undefined;
    mandelbrot.computeRowStride(params, &buf, 0, 1);
    try expect(mandelbrot.ddDispatchCount() > 0);
    try expectEqual(@as(u64, 0), mandelbrot.f64DispatchCount());
    _ = size;
}
```

### Benchmark impact

Add an ultra-deep scenario to `tests/benchmark/bench_render.zig`:

```zig
const ultra_deep = try benchmarkScenario(allocator, "Ultra-deep (zoom=1e16)", .{
    .center_re = -0.7435,
    .center_im = 0.1314,
    .zoom = 1.0e16,
    .width = 200,
    .height = 60,
    .max_iter = 1000,
    .aspect_ratio = 0.5,
}, N);
```

This forces DD dispatch. Compare against historical f128 benchmark numbers (from `benchmarks/results.log`) — expected 3-10x speedup.

### Manual visual verification

- `./mandelbrot` + keyboard zoom way in past `F64_THRESHOLD` → verify image remains coherent (no NaN/garbage)
- `./mandelbrot --animate --center-re -0.7435 --center-im 0.1314 --zoom-to 1e18 --duration 8 --exit-after` → ultra-deep animation should render cleanly with DD kicking in at the deeper frames

## File Structure

### New files
- `src/core/dd.zig` — DD type + arithmetic (~80-120 lines)
- `tests/unit/test_dd.zig` — DD primitive tests
- `tests/unit/test_mandelbrot_dd.zig` — cross-type equivalence + dispatch tests

### Modified files
- `src/core/mandelbrot.zig` — comptime helpers, rewritten `computeIterationsT`, new `computeIterationsDD` wrapper, updated dispatch in `computeRowStride` / `computeRegionDirect` / `offsetWorker`, renamed constants and counters
- `build.zig` — add `dd_mod`, wire into `mandelbrot_mod` imports, add `dd_tests` and `mandelbrot_dd_tests` targets
- `tests/unit/test_parallel.zig` — update counter test references (`f128DispatchCount` → `ddDispatchCount`)
- `tests/benchmark/bench_render.zig` — add ultra-deep scenario
- `PLAN.md`, `CODE_MINIMAP.md`, `README.md` — document the change; README's `Precision & Performance` section gets updated to say "hardware f64 with DD fallback for zoom > 1e13" instead of "with f128 fallback"

### Unchanged
- `src/tui/*` — no TUI changes
- `src/main.zig` — no new CLI flags or env vars
- Cache, renderer, coloring, scheduler — DD is invisible to these; they receive f64 iteration counts as before

## Non-Goals

- **Full numeric library** — no `div`, `sqrt`, `log`, trig. Only what Mandelbrot needs.
- **Quad-double** — DD's ~30 digits is enough for any practical terminal fractal. Quad-double is bigger infra for marginal benefit.
- **User-controllable threshold** — `F64_THRESHOLD` stays hardcoded at 1e13. Adding a flag adds surface area without clear use case.
- **Runtime FMA detection** — `@mulAdd` uses `@mulAdd` builtin which Zig resolves to hardware FMA on platforms that have it, or compensated software otherwise. We rely on this rather than hand-rolling runtime detection.
- **Replacing f128 in cumulative state** (`RegionParams.center_re`, `CacheLevel.step_re`, etc.). These stay f128 since they accumulate across many pan/zoom operations where precision is critical. DD is used only in the per-pixel hot loop.

## Expected Result

After implementation:
- All existing tests pass unchanged
- New DD tests pass (unit + mandelbrot integration + bench)
- Deep-zoom rendering is 3-10x faster than the current f128-based fallback
- Fractal detail remains visually correct at zooms up to ~1e28 (DD's practical ceiling on Mandelbrot)
- `./bm` shows a new `Ultra-deep` scenario with DD performance characteristics

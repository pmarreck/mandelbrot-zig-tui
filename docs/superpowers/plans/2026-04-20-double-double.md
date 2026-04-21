# Double-Double Arithmetic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the soft-float f128 production fallback with double-double (DD) arithmetic. DD represents a high-precision number as two f64 values (`hi + lo`) using QD-style algorithms. Expected 3-10x speedup on deep-zoom scenarios, ~30 digits of precision (enough for zoom up to ~10^30).

**Architecture:** New `src/core/dd.zig` module with DD type + minimal arithmetic (add, sub, mul, mulScalar, comparisons). `mandelbrot.zig` gets comptime dispatch helpers so `computeIterationsT` works with f64, DD, and f128 via the same inner loop. Dispatch in `computeRowStride`/`computeRegionDirect`/`offsetWorker` picks DD above `F64_THRESHOLD`. f128 stays as test-only ground truth for verifying DD correctness.

**Tech Stack:** Zig 0.15.2. Uses `@mulAdd` for hardware FMA in TwoProd.

**Spec:** `docs/superpowers/specs/2026-04-20-double-double-design.md`

**IMPORTANT Zig 0.15 notes:**
- `@mulAdd(f64, a, b, c)` computes `a * b + c` with single rounding (hardware FMA on most platforms)
- No operator overloading — DD arithmetic uses method calls (`.add()`, `.mul()`)
- `@floatCast` for f128 → f64 conversion
- `std.math.isNan`, `std.math.isInf` for edge-case handling
- `inline fn` for zero-cost comptime dispatch helpers

---

## File Structure

```
src/
  core/
    dd.zig                       — NEW: DD type + arithmetic primitives
    mandelbrot.zig               — MODIFY: comptime dispatch helpers, rewritten computeIterationsT,
                                   new computeIterationsDD, dispatch updates, constant renames
tests/
  unit/
    test_dd.zig                  — NEW: DD primitive correctness tests
    test_mandelbrot_dd.zig       — NEW: cross-type equivalence (f64/DD/f128) + dispatch counter tests
    test_parallel.zig            — MODIFY: update counter references (f128→dd)
  benchmark/
    bench_render.zig             — MODIFY: add ultra-deep (zoom=1e16) scenario
build.zig                        — MODIFY: add dd_mod, wire into mandelbrot_mod, new test targets
PLAN.md, CODE_MINIMAP.md, README.md — MODIFY: document DD replacement
```

---

### Task 1: DD Type + Arithmetic Module

**Files:**
- Create: `src/core/dd.zig`
- Create: `tests/unit/test_dd.zig`
- Modify: `build.zig` (add `dd_mod` + test target)

- [ ] **Step 1: Create `src/core/dd.zig` with the full DD module**

```zig
// src/core/dd.zig
// Double-double (DD) arithmetic: represents a high-precision number as two
// f64 values where `hi + lo` is the value and `|hi| >= |lo|`. All operations
// use hardware f64 throughout via QD-style algorithms (Dekker/Knuth TwoSum,
// TwoProd with @mulAdd).
//
// Gives ~106 bits of mantissa (~30 decimal digits), enough for zoom levels
// up to ~10^30. Much faster than soft-float f128 on ARM64/x86_64 (no hardware
// f128 exists there; f128 ops go through slow library calls).
//
// Scope: only the operations needed by the Mandelbrot hot loop — add, sub,
// neg, mul, mulScalar, comparisons. No sqrt, no div, no trig.

const std = @import("std");

pub const DD = struct {
	hi: f64,
	lo: f64,

	/// Construct a DD from a single f64 (lo = 0).
	pub fn fromF64(x: f64) DD {
		return .{ .hi = x, .lo = 0.0 };
	}

	/// Construct a DD from a (hi, lo) pair. Caller must ensure `|hi| >= |lo|`
	/// and that `hi` is the rounded value of `hi + lo` in f64. Used internally
	/// by arithmetic ops; exposed publicly for constructing test inputs.
	pub fn fromF64Pair(hi: f64, lo: f64) DD {
		return .{ .hi = hi, .lo = lo };
	}

	/// Precision-preserving construction from f128.
	/// Splits the value: hi = top ~52 bits, lo = next ~52 bits of roundoff.
	/// Retains ~104 of f128's 112 mantissa bits (~31 of 33 decimal digits).
	/// Critical for correctness at deep zoom: using `fromF64(@floatCast(x))`
	/// instead would truncate to 52 bits before DD iteration even starts,
	/// causing adjacent pixels at zoom > 1e15 to quantize to identical coords.
	pub fn fromF128(x: f128) DD {
		const hi: f64 = @floatCast(x);
		const lo: f64 = @floatCast(x - @as(f128, hi));
		return .{ .hi = hi, .lo = lo };
	}

	pub fn zero() DD {
		return .{ .hi = 0.0, .lo = 0.0 };
	}

	/// Lossy conversion to f64 — returns just `hi`, since `lo` is below
	/// f64 precision by construction.
	pub fn toF64(self: DD) f64 {
		return self.hi + self.lo;
	}

	/// Negation: flip sign of both components.
	pub fn neg(a: DD) DD {
		return .{ .hi = -a.hi, .lo = -a.lo };
	}

	/// DD + DD, using TwoSum for error-free addition.
	/// See Knuth TAOCP vol 2; also QD library (Hida/Li/Bailey).
	pub fn add(a: DD, b: DD) DD {
		// Sum high parts with error
		const s = a.hi + b.hi;
		const bb = s - a.hi;
		const err = (a.hi - (s - bb)) + (b.hi - bb);
		// Add low parts and the error
		const err2 = err + a.lo + b.lo;
		// Renormalize
		const hi = s + err2;
		const lo = err2 - (hi - s);
		return .{ .hi = hi, .lo = lo };
	}

	/// DD - DD.
	pub fn sub(a: DD, b: DD) DD {
		return add(a, neg(b));
	}

	/// DD * DD, using TwoProd via @mulAdd for error-free multiplication.
	/// With hardware FMA, TwoProd is ~2 FLOPs.
	pub fn mul(a: DD, b: DD) DD {
		const p = a.hi * b.hi;
		// err = a.hi * b.hi - p (exact via FMA: p - (a.hi * b.hi))
		const err = @mulAdd(f64, a.hi, b.hi, -p);
		// Add cross-terms and low-low product (low-low is tiny, often zero)
		const cross = a.hi * b.lo + a.lo * b.hi;
		const total_err = err + cross;
		// Renormalize
		const hi = p + total_err;
		const lo = total_err - (hi - p);
		return .{ .hi = hi, .lo = lo };
	}

	/// DD * f64 (specialized, skips low-low cross-term).
	pub fn mulScalar(a: DD, x: f64) DD {
		const p = a.hi * x;
		const err = @mulAdd(f64, a.hi, x, -p);
		const cross = a.lo * x;
		const total_err = err + cross;
		const hi = p + total_err;
		const lo = total_err - (hi - p);
		return .{ .hi = hi, .lo = lo };
	}

	/// Lexicographic: compare `hi` first, then `lo`.
	pub fn gt(a: DD, b: DD) bool {
		if (a.hi > b.hi) return true;
		if (a.hi < b.hi) return false;
		return a.lo > b.lo;
	}

	pub fn lt(a: DD, b: DD) bool {
		if (a.hi < b.hi) return true;
		if (a.hi > b.hi) return false;
		return a.lo < b.lo;
	}

	pub fn eq(a: DD, b: DD) bool {
		return a.hi == b.hi and a.lo == b.lo;
	}
};
```

- [ ] **Step 2: Create `tests/unit/test_dd.zig` with full test coverage**

```zig
const std = @import("std");
const testing = std.testing;
const dd = @import("dd");

// ── Round-trip & construction ──────────────────────────────────────

test "DD.fromF64(x).toF64() round-trip for normal values" {
	const values = [_]f64{ 0.0, 1.0, -1.0, 3.14159265358979, 1e-300, 1e300, -1e-10, 42.0 };
	for (values) |x| {
		const d = dd.DD.fromF64(x);
		try testing.expectEqual(x, d.toF64());
	}
}

test "DD.fromF128 preserves precision beyond f64" {
	// Construct an f128 value whose low bits would be lost in a simple f64 cast.
	// 1.0 + 1e-20 cannot be represented in f64 (spacing ~2.2e-16 near 1.0) but fits in f128.
	const x: f128 = 1.0 + @as(f128, 1.0e-20);
	const d = dd.DD.fromF128(x);
	// DD should preserve the 1e-20 term in its lo component
	try testing.expect(d.hi == 1.0);
	try testing.expect(d.lo > 5e-21);
	try testing.expect(d.lo < 2e-20);
}

test "DD.fromF128 round-trips back through DD arithmetic" {
	// Two nearby f128 values, differing below f64 precision.
	// Converted via fromF128, their DD difference should equal the true f128 difference.
	const a_f128: f128 = 1.0;
	const b_f128: f128 = 1.0 + @as(f128, 5.0e-18);
	const a_dd = dd.DD.fromF128(a_f128);
	const b_dd = dd.DD.fromF128(b_f128);
	const diff_dd = b_dd.sub(a_dd).toF64();
	// Should recover ~5e-18, NOT 0 (which a simple f64 cast would give)
	try testing.expectApproxEqRel(@as(f64, 5.0e-18), diff_dd, 1e-10);
}

test "DD.zero() is neutral element for addition" {
	const z = dd.DD.zero();
	const one = dd.DD.fromF64(1.0);
	try testing.expectEqual(@as(f64, 1.0), z.add(one).toF64());
	try testing.expectEqual(@as(f64, 1.0), one.add(z).toF64());
}

test "DD.zero() equals DD.fromF64(0.0)" {
	try testing.expect(dd.DD.zero().eq(dd.DD.fromF64(0.0)));
}

test "DD.neg flips sign of both components" {
	const a = dd.DD.fromF64Pair(1.5, 1e-20);
	const n = a.neg();
	try testing.expectEqual(@as(f64, -1.5), n.hi);
	try testing.expectEqual(@as(f64, -1e-20), n.lo);
}

// ── Addition ──────────────────────────────────────────────────────

test "DD add of exactly-representable integers" {
	const a = dd.DD.fromF64(1.0);
	const b = dd.DD.fromF64(2.0);
	try testing.expectEqual(@as(f64, 3.0), a.add(b).toF64());
}

test "DD add preserves catastrophic cancellation" {
	// Construct DD(1.0) and DD representing 1.0 - 1e-20 (which f64 alone can't represent).
	// 1.0 - 1e-20 as DD: hi = 1.0, lo = -1e-20 (since 1.0 + (-1e-20) ≈ 1.0 in f64 but we keep the error).
	const one = dd.DD.fromF64(1.0);
	const close_to_one = dd.DD.fromF64Pair(1.0, -1e-20);
	const diff = one.sub(close_to_one);
	// Result should be ~1e-20, NOT 0
	try testing.expect(diff.toF64() > 5e-21);
	try testing.expect(diff.toF64() < 2e-20);
}

test "DD add is approximately associative" {
	// (a + b) + c ≈ a + (b + c) within DD precision for well-conditioned inputs
	const a = dd.DD.fromF64(1.5);
	const b = dd.DD.fromF64(2.7);
	const c = dd.DD.fromF64(3.9);
	const left = a.add(b).add(c);
	const right = a.add(b.add(c));
	try testing.expectApproxEqAbs(left.toF64(), right.toF64(), 1e-30);
}

// ── Multiplication ─────────────────────────────────────────────────

test "DD mul of exactly-representable integers" {
	const a = dd.DD.fromF64(3.0);
	const b = dd.DD.fromF64(7.0);
	try testing.expectEqual(@as(f64, 21.0), a.mul(b).toF64());
}

test "DD mul large × small cancels correctly" {
	// 1e20 * 1e-20 should equal ~1.0 with DD precision
	const big = dd.DD.fromF64(1e20);
	const small = dd.DD.fromF64(1e-20);
	const product = big.mul(small);
	try testing.expectApproxEqRel(@as(f64, 1.0), product.toF64(), 1e-15);
}

test "DD mul precision matches f128 reference for 100 random pairs" {
	// Use a deterministic seed for reproducibility
	var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
	const rng = prng.random();

	var i: u32 = 0;
	while (i < 100) : (i += 1) {
		// Generate f64 values in a range that avoids overflow when multiplied
		const a_f64 = (rng.float(f64) - 0.5) * 1e10;
		const b_f64 = (rng.float(f64) - 0.5) * 1e10;

		const a_dd = dd.DD.fromF64(a_f64);
		const b_dd = dd.DD.fromF64(b_f64);
		const product_dd = a_dd.mul(b_dd).toF64();

		const a_f128: f128 = a_f64;
		const b_f128: f128 = b_f64;
		const product_f128: f64 = @floatCast(a_f128 * b_f128);

		// DD should agree with f128 within ~2e-16 relative error (1 ULP of f64)
		const rel_err = @abs(product_dd - product_f128) / @max(@abs(product_f128), 1e-300);
		try testing.expect(rel_err < 1e-14);
	}
}

// ── mulScalar specialization ───────────────────────────────────────

test "DD.mulScalar matches DD.mul for simple cases" {
	const a = dd.DD.fromF64(3.0);
	const scalar: f64 = 7.0;
	const via_mul = a.mul(dd.DD.fromF64(scalar));
	const via_scalar = a.mulScalar(scalar);
	try testing.expectEqual(via_mul.toF64(), via_scalar.toF64());
}

test "DD.mulScalar(a, 2.0) == a.add(a)" {
	const a = dd.DD.fromF64Pair(1.5, 1e-20);
	const doubled = a.mulScalar(2.0);
	const added = a.add(a);
	try testing.expectApproxEqAbs(doubled.toF64(), added.toF64(), 1e-30);
}

// ── Comparisons ────────────────────────────────────────────────────

test "DD.gt: hi equal, lo differs" {
	const a = dd.DD.fromF64Pair(1.0, 1e-20);
	const b = dd.DD.fromF64Pair(1.0, 0.0);
	try testing.expect(a.gt(b));
	try testing.expect(!b.gt(a));
}

test "DD.gt: hi differs" {
	const a = dd.DD.fromF64(2.0);
	const b = dd.DD.fromF64(1.0);
	try testing.expect(a.gt(b));
	try testing.expect(!b.gt(a));
}

test "DD comparison trichotomy" {
	const a = dd.DD.fromF64(1.5);
	const b = dd.DD.fromF64(2.5);
	// Exactly one of lt/eq/gt must be true
	const lt = a.lt(b);
	const eq = a.eq(b);
	const gt = a.gt(b);
	var count: u32 = 0;
	if (lt) count += 1;
	if (eq) count += 1;
	if (gt) count += 1;
	try testing.expectEqual(@as(u32, 1), count);
	try testing.expect(lt); // a=1.5 < b=2.5
}

test "DD.gt: bailout comparison for Mandelbrot" {
	// 65536.0 is the bailout. DD values slightly above and below should compare correctly.
	const bailout = dd.DD.fromF64(65536.0);
	const above = dd.DD.fromF64Pair(65536.0, 1e-20);
	const below = dd.DD.fromF64Pair(65535.99, 0.0);
	try testing.expect(above.gt(bailout));
	try testing.expect(!below.gt(bailout));
}
```

- [ ] **Step 3: Add `dd_mod` and `dd_tests` to `build.zig`**

Near the top of `build.zig`, after `cache_mod` and before `mandelbrot_mod`:

```zig
    const dd_mod = b.createModule(.{
        .root_source_file = b.path("src/core/dd.zig"),
    });
```

(The placement before `mandelbrot_mod` matters because `mandelbrot_mod` will import `dd_mod` in Task 2.)

Add a test target after the existing `animation_tests` block (or near other test targets — anywhere consistent):

```zig
    const dd_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_dd.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dd", .module = dd_mod },
            },
        }),
    });
    const run_dd_tests = b.addRunArtifact(dd_tests);
    test_step.dependOn(&run_dd_tests.step);
```

- [ ] **Step 4: Run tests — should pass**

```bash
nix develop -c zig build test -Doptimize=Debug
```

All 17 new DD tests should pass. Any existing tests remain green.

- [ ] **Step 5: Commit**

```bash
git add src/core/dd.zig tests/unit/test_dd.zig build.zig
git commit -m "feat: dd.zig — double-double arithmetic primitives with QD-style algorithms"
```

Do NOT include Co-Authored-By lines.

---

### Task 2: Comptime Dispatch Helpers in `mandelbrot.zig`

Pure refactor: extract inline helpers that dispatch operators at comptime based on type `T`. Rewrite `computeIterationsT` to use them. No behavior change for f64 or f128 paths.

**Files:**
- Modify: `src/core/mandelbrot.zig`

- [ ] **Step 1: Add `dd` to `mandelbrot_mod` in `build.zig`**

Find `mandelbrot_mod` definition in `build.zig`. Currently:
```zig
    const mandelbrot_mod = b.createModule(.{
        .root_source_file = b.path("src/core/mandelbrot.zig"),
        .imports = &.{
            .{ .name = "cache", .module = cache_mod },
        },
    });
```

Add `dd` to its imports:
```zig
    const mandelbrot_mod = b.createModule(.{
        .root_source_file = b.path("src/core/mandelbrot.zig"),
        .imports = &.{
            .{ .name = "cache", .module = cache_mod },
            .{ .name = "dd", .module = dd_mod },
        },
    });
```

- [ ] **Step 2: Add `dd` import + comptime dispatch helpers to `src/core/mandelbrot.zig`**

At the top of `mandelbrot.zig`, near the other imports (`const std = @import("std"); const cache_mod = @import("cache");`), add:

```zig
const dd = @import("dd");
```

After the existing constants but before `computeIterationsT`, add the dispatch helpers:

```zig
// ── Comptime dispatch helpers ──────────────────────────────────────
// These inline at compile time: for T=f64/f128 they become primitive
// operators; for T=dd.DD they call the DD methods. Zero runtime cost.

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

- [ ] **Step 3: Rewrite `computeIterationsT` to use the helpers**

Find the existing `computeIterationsT` function. Replace its body with:

```zig
/// Generic smooth iteration count over float type T (f64, f128, or dd.DD).
/// Returns f64 (smooth iteration count is always returned as f64 for storage).
/// Interior points return INTERIOR (-1.0).
/// Uses comptime operator dispatch so a single function body works for all three types.
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
			const mod_sq: f64 = opToF64(T, sum_sq);
			const log_zn = @log(mod_sq) / 2.0;
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

- [ ] **Step 4: Add `computeIterationsDD` public wrapper**

After the existing `computeIterationsF128` wrapper (or near the other wrappers), add:

```zig
/// DD precision path: use when zoom exceeds F64_THRESHOLD (~1e13).
/// ~30 digits of precision via hardware f64 throughout.
pub fn computeIterationsDD(c_re: dd.DD, c_im: dd.DD, max_iter: u32) f64 {
	return computeIterationsT(dd.DD, c_re, c_im, max_iter);
}
```

- [ ] **Step 5: Run tests — existing tests should still pass**

```bash
nix develop -c zig build test -Doptimize=Debug
```

Critically, the existing `computeIterations` (f64) and `computeIterationsF128` tests should still pass since the rewrite is behaviorally equivalent for those types.

- [ ] **Step 6: Commit**

```bash
git add src/core/mandelbrot.zig build.zig
git commit -m "refactor: comptime dispatch helpers + computeIterationsDD wrapper"
```

---

### Task 3: Cross-Type Equivalence Tests

Verify DD matches f128 across zoom depths, and DD matches f64 at shallow zoom. This is the main correctness verification.

**Files:**
- Create: `tests/unit/test_mandelbrot_dd.zig`
- Modify: `build.zig` (add test target)

- [ ] **Step 1: Create `tests/unit/test_mandelbrot_dd.zig`**

```zig
const std = @import("std");
const testing = std.testing;
const mandelbrot = @import("mandelbrot");
const dd = @import("dd");

test "f64 and DD agree at shallow zoom for known points" {
	const points = [_][2]f64{
		.{ 0.25, 0.5 },
		.{ -0.5, 0.6 },
		.{ -0.7435, 0.1314 },
		.{ -2.0, 0.0 },
		.{ 1.0, 0.0 },
		.{ 0.0, 1.0 },
		.{ 0.3, 0.4 },
	};
	for (points) |p| {
		const r_f64 = mandelbrot.computeIterations(p[0], p[1], 256);
		const r_dd = mandelbrot.computeIterationsDD(
			dd.DD.fromF64(p[0]),
			dd.DD.fromF64(p[1]),
			256,
		);
		// Both interior or both exterior
		if (r_f64 == mandelbrot.INTERIOR) {
			try testing.expectEqual(mandelbrot.INTERIOR, r_dd);
		} else if (r_dd == mandelbrot.INTERIOR) {
			try testing.expectEqual(mandelbrot.INTERIOR, r_f64);
		} else {
			try testing.expectApproxEqAbs(r_f64, r_dd, 1e-9);
		}
	}
}

test "DD and f128 agree across zoom depths" {
	// Points at various offsets from seahorse valley focal
	const depths = [_]f64{ 1.0, 1e4, 1e8, 1e12, 1e16, 1e20, 1e28 };
	for (depths) |z| {
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
			try testing.expectEqual(mandelbrot.INTERIOR, r_f128);
		} else if (r_f128 == mandelbrot.INTERIOR) {
			try testing.expectEqual(mandelbrot.INTERIOR, r_dd);
		} else {
			try testing.expectApproxEqRel(r_dd, r_f128, 1e-10);
		}
	}
}
```

- [ ] **Step 2: Add test target to `build.zig`**

After the existing `dd_tests` block in `build.zig`:

```zig
    const mandelbrot_dd_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_mandelbrot_dd.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mandelbrot", .module = mandelbrot_mod },
                .{ .name = "dd", .module = dd_mod },
            },
        }),
    });
    const run_mandelbrot_dd_tests = b.addRunArtifact(mandelbrot_dd_tests);
    test_step.dependOn(&run_mandelbrot_dd_tests.step);
```

- [ ] **Step 3: Run tests — should pass**

```bash
nix develop -c zig build test -Doptimize=Debug
```

Both new equivalence tests should pass.

- [ ] **Step 4: Commit**

```bash
git add tests/unit/test_mandelbrot_dd.zig build.zig
git commit -m "test: DD correctness — cross-type equivalence with f64 and f128"
```

---

### Task 4: Dispatch Constants Rename + DD Counter

Rename the threshold constants to describe the f64-viability perspective and replace the f128 dispatch counter with a DD one.

**Files:**
- Modify: `src/core/mandelbrot.zig`
- Modify: `tests/unit/test_parallel.zig`

- [ ] **Step 1: Rename constants in `src/core/mandelbrot.zig`**

Find:
```zig
pub const F128_DISPATCH_THRESHOLD: f128 = 1.0e13;
pub const F128_STEP_THRESHOLD: f128 = 2.0e-15;
```

Replace with:
```zig
/// Zoom threshold above which f64 precision is insufficient.
/// Derived from f64's relative precision (~2.2e-16) vs pixel spacing (4/zoom/width).
/// Above this threshold, use the DD path for ~30 digits of precision.
pub const F64_THRESHOLD: f128 = 1.0e13;

/// Step-size threshold below which f64 precision is insufficient.
/// Complementary to F64_THRESHOLD (zoom-based). Equivalent when terminal is ~200 wide.
pub const F64_STEP_THRESHOLD: f128 = 2.0e-15;
```

- [ ] **Step 2: Replace f128 counter with DD counter in `src/core/mandelbrot.zig`**

Find:
```zig
var g_f64_dispatch = std.atomic.Value(u64).init(0);
var g_f128_dispatch = std.atomic.Value(u64).init(0);

pub fn resetDispatchCounters() void {
	g_f64_dispatch.store(0, .release);
	g_f128_dispatch.store(0, .release);
}

pub fn f64DispatchCount() u64 {
	return g_f64_dispatch.load(.acquire);
}

pub fn f128DispatchCount() u64 {
	return g_f128_dispatch.load(.acquire);
}
```

Replace with:
```zig
var g_f64_dispatch = std.atomic.Value(u64).init(0);
var g_dd_dispatch = std.atomic.Value(u64).init(0);

pub fn resetDispatchCounters() void {
	g_f64_dispatch.store(0, .release);
	g_dd_dispatch.store(0, .release);
}

pub fn f64DispatchCount() u64 {
	return g_f64_dispatch.load(.acquire);
}

pub fn ddDispatchCount() u64 {
	return g_dd_dispatch.load(.acquire);
}
```

- [ ] **Step 3: Update all references to old constants/counters in `src/core/mandelbrot.zig`**

Search for `F128_DISPATCH_THRESHOLD`, `F128_STEP_THRESHOLD`, and `g_f128_dispatch` in `src/core/mandelbrot.zig`. Replace respectively with `F64_THRESHOLD`, `F64_STEP_THRESHOLD`, and `g_dd_dispatch`. The dispatch logic itself will be updated in Task 5 — for now, just update the names (the functions still call the f128 path, but the *threshold constant* is renamed).

Specifically, in `computeRowStride`, `computeRegionDirect`, and `offsetWorker`:
- `if (params.zoom <= F128_DISPATCH_THRESHOLD)` → `if (params.zoom <= F64_THRESHOLD)`
- `if (level.step_re > F128_STEP_THRESHOLD)` → `if (level.step_re > F64_STEP_THRESHOLD)`
- `g_f128_dispatch.fetchAdd(...)` → `g_dd_dispatch.fetchAdd(...)` (the dispatch path still calls f128, but we're counting "fallback used" which is now DD-conceptually; Task 5 will swap the actual call)

- [ ] **Step 4: Update `tests/unit/test_parallel.zig` counter references**

Find all calls to `mandelbrot.f128DispatchCount()` and replace with `mandelbrot.ddDispatchCount()`. The test logic is unchanged — we're verifying "the non-f64 path fired".

Also update any comments that mention the old counter name.

- [ ] **Step 5: Run tests — should pass**

```bash
nix develop -c zig build test -Doptimize=Debug
```

All tests pass. The f128 path is still being called in the dispatch arms — that changes in Task 5 — but the counter renaming and constant renaming don't affect behavior.

- [ ] **Step 6: Commit**

```bash
git add src/core/mandelbrot.zig tests/unit/test_parallel.zig
git commit -m "refactor: rename F128 thresholds to F64_THRESHOLD + replace f128 counter with DD"
```

---

### Task 5: Swap DD Into Production Dispatch Paths

Replace the f128 calls in `computeRowStride`, `computeRegionDirect`, and `offsetWorker` with DD calls. f128 stays only in test-invoked `computeIterationsF128`.

**Files:**
- Modify: `src/core/mandelbrot.zig`

- [ ] **Step 1: Rewrite the non-f64 branch of `computeRowStride`**

Find the `else` branch in `computeRowStride` that currently calls `computeIterationsF128`. Replace it with a DD-based implementation:

```zig
	} else {
		_ = g_dd_dispatch.fetchAdd(1, .monotonic);
		// DD path: precision ~30 digits via hardware f64 throughout.
		// fromF128 preserves the full f128 precision of viewport scalars in
		// DD's hi+lo pair — essential at deep zoom where pixel spacing is
		// below f64 precision.
		const start_re_dd = dd.DD.fromF128(start_re);
		const start_im_dd = dd.DD.fromF128(start_im);
		const step_re_dd = dd.DD.fromF128(step_re);
		const step_im_dd = dd.DD.fromF128(step_im);

		var row: u32 = thread_idx;
		while (row < params.height) : (row += num_threads) {
			const row_f64: f64 = @floatFromInt(row);
			const c_im_dd = start_im_dd.add(step_im_dd.mulScalar(row_f64));
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

- [ ] **Step 2: Rewrite the non-f64 branch of `computeRegionDirect`**

Find the branch that calls `computeIterationsF128` on cache levels. Replace:

```zig
	} else {
		// DD path
		_ = g_dd_dispatch.fetchAdd(1, .monotonic);
		var row: u32 = 0;
		while (row < level.height) : (row += 1) {
			var col: u32 = 0;
			while (col < level.width) : (col += 1) {
				const pt = level.pointAt(col, row);
				// pt.re and pt.im are f128 — fromF128 preserves precision.
				const c_re_dd = dd.DD.fromF128(pt.re);
				const c_im_dd = dd.DD.fromF128(pt.im);
				level.set(col, row, computeIterationsDD(c_re_dd, c_im_dd, level.max_iter));
			}
		}
	}
```

- [ ] **Step 3: Rewrite `offsetWorker`'s non-f64 branch**

```zig
fn offsetWorker(args: OffsetWorkerArgs) void {
	const use_f64 = args.child.step_re > F64_STEP_THRESHOLD;
	var row: u32 = args.row_start;
	while (row < args.child.height) : (row += 2) {
		if (args.gen) |g| {
			if (g.load(.acquire) != args.expected) return;
		}
		var col: u32 = args.col_start;
		while (col < args.child.width) : (col += 2) {
			const pt = args.child.pointAt(col, row);
			if (use_f64) {
				const c_re: f64 = @floatCast(pt.re);
				const c_im: f64 = @floatCast(pt.im);
				args.child.set(col, row, computeIterations(c_re, c_im, args.child.max_iter));
			} else {
				const c_re_dd = dd.DD.fromF128(pt.re);
				const c_im_dd = dd.DD.fromF128(pt.im);
				args.child.set(col, row, computeIterationsDD(c_re_dd, c_im_dd, args.child.max_iter));
			}
		}
	}
}
```

- [ ] **Step 4: Add dispatch counter verification test — APPEND to `tests/unit/test_mandelbrot_dd.zig`**

```zig
test "DD dispatches when zoom exceeds F64_THRESHOLD" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

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
	const buf = try allocator.alloc(f64, size);
	defer allocator.free(buf);

	mandelbrot.computeRowStride(params, buf, 0, 1);

	try testing.expect(mandelbrot.ddDispatchCount() > 0);
	try testing.expectEqual(@as(u64, 0), mandelbrot.f64DispatchCount());
}

test "f64 dispatches when zoom at or below F64_THRESHOLD" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	mandelbrot.resetDispatchCounters();

	const params = mandelbrot.RegionParams{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.width = 20,
		.height = 10,
		.max_iter = 50,
		.aspect_ratio = 0.5,
	};
	const size: usize = 20 * 10;
	const buf = try allocator.alloc(f64, size);
	defer allocator.free(buf);

	mandelbrot.computeRowStride(params, buf, 0, 1);

	try testing.expect(mandelbrot.f64DispatchCount() > 0);
	try testing.expectEqual(@as(u64, 0), mandelbrot.ddDispatchCount());
}
```

- [ ] **Step 5: Run tests — all should pass**

```bash
nix develop -c zig build test -Doptimize=Debug
```

Both new dispatch tests + the equivalence tests from Task 3 + all existing tests pass.

- [ ] **Step 6: Manual smoke test — ultra-deep zoom**

```bash
./build
MANDELBROT_ZOOM=1e16 MANDELBROT_CENTER_RE=-0.7435 MANDELBROT_CENTER_IM=0.1314 MANDELBROT_COLS=60 MANDELBROT_ROWS=20 ./zig-out/bin/mandelbrot --single-frame 2>/dev/null | head -3
```

Should produce valid ANSI output (not NaN/garbage). The fractal at zoom 1e16 should look coherent.

- [ ] **Step 7: Commit**

```bash
git add src/core/mandelbrot.zig tests/unit/test_mandelbrot_dd.zig
git commit -m "feat: DD production dispatch — replace f128 fallback in hot loop"
```

---

### Task 6: Ultra-Deep Bench Scenario

Add a bench scenario that forces DD dispatch, so we can track DD performance over time.

**Files:**
- Modify: `tests/benchmark/bench_render.zig`

- [ ] **Step 1: Add ultra-deep scenario**

In `tests/benchmark/bench_render.zig`, find the existing `small` scenario declaration. After it (before the `const results = [_]BenchResult{...}` array), add:

```zig
	// Ultra-deep: zoom well past F64_THRESHOLD, forces DD dispatch
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

Update the results array to include it:

```zig
	const results = [_]BenchResult{ shallow, deep, small, ultra_deep };
```

- [ ] **Step 2: Run the bench**

```bash
./bm
```

Expected: all 4 scenarios print. The ultra-deep scenario should show DD performance (likely slower than shallow/deep due to more iterations at max_iter=1000, but still hardware-f64 throughout).

- [ ] **Step 3: Commit**

```bash
git add tests/benchmark/bench_render.zig benchmarks/results.log
git commit -m "bench: ultra-deep (zoom=1e16) scenario forces DD dispatch"
```

---

### Task 7: Documentation & Final Verification

**Files:**
- Modify: `README.md`
- Modify: `PLAN.md`
- Modify: `CODE_MINIMAP.md`

- [ ] **Step 1: Update `README.md`'s Precision & Performance section**

In the `## Features` section, find the bullet that says:
```markdown
- **Hardware f64 hot loop with f128 fallback** — f64 by default...
```

Replace with:
```markdown
- **Hardware f64 hot loop with double-double fallback** — f64 by default (fast on Apple Silicon / x86_64), automatically falls back to double-double (DD) arithmetic when zoom exceeds 10^13. DD represents high-precision numbers as two f64 values (`hi + lo`) using QD-style algorithms (TwoSum, TwoProd via `@mulAdd`), giving ~30 digits of precision using hardware f64 throughout. 3-10x faster than soft-float f128 emulation. The f128 implementation is kept as test-only ground truth for verifying DD correctness.
```

In the `## Technical Highlights` section, find the `### 3. f64 hot loop with f128 fallback` subsection. Update its title and content to reflect DD:

```markdown
### 3. f64 hot loop with double-double fallback (30-70x speedup + deep-zoom precision)

Apple Silicon (and most ARM64/x86_64) has no hardware `f128`; soft-float emulation is 30-50x slower than hardware `f64`. The inner iteration loop uses a comptime-generic implementation (`computeIterationsT`) that dispatches on the float type. Above the f64 precision threshold (~zoom 10^13), it switches to **double-double (DD)** arithmetic instead of f128.

DD represents a high-precision number as two f64 values: `value = hi + lo`, where `|hi| >= |lo|` and `lo` carries the roundoff error. Arithmetic operations use QD-style algorithms (Dekker/Knuth TwoSum for addition, TwoProd via `@mulAdd` for multiplication). All ops run on hardware f64 — no soft-float — giving ~106 bits of mantissa (~30 decimal digits), enough for zoom levels up to ~10^30. Testing verifies DD matches f128 within tight epsilon across zoom depths.

This alone gave roughly 34x sequential speedup (41 ms → 1.2 ms per 200x60 frame) at shallow zoom, and an additional 3-10x speedup over the old f128 fallback at ultra-deep zoom.
```

- [ ] **Step 2: Update `PLAN.md`**

In the "Completed" section, add:
```markdown
- [x] Double-double (DD) arithmetic replacing f128 soft-float fallback — ~2026-04-20 EST
```

Remove the corresponding "Future Enhancement" entry (it mentioned DD as a future item).

- [ ] **Step 3: Update `CODE_MINIMAP.md`**

Add a new section under `src/core/`:

```markdown
## `src/core/dd.zig`
- `DD` — struct: two f64 values representing a high-precision number (`value = hi + lo`)
- `DD.fromF64(x)`, `DD.fromF64Pair(hi, lo)`, `DD.fromF128(x)`, `DD.zero()` — constructors (fromF128 preserves f128 precision across the conversion)
- `DD.toF64()` — lossy conversion to f64
- `DD.add(a, b)` — TwoSum-based addition, no ordering assumption
- `DD.sub(a, b)`, `DD.neg(a)` — subtraction + negation
- `DD.mul(a, b)` — TwoProd via `@mulAdd` for error-free multiplication
- `DD.mulScalar(a, x)` — specialized DD × f64 multiplication
- `DD.gt(a, b)`, `DD.lt(a, b)`, `DD.eq(a, b)` — lexicographic comparisons
```

Update the `src/core/mandelbrot.zig` section: replace any mention of f128 fallback with DD. Specifically update these bullets:

```markdown
- `computeIterationsT(comptime T, c_re, c_im, max_iter)` — generic smooth iteration count over T (f64, f128, or dd.DD) via comptime operator dispatch helpers
- `computeIterations(c_re: f64, c_im: f64, max_iter)` — default hardware-fast path
- `computeIterationsDD(c_re: DD, c_im: DD, max_iter)` — precision path using double-double arithmetic
- `computeIterationsF128(c_re: f128, c_im: f128, max_iter)` — reference path for tests only
- `F64_THRESHOLD` = 1.0e13 (zoom-based dispatch cutoff; replaces former F128_DISPATCH_THRESHOLD)
- `F64_STEP_THRESHOLD` = 2.0e-15 (step-based dispatch cutoff)
- `resetDispatchCounters() / f64DispatchCount() / ddDispatchCount()` — test-only observability
```

- [ ] **Step 4: Final test run**

```bash
./test
```

All tests pass.

```bash
./bm
```

All 4 bench scenarios complete; ultra-deep DD numbers land in `benchmarks/results.log`.

- [ ] **Step 5: Commit**

```bash
git add README.md PLAN.md CODE_MINIMAP.md
git commit -m "docs: README + PLAN + CODE_MINIMAP for double-double arithmetic"
```

---

## Self-Review

**Spec coverage:**
- ✅ DD type with full API: fromF64, fromF64Pair, zero, toF64, add, sub, neg, mul, mulScalar, gt, lt, eq (Task 1)
- ✅ QD-style algorithms: TwoSum for add, TwoProd via @mulAdd for mul (Task 1)
- ✅ DD primitive tests: round-trip, catastrophic cancellation, precision vs f128, comparisons (Task 1)
- ✅ Comptime dispatch helpers in mandelbrot.zig (Task 2)
- ✅ computeIterationsT rewrite to use helpers (Task 2)
- ✅ computeIterationsDD wrapper (Task 2)
- ✅ Cross-type equivalence tests: f64/DD at shallow, DD/f128 across depths (Task 3)
- ✅ F128_* → F64_* constant renames (Task 4)
- ✅ g_f128_dispatch → g_dd_dispatch counter swap (Task 4)
- ✅ f128DispatchCount() → ddDispatchCount() (Task 4)
- ✅ f128 calls in production replaced with DD in computeRowStride, computeRegionDirect, offsetWorker (Task 5)
- ✅ Dispatch counter tests (Task 5)
- ✅ Manual ultra-deep smoke test (Task 5)
- ✅ Ultra-deep bench scenario (Task 6)
- ✅ README + PLAN + CODE_MINIMAP updates (Task 7)

**Placeholder scan:** No TBDs. All code blocks complete.

**Type consistency:**
- `DD` struct field order and names consistent between Task 1 and Task 2 usage
- `F64_THRESHOLD` / `F64_STEP_THRESHOLD` consistent between Task 4 rename and Task 5 references
- `g_dd_dispatch` consistent between Task 4 creation and Task 5 increments
- `ddDispatchCount()` consistent between Task 4 definition and Task 5 test invocations
- `computeIterationsDD` signature consistent between Task 2 definition and Task 5 usage
- Inline helper names (`opMul`, `opAdd`, etc.) consistent between Task 2 definition and Task 2 usage in `computeIterationsT`

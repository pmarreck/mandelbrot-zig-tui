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

test "DD.fromF128 preserves precision beyond f64" {
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
	const a_f128: f128 = 1.0;
	const b_f128: f128 = 1.0 + @as(f128, 5.0e-18);
	const a_dd = dd.DD.fromF128(a_f128);
	const b_dd = dd.DD.fromF128(b_f128);
	const diff_dd = b_dd.sub(a_dd).toF64();
	// Should recover ~5e-18, NOT 0 (which a simple f64 cast would give)
	try testing.expectApproxEqRel(@as(f64, 5.0e-18), diff_dd, 1e-10);
}

// ── Addition ──────────────────────────────────────────────────────

test "DD add of exactly-representable integers" {
	const a = dd.DD.fromF64(1.0);
	const b = dd.DD.fromF64(2.0);
	try testing.expectEqual(@as(f64, 3.0), a.add(b).toF64());
}

test "DD add preserves catastrophic cancellation" {
	// Construct DD representing 1.0 - 1e-20, which f64 alone cannot represent.
	const one = dd.DD.fromF64(1.0);
	const close_to_one = dd.DD.fromF64Pair(1.0, -1e-20);
	const diff = one.sub(close_to_one);
	// Result should be ~1e-20, NOT 0
	try testing.expect(diff.toF64() > 5e-21);
	try testing.expect(diff.toF64() < 2e-20);
}

test "DD add is approximately associative" {
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

test "DD mul large * small cancels correctly" {
	// 1e20 * 1e-20 should equal ~1.0 with DD precision
	const big = dd.DD.fromF64(1e20);
	const small = dd.DD.fromF64(1e-20);
	const product = big.mul(small);
	try testing.expectApproxEqRel(@as(f64, 1.0), product.toF64(), 1e-15);
}

test "DD mul precision matches f128 reference for 100 random pairs" {
	var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
	const rng = prng.random();

	var i: u32 = 0;
	while (i < 100) : (i += 1) {
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
	const lt = a.lt(b);
	const eq = a.eq(b);
	const gt = a.gt(b);
	var count: u32 = 0;
	if (lt) count += 1;
	if (eq) count += 1;
	if (gt) count += 1;
	try testing.expectEqual(@as(u32, 1), count);
	try testing.expect(lt);
}

test "DD.gt: bailout comparison for Mandelbrot" {
	const bailout = dd.DD.fromF64(65536.0);
	const above = dd.DD.fromF64Pair(65536.0, 1e-20);
	const below = dd.DD.fromF64Pair(65535.99, 0.0);
	try testing.expect(above.gt(bailout));
	try testing.expect(!below.gt(bailout));
}

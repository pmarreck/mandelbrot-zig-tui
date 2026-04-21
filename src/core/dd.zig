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

	/// Lossy conversion to f64 — returns the sum of hi and lo.
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
		const s = a.hi + b.hi;
		const bb = s - a.hi;
		const err = (a.hi - (s - bb)) + (b.hi - bb);
		const err2 = err + a.lo + b.lo;
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
		const err = @mulAdd(f64, a.hi, b.hi, -p);
		const cross = a.hi * b.lo + a.lo * b.hi;
		const total_err = err + cross;
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

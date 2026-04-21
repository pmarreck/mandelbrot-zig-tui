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

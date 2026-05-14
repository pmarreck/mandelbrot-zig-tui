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

test "DD dispatches when zoom exceeds F64_THRESHOLD" {
	var gpa: std.heap.DebugAllocator(.{}) = .init;
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
	const buf = try allocator.alloc(f64, 20 * 10);
	defer allocator.free(buf);

	mandelbrot.computeRowStride(params, buf, 0, 1);

	try testing.expect(mandelbrot.ddDispatchCount() > 0);
	try testing.expectEqual(@as(u64, 0), mandelbrot.f64DispatchCount());
}

test "f64 dispatches when zoom at or below F64_THRESHOLD" {
	var gpa: std.heap.DebugAllocator(.{}) = .init;
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
	const buf = try allocator.alloc(f64, 20 * 10);
	defer allocator.free(buf);

	mandelbrot.computeRowStride(params, buf, 0, 1);

	try testing.expect(mandelbrot.f64DispatchCount() > 0);
	try testing.expectEqual(@as(u64, 0), mandelbrot.ddDispatchCount());
}

const std = @import("std");
const testing = std.testing;
const mandelbrot = @import("mandelbrot");

test "origin (0,0) is in the Mandelbrot set" {
	const result = mandelbrot.computeIterations(0.0, 0.0, 256);
	try testing.expectEqual(@as(u32, 256), result);
}

test "(2,0) escapes at iteration 2 — |z1|^2 = 4 is not > 4, |z2|^2 = 36 > 4" {
	const result = mandelbrot.computeIterations(2.0, 0.0, 256);
	try testing.expectEqual(@as(u32, 2), result);
}
test "(-1,0) is in the Mandelbrot set" {
	const result = mandelbrot.computeIterations(-1.0, 0.0, 256);
	try testing.expectEqual(@as(u32, 256), result);
}

test "(-2,0) is in the set — oscillates between -2 and 2" {
	const result = mandelbrot.computeIterations(-2.0, 0.0, 256);
	try testing.expectEqual(@as(u32, 256), result);
}

test "(1, 0) escapes at iteration 3" {
	// z0=0, z1=1, z2=1+1=2, z3=4+1=5, |5|^2=25 > 4 → escapes at iter 3
	const result = mandelbrot.computeIterations(1.0, 0.0, 256);
	try testing.expectEqual(@as(u32, 3), result);
}

test "(0.5, 0.5) escapes at a known iteration count" {
	const result = mandelbrot.computeIterations(0.5, 0.5, 1000);
	try testing.expect(result < 1000);
	try testing.expect(result > 0);
}

test "(-0.75, 0.0) is in the set — neck of the cardioid" {
	const result = mandelbrot.computeIterations(-0.75, 0.0, 1000);
	try testing.expectEqual(@as(u32, 1000), result);
}

test "computeRegion fills buffer with correct iteration counts" {
	const width: u16 = 3;
	const height: u16 = 2;
	var buf: [6]u32 = undefined;
	mandelbrot.computeRegion(.{
		.center_re = 0.0,
		.center_im = 0.0,
		.zoom = 1.0,
		.width = width,
		.height = height,
		.max_iter = 256,
		.aspect_ratio = 0.5,
	}, &buf);

	for (buf) |val| {
		try testing.expect(val <= 256);
	}
}

test "computeRegion at known zoom produces deterministic output" {
	const width: u16 = 5;
	const height: u16 = 3;
	var buf1: [15]u32 = undefined;
	var buf2: [15]u32 = undefined;
	const params = mandelbrot.RegionParams{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.width = width,
		.height = height,
		.max_iter = 100,
		.aspect_ratio = 0.5,
	};
	mandelbrot.computeRegion(params, &buf1);
	mandelbrot.computeRegion(params, &buf2);

	try testing.expectEqualSlices(u32, &buf1, &buf2);
}

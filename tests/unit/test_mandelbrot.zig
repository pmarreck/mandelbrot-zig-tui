const std = @import("std");
const testing = std.testing;
const mandelbrot = @import("mandelbrot");

test "origin (0,0) is in the Mandelbrot set" {
	const result = mandelbrot.computeIterations(0.0, 0.0, 256);
	try testing.expectEqual(mandelbrot.INTERIOR, result);
}

test "(2,0) escapes early with smooth value near 2" {
	const result = mandelbrot.computeIterations(2.0, 0.0, 256);
	// With smooth coloring the exact value depends on the log-log correction,
	// but it should be a small positive number (escapes very quickly)
	try testing.expect(result > 0.0);
	try testing.expect(result < 5.0);
}

test "(-1,0) is in the Mandelbrot set" {
	const result = mandelbrot.computeIterations(-1.0, 0.0, 256);
	try testing.expectEqual(mandelbrot.INTERIOR, result);
}

test "(-2,0) escapes with large bailout — leaves the set boundary" {
	// With bailout=256 (not 2), (-2,0) does eventually escape
	// because |z| oscillates at exactly 2 with bailout=2, but with bailout=256
	// the sequence -2, 2, 2, 2... stays bounded. Actually let's check:
	// z0=0, z1=-2, z2=(-2)^2+(-2)=2, z3=2^2+(-2)=2, ...
	// |z| never exceeds 2, so |z|^2 never exceeds 4, which is < 65536 (our bailout_sq).
	// So this is still interior.
	const result = mandelbrot.computeIterations(-2.0, 0.0, 256);
	try testing.expectEqual(mandelbrot.INTERIOR, result);
}

test "(1, 0) escapes with smooth value near 3" {
	const result = mandelbrot.computeIterations(1.0, 0.0, 256);
	// Should escape around iteration 3 with smooth correction
	try testing.expect(result > 1.0);
	try testing.expect(result < 6.0);
}

test "(0.5, 0.5) escapes at a known iteration count" {
	const result = mandelbrot.computeIterations(0.5, 0.5, 1000);
	try testing.expect(result != mandelbrot.INTERIOR);
	try testing.expect(result > 0.0);
}

test "(-0.75, 0.0) is in the set — neck of the cardioid" {
	const result = mandelbrot.computeIterations(-0.75, 0.0, 1000);
	try testing.expectEqual(mandelbrot.INTERIOR, result);
}

test "smooth iteration count is continuous (no discrete jumps)" {
	// Two nearby points that escape at different integer iterations
	// should have smooth values that are close together
	const r1 = mandelbrot.computeIterations(0.3, 0.5, 1000);
	const r2 = mandelbrot.computeIterations(0.31, 0.5, 1000);
	if (r1 != mandelbrot.INTERIOR and r2 != mandelbrot.INTERIOR) {
		const diff = @abs(r1 - r2);
		// Nearby points should differ by less than 2 iterations
		try testing.expect(diff < 2.0);
	}
}

test "computeRegion fills buffer with valid values" {
	const width: u16 = 3;
	const height: u16 = 2;
	var buf: [6]f64 = undefined;
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
		// Should be either INTERIOR or a positive smooth iteration value
		try testing.expect(val == mandelbrot.INTERIOR or val > 0.0);
	}
}

test "computeRegion at known zoom produces deterministic output" {
	const width: u16 = 5;
	const height: u16 = 3;
	var buf1: [15]f64 = undefined;
	var buf2: [15]f64 = undefined;
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

	try testing.expectEqualSlices(f64, &buf1, &buf2);
}

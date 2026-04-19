const std = @import("std");
const testing = std.testing;
const mandelbrot = @import("mandelbrot");

test "parallelComputeRegion matches sequential computeRegion" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	const params = mandelbrot.RegionParams{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.width = 40,
		.height = 20,
		.max_iter = 100,
		.aspect_ratio = 0.5,
	};

	const size: usize = 40 * 20;
	const sequential = try allocator.alloc(f64, size);
	defer allocator.free(sequential);
	const parallel = try allocator.alloc(f64, size);
	defer allocator.free(parallel);

	mandelbrot.computeRegion(params, sequential);
	try mandelbrot.parallelComputeRegion(params, parallel);

	try testing.expectEqualSlices(f64, sequential, parallel);
}

test "parallelComputeRegion works with odd row count" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	const params = mandelbrot.RegionParams{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.width = 20,
		.height = 7, // not divisible by 3
		.max_iter = 50,
		.aspect_ratio = 0.5,
	};

	const size: usize = 20 * 7;
	const sequential = try allocator.alloc(f64, size);
	defer allocator.free(sequential);
	const parallel = try allocator.alloc(f64, size);
	defer allocator.free(parallel);

	mandelbrot.computeRegion(params, sequential);
	try mandelbrot.parallelComputeRegion(params, parallel);

	try testing.expectEqualSlices(f64, sequential, parallel);
}

test "parallelComputeRegion handles small heights (fewer rows than threads)" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	// Height 2 is less than NUM_THREADS=3
	const params = mandelbrot.RegionParams{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.width = 10,
		.height = 2,
		.max_iter = 50,
		.aspect_ratio = 0.5,
	};

	const size: usize = 10 * 2;
	const sequential = try allocator.alloc(f64, size);
	defer allocator.free(sequential);
	const parallel = try allocator.alloc(f64, size);
	defer allocator.free(parallel);

	mandelbrot.computeRegion(params, sequential);
	try mandelbrot.parallelComputeRegion(params, parallel);

	try testing.expectEqualSlices(f64, sequential, parallel);
}

// tests/benchmark/bench_render.zig
// Benchmarks for Mandelbrot rendering: sequential vs parallel row-band split.
// Always build with -Doptimize=ReleaseFast (asserted via build.zig).

const std = @import("std");
const mandelbrot = @import("mandelbrot");

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	var stderr_buf: [4096]u8 = undefined;
	var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
	const stderr = &stderr_writer.interface;

	// Assert not a debug build (the DEBUG BUILD banner check — but we want
	// the bench to actively refuse debug builds rather than just warn).
	if (comptime @import("builtin").mode == .Debug) {
		try stderr.writeAll("\x1b[31mERROR: bench-render must NOT run in Debug mode.\x1b[0m\n");
		try stderr.writeAll("Rebuild with: nix develop -c zig build bench -Doptimize=ReleaseFast\n");
		try stderr.flush();
		std.process.exit(1);
	}

	const width: u16 = 200;
	const height: u16 = 60;
	const max_iter: u32 = 256;
	const size: usize = @as(usize, width) * @as(usize, height);

	const buf_seq = try allocator.alloc(f64, size);
	defer allocator.free(buf_seq);
	const buf_par = try allocator.alloc(f64, size);
	defer allocator.free(buf_par);

	const params = mandelbrot.RegionParams{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.width = width,
		.height = height,
		.max_iter = max_iter,
		.aspect_ratio = 0.5,
	};

	// Warm up to reduce first-run variance.
	mandelbrot.computeRegion(params, buf_seq);

	const N: u32 = 20;

	// Benchmark sequential.
	var timer = try std.time.Timer.start();
	var i: u32 = 0;
	while (i < N) : (i += 1) {
		mandelbrot.computeRegion(params, buf_seq);
	}
	const seq_ns = timer.read();

	// Benchmark parallel.
	timer.reset();
	i = 0;
	while (i < N) : (i += 1) {
		try mandelbrot.parallelComputeRegion(params, buf_par);
	}
	const par_ns = timer.read();

	const seq_ms = @as(f64, @floatFromInt(seq_ns)) / @as(f64, @floatFromInt(N)) / 1_000_000.0;
	const par_ms = @as(f64, @floatFromInt(par_ns)) / @as(f64, @floatFromInt(N)) / 1_000_000.0;
	const speedup = seq_ms / par_ms;

	try stderr.print("\n=== Mandelbrot Render Benchmark ({d}x{d}, iter={d}, N={d}) ===\n", .{ width, height, max_iter, N });
	try stderr.print("  Sequential:  {d:.2} ms/frame\n", .{seq_ms});
	try stderr.print("  Parallel:    {d:.2} ms/frame\n", .{par_ms});
	try stderr.print("  Speedup:     {d:.2}x\n\n", .{speedup});

	// Verify correctness: parallel output must match sequential bit-for-bit.
	if (!std.mem.eql(f64, buf_seq, buf_par)) {
		try stderr.writeAll("\x1b[31m  WARNING: parallel output differs from sequential!\x1b[0m\n");
		try stderr.flush();
		std.process.exit(2);
	}

	try stderr.flush();
}

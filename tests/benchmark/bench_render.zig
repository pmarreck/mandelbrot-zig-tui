// tests/benchmark/bench_render.zig
// Benchmarks for Mandelbrot rendering: sequential vs parallel across three scenarios.
// Always runs in ReleaseFast — debug mode aborts with a loud error.

const std = @import("std");
const mandelbrot = @import("mandelbrot");

/// Elapsed nanoseconds between two `std.Io.Timestamp`s.
/// Mirrors `std.time.Timer.read()` semantics (clamp negative diffs to 0).
fn elapsedNs(start: std.Io.Timestamp, end: std.Io.Timestamp) u64 {
	const diff: i96 = end.nanoseconds - start.nanoseconds;
	return if (diff < 0) 0 else @intCast(diff);
}

const BenchResult = struct {
	scenario: []const u8,
	width: u16,
	height: u16,
	max_iter: u32,
	zoom: f128,
	seq_ms: f64,
	par_ms: f64,
	speedup: f64,
};

fn benchmarkScenario(
	io: std.Io,
	allocator: std.mem.Allocator,
	name: []const u8,
	params: mandelbrot.RegionParams,
	n_iters: u32,
) !BenchResult {
	const size: usize = @as(usize, params.width) * @as(usize, params.height);
	const buf_seq = try allocator.alloc(f64, size);
	defer allocator.free(buf_seq);
	const buf_par = try allocator.alloc(f64, size);
	defer allocator.free(buf_par);

	// Warm up
	mandelbrot.computeRegion(params, buf_seq);

	// Sequential
	const seq_t0 = std.Io.Timestamp.now(io, .awake);
	var i: u32 = 0;
	while (i < n_iters) : (i += 1) {
		mandelbrot.computeRegion(params, buf_seq);
	}
	const seq_t1 = std.Io.Timestamp.now(io, .awake);
	const seq_ns = elapsedNs(seq_t0, seq_t1);

	// Parallel
	const par_t0 = std.Io.Timestamp.now(io, .awake);
	i = 0;
	while (i < n_iters) : (i += 1) {
		try mandelbrot.parallelComputeRegion(params, buf_par, null);
	}
	const par_t1 = std.Io.Timestamp.now(io, .awake);
	const par_ns = elapsedNs(par_t0, par_t1);

	// Correctness check
	if (!std.mem.eql(f64, buf_seq, buf_par)) {
		return error.ParallelMismatch;
	}

	const seq_ms = @as(f64, @floatFromInt(seq_ns)) / @as(f64, @floatFromInt(n_iters)) / 1_000_000.0;
	const par_ms = @as(f64, @floatFromInt(par_ns)) / @as(f64, @floatFromInt(n_iters)) / 1_000_000.0;

	return .{
		.scenario = name,
		.width = params.width,
		.height = params.height,
		.max_iter = params.max_iter,
		.zoom = params.zoom,
		.seq_ms = seq_ms,
		.par_ms = par_ms,
		.speedup = seq_ms / par_ms,
	};
}

pub fn main(init: std.process.Init) !void {
	const allocator = init.gpa;
	const io = init.io;

	var stderr_buf: [4096]u8 = undefined;
	var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
	const stderr = &stderr_writer.interface;

	if (comptime @import("builtin").mode == .Debug) {
		try stderr.writeAll("\x1b[31mERROR: bench-render must NOT run in Debug mode.\x1b[0m\n");
		try stderr.writeAll("Rebuild with: nix develop -c zig build bench\n");
		try stderr.flush();
		std.process.exit(1);
	}

	const N: u32 = 10;

	try stderr.writeAll("\n=== Mandelbrot Render Benchmarks ===\n\n");
	try stderr.flush();

	// Shallow: default view — mostly escape-velocity points, tests iteration throughput
	const shallow = try benchmarkScenario(io, allocator, "Shallow (zoom=1)", .{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.width = 200,
		.height = 60,
		.max_iter = 256,
		.aspect_ratio = 0.5,
	}, N);

	// Deep: zoomed into the seahorse valley — many interior points, stresses max_iter
	const deep = try benchmarkScenario(io, allocator, "Deep (zoom=1000)", .{
		.center_re = -0.7435,
		.center_im = 0.1314,
		.zoom = 1000.0,
		.width = 200,
		.height = 60,
		.max_iter = 1000,
		.aspect_ratio = 0.5,
	}, N);

	// Small view — tests thread overhead on less work
	const small = try benchmarkScenario(io, allocator, "Small (80x24)", .{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.width = 80,
		.height = 24,
		.max_iter = 256,
		.aspect_ratio = 0.5,
	}, N);

	// Ultra-deep: zoom past F64_THRESHOLD (1e13) forces DD dispatch
	const ultra_deep = try benchmarkScenario(io, allocator, "Ultra-deep (zoom=1e16)", .{
		.center_re = -0.7435,
		.center_im = 0.1314,
		.zoom = 1.0e16,
		.width = 200,
		.height = 60,
		.max_iter = 1000,
		.aspect_ratio = 0.5,
	}, N);

	const results = [_]BenchResult{ shallow, deep, small, ultra_deep };
	for (results) |r| {
		try stderr.print("  {s}: {d}x{d}, iter={d}, zoom={d}, N={d}\n", .{
			r.scenario, r.width, r.height, r.max_iter, @as(f64, @floatCast(r.zoom)), N,
		});
		try stderr.print("    Sequential:  {d:.2} ms/frame\n", .{r.seq_ms});
		try stderr.print("    Parallel:    {d:.2} ms/frame\n", .{r.par_ms});
		try stderr.print("    Speedup:     {d:.2}x\n\n", .{r.speedup});
	}

	try stderr.flush();
}

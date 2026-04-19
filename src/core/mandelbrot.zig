// src/core/mandelbrot.zig
// Mandelbrot escape-time computation using f128 precision.
// Pure function: no I/O, no allocations, no side effects.

const std = @import("std");
const math = std.math;

/// Bailout radius squared. Must be large (>=256) for smooth coloring
/// (the log-log correction converges properly with large bailout).
const BAILOUT_SQ: f128 = 65536.0; // 256^2

/// Sentinel value for interior points (in the Mandelbrot set).
pub const INTERIOR: f64 = -1.0;

/// Compute smooth (fractional) escape iteration for a single point.
/// Returns a continuous f64 value using the normalized iteration count
/// formula: n + 1 - log2(log2(|z_n|)). Interior points return INTERIOR (-1.0).
/// Uses f128 for ~33 digits of precision in the z iteration.
pub fn computeIterations(c_re: f128, c_im: f128, max_iter: u32) f64 {
	var z_re: f128 = 0.0;
	var z_im: f128 = 0.0;
	var i: u32 = 0;
	while (i < max_iter) : (i += 1) {
		const z_re2 = z_re * z_re;
		const z_im2 = z_im * z_im;
		if (z_re2 + z_im2 > BAILOUT_SQ) {
			// Smooth coloring: n + 1 - log2(log2(|z|))
			const mod_sq: f64 = @floatCast(z_re2 + z_im2);
			const log_zn = @log(mod_sq) / 2.0; // log(|z|)
			const nu = @log(log_zn / @log(2.0)) / @log(2.0); // log2(log2(|z|))
			return @as(f64, @floatFromInt(i)) + 1.0 - nu;
		}
		z_im = 2.0 * z_re * z_im + c_im;
		z_re = z_re2 - z_im2 + c_re;
	}
	return INTERIOR;
}

/// Parameters for computing a rectangular region of the complex plane.
pub const RegionParams = struct {
	center_re: f128,
	center_im: f128,
	zoom: f128,
	width: u16,
	height: u16,
	max_iter: u32,
	/// Terminal character aspect ratio (typically ~0.5 since chars are taller than wide).
	aspect_ratio: f64,
};

/// Compute smooth escape iterations for a rectangular grid of the complex plane.
/// Output buffer must have length >= width * height. Fills in row-major order.
/// Interior points are stored as INTERIOR (-1.0).
/// Designed for future parallelization: sub-regions can be computed independently.
pub fn computeRegion(params: RegionParams, out: []f64) void {
	const w: f128 = @floatFromInt(params.width);
	const h: f128 = @floatFromInt(params.height);
	const aspect: f128 = @floatCast(params.aspect_ratio);

	const range_re = 4.0 / params.zoom;
	const range_im = range_re * (h / w) / aspect;

	const step_re = range_re / w;
	const step_im = range_im / h;

	const start_re = params.center_re - range_re / 2.0;
	const start_im = params.center_im - range_im / 2.0;

	var row: u16 = 0;
	while (row < params.height) : (row += 1) {
		var col: u16 = 0;
		while (col < params.width) : (col += 1) {
			const c_re = start_re + @as(f128, @floatFromInt(col)) * step_re + step_re / 2.0;
			const c_im = start_im + @as(f128, @floatFromInt(row)) * step_im + step_im / 2.0;
			const idx = @as(usize, row) * @as(usize, params.width) + @as(usize, col);
			out[idx] = computeIterations(c_re, c_im, params.max_iter);
		}
	}
}

/// Number of worker threads for parallel computation.
const NUM_THREADS: u32 = 3;

/// Compute a contiguous band of rows (from start_row to end_row exclusive).
/// Same math as computeRegion but only fills the specified row range.
/// Thread-safe: no shared mutable state, each thread writes to disjoint rows.
pub fn computeRowBand(params: RegionParams, out: []f64, start_row: u16, end_row: u16) void {
	const w: f128 = @floatFromInt(params.width);
	const h: f128 = @floatFromInt(params.height);
	const aspect: f128 = @floatCast(params.aspect_ratio);

	const range_re = 4.0 / params.zoom;
	const range_im = range_re * (h / w) / aspect;

	const step_re = range_re / w;
	const step_im = range_im / h;

	const start_re = params.center_re - range_re / 2.0;
	const start_im = params.center_im - range_im / 2.0;

	var row = start_row;
	while (row < end_row) : (row += 1) {
		var col: u16 = 0;
		while (col < params.width) : (col += 1) {
			const c_re = start_re + @as(f128, @floatFromInt(col)) * step_re + step_re / 2.0;
			const c_im = start_im + @as(f128, @floatFromInt(row)) * step_im + step_im / 2.0;
			const idx = @as(usize, row) * @as(usize, params.width) + @as(usize, col);
			out[idx] = computeIterations(c_re, c_im, params.max_iter);
		}
	}
}

/// Parallel version of computeRegion: splits rows across 3 threads.
/// Output is identical to sequential computeRegion (floating-point ops are
/// deterministic given the same inputs and each pixel is independent).
/// Falls back to sequential for very small heights (< NUM_THREADS rows).
pub fn parallelComputeRegion(params: RegionParams, out: []f64) !void {
	const height = params.height;
	if (height < NUM_THREADS) {
		// Too few rows for threading — fall back to sequential
		computeRegion(params, out);
		return;
	}

	const rows_per_thread = height / NUM_THREADS;
	var threads: [NUM_THREADS]std.Thread = undefined;
	var i: u32 = 0;
	while (i < NUM_THREADS) : (i += 1) {
		const start_row: u16 = @intCast(i * rows_per_thread);
		const end_row: u16 = if (i == NUM_THREADS - 1) height else @intCast((i + 1) * rows_per_thread);
		threads[i] = try std.Thread.spawn(.{}, computeRowBand, .{ params, out, start_row, end_row });
	}
	for (&threads) |*t| t.join();
}

const cache_mod = @import("cache");

/// Fill a CacheLevel's data buffer using its own grid coordinates.
/// Convenience wrapper over computeIterations for cache levels.
/// Sets level.complete = true on return.
pub fn computeRegionDirect(level: *cache_mod.CacheLevel) void {
	var row: u32 = 0;
	while (row < level.height) : (row += 1) {
		var col: u32 = 0;
		while (col < level.width) : (col += 1) {
			const pt = level.pointAt(col, row);
			level.set(col, row, computeIterations(pt.re, pt.im, level.max_iter));
		}
	}
	level.complete = true;
}

/// Arguments for the offset worker thread.
const OffsetWorkerArgs = struct {
	child: *cache_mod.CacheLevel,
	col_start: u32, // 0 or 1
	row_start: u32, // 0 or 1
	gen: ?*const std.atomic.Value(u32),
	expected: u32,
};

/// Worker function: fills one of the 3 offset patterns.
/// Each thread writes to rows starting at row_start with stride 2,
/// columns starting at col_start with stride 2.
fn offsetWorker(args: OffsetWorkerArgs) void {
	var row: u32 = args.row_start;
	while (row < args.child.height) : (row += 2) {
		// Check cancellation every row
		if (args.gen) |g| {
			if (g.load(.acquire) != args.expected) return;
		}
		var col: u32 = args.col_start;
		while (col < args.child.width) : (col += 2) {
			const pt = args.child.pointAt(col, row);
			args.child.set(col, row, computeIterations(pt.re, pt.im, args.child.max_iter));
		}
	}
}

/// Compute the 3 offset patterns to double resolution from parent to child.
/// Child must be 2x parent dimensions with even-indexed points already inherited
/// via `child.inheritFromParent(parent)`.
/// Spawns 3 threads (odd-col/even-row, even-col/odd-row, odd-col/odd-row).
/// If generation is non-null, threads check it per-row for cancellation.
/// Sets child.complete = true only if computation was not cancelled.
pub fn computeDoubling(
	parent: *const cache_mod.CacheLevel,
	child: *cache_mod.CacheLevel,
	generation: ?*const std.atomic.Value(u32),
) !void {
	_ = parent; // Parent data already inherited into child's even-even slots

	const expected_gen: u32 = if (generation) |g| g.load(.acquire) else 0;

	var threads: [3]std.Thread = undefined;
	// Thread 1: odd col, even row
	threads[0] = try std.Thread.spawn(.{}, offsetWorker, .{OffsetWorkerArgs{
		.child = child,
		.col_start = 1,
		.row_start = 0,
		.gen = generation,
		.expected = expected_gen,
	}});
	// Thread 2: even col, odd row
	threads[1] = try std.Thread.spawn(.{}, offsetWorker, .{OffsetWorkerArgs{
		.child = child,
		.col_start = 0,
		.row_start = 1,
		.gen = generation,
		.expected = expected_gen,
	}});
	// Thread 3: odd col, odd row
	threads[2] = try std.Thread.spawn(.{}, offsetWorker, .{OffsetWorkerArgs{
		.child = child,
		.col_start = 1,
		.row_start = 1,
		.gen = generation,
		.expected = expected_gen,
	}});

	for (&threads) |*t| t.join();

	// Check if computation completed (wasn't cancelled)
	if (generation) |g| {
		child.complete = (g.load(.acquire) == expected_gen);
	} else {
		child.complete = true;
	}
}

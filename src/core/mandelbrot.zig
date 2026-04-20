// src/core/mandelbrot.zig
// Mandelbrot escape-time computation.
// Pure function: no I/O, no allocations, no side effects.
//
// Hot-loop precision dispatch: Apple Silicon has no hardware f128; f128 ops
// compile to slow soft-float library calls. We default to f64 (hardware-fast)
// and fall back to f128 only when zoom/step resolution demands it.

const std = @import("std");

/// Bailout squared. Stored as f64 so both f64 and f128 paths can coerce cleanly.
const BAILOUT_SQ_F64: f64 = 65536.0; // 256^2

/// Sentinel value for interior points (in the Mandelbrot set).
pub const INTERIOR: f64 = -1.0;

/// Zoom threshold above which f128 precision is required.
/// Derived from f64's relative precision (2.2e-16) vs pixel spacing (4/zoom/width).
/// At zoom 10^13 on a 200-wide terminal, pixel spacing is ~2e-15 — close to f64's limit.
pub const F128_DISPATCH_THRESHOLD: f128 = 1.0e13;

/// Step-size threshold below which f128 precision is required.
/// Complementary to F128_DISPATCH_THRESHOLD (zoom-based). Equivalent when
/// terminal is ~200 wide: step = 4/zoom/200, so step < 2e-15 ⇔ zoom > 1e13.
pub const F128_STEP_THRESHOLD: f128 = 2.0e-15;

/// Test-only dispatch counters. Incremented once per call to computeRowStride,
/// computeRegionDirect, and offsetWorker — not once per pixel.
var g_f64_dispatch = std.atomic.Value(u64).init(0);
var g_f128_dispatch = std.atomic.Value(u64).init(0);

pub fn resetDispatchCounters() void {
	g_f64_dispatch.store(0, .release);
	g_f128_dispatch.store(0, .release);
}

pub fn f64DispatchCount() u64 {
	return g_f64_dispatch.load(.acquire);
}

pub fn f128DispatchCount() u64 {
	return g_f128_dispatch.load(.acquire);
}

/// Generic smooth iteration count over float type T (f64 or f128).
/// Returns f64 (smooth iteration count is always returned as f64 for storage).
/// Interior points return INTERIOR (-1.0).
pub fn computeIterationsT(comptime T: type, c_re: T, c_im: T, max_iter: u32) f64 {
	var z_re: T = 0.0;
	var z_im: T = 0.0;
	const bailout_sq: T = @as(T, BAILOUT_SQ_F64);
	var i: u32 = 0;
	while (i < max_iter) : (i += 1) {
		const z_re2 = z_re * z_re;
		const z_im2 = z_im * z_im;
		if (z_re2 + z_im2 > bailout_sq) {
			const mod_sq: f64 = @floatCast(z_re2 + z_im2);
			const log_zn = @log(mod_sq) / 2.0;
			const nu = @log(log_zn / @log(2.0)) / @log(2.0);
			return @as(f64, @floatFromInt(i)) + 1.0 - nu;
		}
		z_im = 2.0 * z_re * z_im + c_im;
		z_re = z_re2 - z_im2 + c_re;
	}
	return INTERIOR;
}

/// Default: fast f64 path. Safe to ~10^13 zoom depth (f64 relative precision
/// ~2.2e-16; pixel spacing at that zoom is ~0.02/10^13 ~ 2e-15 — still resolvable).
pub fn computeIterations(c_re: f64, c_im: f64, max_iter: u32) f64 {
	return computeIterationsT(f64, c_re, c_im, max_iter);
}

/// Precision path: use when zoom exceeds ~10^13.
pub fn computeIterationsF128(c_re: f128, c_im: f128, max_iter: u32) f64 {
	return computeIterationsT(f128, c_re, c_im, max_iter);
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
/// Delegates to the stride path (thread_idx=0, num_threads=1 covers all rows)
/// so sequential and parallel code share the same dispatching inner loop.
/// Output buffer must have length >= width * height. Fills in row-major order.
pub fn computeRegion(params: RegionParams, out: []f64) void {
	computeRowStride(params, out, 0, 1);
}

/// Maximum number of worker threads we'll ever spawn.
/// Cap 12 to leave headroom for main thread + OS + other processes on many-core systems.
const MAX_THREADS: u32 = 12;

/// Detect optimal worker thread count for the current CPU.
/// Caps at MAX_THREADS. Returns 3 as a safe fallback if detection fails.
pub fn autoThreadCount() u32 {
	const count = std.Thread.getCpuCount() catch return 3;
	return @intCast(@min(@max(count, @as(usize, 1)), MAX_THREADS));
}

/// Compute rows with stride (interleaved) row assignment, dispatching between
/// hardware-fast f64 and soft-float f128 based on zoom level.
/// Thread `thread_idx` of `num_threads` total processes rows
/// `thread_idx, thread_idx + num_threads, thread_idx + 2*num_threads, ...`.
/// This balances load across threads: the fractal's high-iteration interior
/// gets spread across all threads instead of concentrating in one contiguous band.
pub fn computeRowStride(params: RegionParams, out: []f64, thread_idx: u32, num_threads: u32) void {
	const w: f128 = @floatFromInt(params.width);
	const h: f128 = @floatFromInt(params.height);
	const aspect: f128 = @floatCast(params.aspect_ratio);

	const range_re = 4.0 / params.zoom;
	const range_im = range_re * (h / w) / aspect;

	const step_re = range_re / w;
	const step_im = range_im / h;

	const start_re = params.center_re - range_re / 2.0;
	const start_im = params.center_im - range_im / 2.0;

	// Dispatch decision: below threshold use f64 (fast hardware),
	// above threshold use f128 (slow soft-float, but required for precision).
	if (params.zoom <= F128_DISPATCH_THRESHOLD) {
		_ = g_f64_dispatch.fetchAdd(1, .monotonic);
		// Precompute f64 versions of row-invariant scalars for the inner loop
		const start_re_f64: f64 = @floatCast(start_re);
		const start_im_f64: f64 = @floatCast(start_im);
		const step_re_f64: f64 = @floatCast(step_re);
		const step_im_f64: f64 = @floatCast(step_im);

		var row: u32 = thread_idx;
		while (row < params.height) : (row += num_threads) {
			const row_f64: f64 = @floatFromInt(row);
			const c_im_f64 = start_im_f64 + row_f64 * step_im_f64;
			var col: u32 = 0;
			while (col < params.width) : (col += 1) {
				const col_f64: f64 = @floatFromInt(col);
				const c_re_f64 = start_re_f64 + col_f64 * step_re_f64;
				const idx = row * @as(u32, params.width) + col;
				out[idx] = computeIterations(c_re_f64, c_im_f64, params.max_iter);
			}
		}
	} else {
		_ = g_f128_dispatch.fetchAdd(1, .monotonic);
		var row: u32 = thread_idx;
		while (row < params.height) : (row += num_threads) {
			var col: u32 = 0;
			while (col < params.width) : (col += 1) {
				const c_re = start_re + @as(f128, @floatFromInt(col)) * step_re;
				const c_im = start_im + @as(f128, @floatFromInt(row)) * step_im;
				const idx = row * @as(u32, params.width) + col;
				out[idx] = computeIterationsF128(c_re, c_im, params.max_iter);
			}
		}
	}
}

/// Parallel version of computeRegion. Splits rows across `num_threads` threads
/// using interleaved (stride-based) assignment for even load balancing.
/// If `num_threads` is null, auto-detects via autoThreadCount().
/// Output is identical to sequential computeRegion.
/// Falls back to sequential for very small heights (< num_threads rows) or when n <= 1.
pub fn parallelComputeRegion(params: RegionParams, out: []f64, num_threads: ?u32) !void {
	const n = num_threads orelse autoThreadCount();
	const height = params.height;
	if (height < n or n <= 1) {
		computeRegion(params, out);
		return;
	}

	var threads: [MAX_THREADS]std.Thread = undefined;
	var i: u32 = 0;
	while (i < n) : (i += 1) {
		threads[i] = try std.Thread.spawn(.{}, computeRowStride, .{ params, out, i, n });
	}
	var j: u32 = 0;
	while (j < n) : (j += 1) {
		threads[j].join();
	}
}

const cache_mod = @import("cache");

/// Fill a CacheLevel's data buffer using its own grid coordinates.
/// Dispatches between hardware-fast f64 and soft-float f128 based on step size.
/// Sets level.complete = true on return.
pub fn computeRegionDirect(level: *cache_mod.CacheLevel) void {
	if (level.step_re > F128_STEP_THRESHOLD) {
		// f64 path
		_ = g_f64_dispatch.fetchAdd(1, .monotonic);
		var row: u32 = 0;
		while (row < level.height) : (row += 1) {
			var col: u32 = 0;
			while (col < level.width) : (col += 1) {
				const pt = level.pointAt(col, row);
				const c_re: f64 = @floatCast(pt.re);
				const c_im: f64 = @floatCast(pt.im);
				level.set(col, row, computeIterations(c_re, c_im, level.max_iter));
			}
		}
	} else {
		// f128 path
		_ = g_f128_dispatch.fetchAdd(1, .monotonic);
		var row: u32 = 0;
		while (row < level.height) : (row += 1) {
			var col: u32 = 0;
			while (col < level.width) : (col += 1) {
				const pt = level.pointAt(col, row);
				level.set(col, row, computeIterationsF128(pt.re, pt.im, level.max_iter));
			}
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
	const use_f64 = args.child.step_re > F128_STEP_THRESHOLD;
	var row: u32 = args.row_start;
	while (row < args.child.height) : (row += 2) {
		// Check cancellation every row
		if (args.gen) |g| {
			if (g.load(.acquire) != args.expected) return;
		}
		var col: u32 = args.col_start;
		while (col < args.child.width) : (col += 2) {
			const pt = args.child.pointAt(col, row);
			if (use_f64) {
				const c_re: f64 = @floatCast(pt.re);
				const c_im: f64 = @floatCast(pt.im);
				args.child.set(col, row, computeIterations(c_re, c_im, args.child.max_iter));
			} else {
				args.child.set(col, row, computeIterationsF128(pt.re, pt.im, args.child.max_iter));
			}
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

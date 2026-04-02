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

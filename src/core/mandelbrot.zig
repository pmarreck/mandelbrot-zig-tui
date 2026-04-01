// src/core/mandelbrot.zig
// Mandelbrot escape-time computation using f128 precision.
// Pure function: no I/O, no allocations, no side effects.

/// Compute escape iteration for a single point in the complex plane.
/// Returns the iteration count at which |z|^2 > 4, or max_iter if the point
/// is (likely) in the Mandelbrot set. Uses f128 for ~33 digits of precision,
/// enabling deep zooms far beyond f64's ~15-digit limit.
pub fn computeIterations(c_re: f128, c_im: f128, max_iter: u32) u32 {
	var z_re: f128 = 0.0;
	var z_im: f128 = 0.0;
	var i: u32 = 0;
	while (i < max_iter) : (i += 1) {
		const z_re2 = z_re * z_re;
		const z_im2 = z_im * z_im;
		if (z_re2 + z_im2 > 4.0) return i;
		z_im = 2.0 * z_re * z_im + c_im;
		z_re = z_re2 - z_im2 + c_re;
	}
	return max_iter;
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

/// Compute escape iterations for a rectangular grid of the complex plane.
/// Output buffer must have length >= width * height. Fills in row-major order.
/// Designed for future parallelization: sub-regions can be computed independently.
pub fn computeRegion(params: RegionParams, out: []u32) void {
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

// src/core/viewport.zig
// Screen<->complex coordinate mapping, pan, zoom, adaptive iteration scaling.
// Pure functions: no I/O, no side effects.

const std = @import("std");

pub const ViewState = struct {
	center_re: f128,
	center_im: f128,
	zoom: f128,
	base_iter: u32,
	max_iter: u32,
};

pub const Direction = enum {
	up,
	down,
	left,
	right,
};

pub const ScreenToComplexParams = struct {
	col: u16,
	row: u16,
	center_re: f128,
	center_im: f128,
	zoom: f128,
	width: u16,
	height: u16,
	aspect_ratio: f64,
};

pub const ComplexPoint = struct {
	re: f128,
	im: f128,
};

/// Map a terminal cell (col, row) to a point on the complex plane.
/// Uses the same range calculation as mandelbrot.computeRegion so that
/// screen coordinates and iteration grids stay in perfect agreement.
pub fn screenToComplex(p: ScreenToComplexParams) ComplexPoint {
	const w: f128 = @floatFromInt(p.width);
	const h: f128 = @floatFromInt(p.height);
	const aspect: f128 = @floatCast(p.aspect_ratio);

	const range_re = 4.0 / p.zoom;
	const range_im = range_re * (h / w) / aspect;

	const col_f: f128 = @floatFromInt(p.col);
	const row_f: f128 = @floatFromInt(p.row);

	const re = p.center_re + (col_f - w / 2.0) / w * range_re;
	const im = p.center_im + (row_f - h / 2.0) / h * range_im;

	return .{ .re = re, .im = im };
}

/// Zoom by factor centered on a screen position (click_col, click_row).
/// The clicked point becomes the new center so the user "zooms into" wherever
/// they clicked. max_iter is recalculated via adaptiveMaxIter.
pub fn zoomAt(
	state: ViewState,
	factor: f128,
	click_col: u16,
	click_row: u16,
	width: u16,
	height: u16,
	aspect_ratio: f64,
) ViewState {
	const target = screenToComplex(.{
		.col = click_col,
		.row = click_row,
		.center_re = state.center_re,
		.center_im = state.center_im,
		.zoom = state.zoom,
		.width = width,
		.height = height,
		.aspect_ratio = aspect_ratio,
	});

	const new_zoom = state.zoom * factor;

	return .{
		.center_re = target.re,
		.center_im = target.im,
		.zoom = new_zoom,
		.base_iter = state.base_iter,
		.max_iter = adaptiveMaxIter(new_zoom, state.base_iter),
	};
}

/// Pan by 10% of visible range in the given direction.
/// Returns a new ViewState with shifted center; zoom and iterations unchanged.
pub fn pan(
	state: ViewState,
	direction: Direction,
	width: u16,
	height: u16,
	aspect_ratio: f64,
) ViewState {
	const w: f128 = @floatFromInt(width);
	const h: f128 = @floatFromInt(height);
	const aspect: f128 = @floatCast(aspect_ratio);

	const range_re = 4.0 / state.zoom;
	const range_im = range_re * (h / w) / aspect;

	const step_re = range_re * 0.1;
	const step_im = range_im * 0.1;

	var new = state;
	switch (direction) {
		.left => new.center_re -= step_re,
		.right => new.center_re += step_re,
		.up => new.center_im -= step_im,
		.down => new.center_im += step_im,
	}
	return new;
}

/// Adaptive max iterations: base + 50 * log2(zoom).
/// At zoom <= 1.0 returns base unchanged. Clamped to 100,000 to prevent
/// runaway computation at extreme zoom depths.
pub fn adaptiveMaxIter(zoom: f128, base: u32) u32 {
	if (zoom <= 1.0) return base;
	const zoom_f64: f64 = @floatCast(zoom);
	const extra: f64 = 50.0 * @log2(zoom_f64);
	const total = @as(u64, base) + @as(u64, @intFromFloat(@max(0.0, extra)));
	return @intCast(@min(total, 100_000));
}

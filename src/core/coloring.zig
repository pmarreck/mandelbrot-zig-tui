// src/core/coloring.zig
// Maps smooth iteration count to terminal cell: ASCII density char + true-color RGB.
// Uses Bernstein polynomial palette (Wikipedia Mandelbrot) with log transform.
// Pure function: no I/O, no side effects.

const std = @import("std");
const mandelbrot = @import("mandelbrot");

pub const RGB = struct {
	r: u8,
	g: u8,
	b: u8,
};

pub const Cell = struct {
	char: u8,
	color: RGB,
	is_interior: bool,
};

/// Density characters for exterior points — cyclic mapping.
/// Space excluded: every exterior cell must be visible so fg color shows.
const density_chars = ".:-=+*#%@";

/// Convert a smooth iteration count to an RGB color via the Bernstein palette
/// with log transform for visual band distribution.
/// Interior points (iter == INTERIOR) return black.
/// This is the shared coloring primitive — iterToCell (density mode) and
/// iterToBlock (blocks mode, future) both call it.
pub fn iterToColor(smooth_iter: f64, max_iter: u32) RGB {
	if (smooth_iter == mandelbrot.INTERIOR) {
		return .{ .r = 0, .g = 0, .b = 0 };
	}
	const t = logTransform(smooth_iter, max_iter);
	return bernsteinPalette(t);
}

/// Map a smooth iteration count to a renderable terminal cell.
/// Interior points (smooth_iter == INTERIOR) produce a black space.
/// Exterior points get a cyclic density char + Bernstein polynomial RGB color.
pub fn iterToCell(smooth_iter: f64, max_iter: u32) Cell {
	if (smooth_iter == mandelbrot.INTERIOR) {
		return .{ .char = ' ', .color = .{ .r = 0, .g = 0, .b = 0 }, .is_interior = true };
	}

	// Cyclic character mapping based on integer part of smooth iteration
	const int_iter: u32 = @intFromFloat(@max(0.0, smooth_iter));
	const char = density_chars[int_iter % density_chars.len];

	const color = iterToColor(smooth_iter, max_iter);

	return .{ .char = char, .color = color, .is_interior = false };
}

/// Log transform to spread iteration values across [0,1].
/// Maps smooth_iter to a value in [0, 1) using log scaling,
/// then applies a cyclic wrap for pleasing color bands at all zoom levels.
fn logTransform(smooth_iter: f64, max_iter: u32) f64 {
	const max_f: f64 = @floatFromInt(max_iter);
	// Log scale to spread low values; +1 to avoid log(0)
	const log_val = @log(smooth_iter + 1.0) / @log(max_f + 1.0);
	// Multiply by a period factor and take fractional part for cyclic banding
	const period = 3.0; // controls number of color cycles visible
	return log_val * period - @floor(log_val * period);
}

/// Bernstein polynomial palette — the classic Wikipedia Mandelbrot coloring.
/// Maps t in [0,1] to RGB using cubic Bernstein basis polynomials.
/// Produces a smooth blue → cyan → orange → yellow → dark gradient.
fn bernsteinPalette(t: f64) RGB {
	const t_c = std.math.clamp(t, 0.0, 1.0);
	const t1 = 1.0 - t_c;

	// Bernstein basis polynomials with hand-tuned coefficients
	const r_f = 9.0 * t1 * t_c * t_c * t_c;
	const g_f = 15.0 * t1 * t1 * t_c * t_c;
	const b_f = 8.5 * t1 * t1 * t1 * t_c;

	return .{
		.r = @intFromFloat(std.math.clamp(r_f * 255.0, 0.0, 255.0)),
		.g = @intFromFloat(std.math.clamp(g_f * 255.0, 0.0, 255.0)),
		.b = @intFromFloat(std.math.clamp(b_f * 255.0, 0.0, 255.0)),
	};
}

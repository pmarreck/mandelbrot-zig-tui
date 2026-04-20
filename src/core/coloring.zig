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

/// Glyph rendering mode. Density uses ASCII intensity characters;
/// blocks uses Unicode quadrant characters for 2×2 sub-pixel shape fidelity.
pub const GlyphMode = enum { density, blocks };

/// Result of iterToBlock — UTF-8 char bytes + FG/BG colors for a terminal cell.
pub const BlockCell = struct {
	/// UTF-8 bytes for the glyph (1 byte for space, 3 bytes for block chars).
	char_bytes: []const u8,
	fg: RGB,
	bg: RGB,
	all_interior: bool,
};

/// Density characters for exterior points — cyclic mapping.
/// Space excluded: every exterior cell must be visible so fg color shows.
const density_chars = ".:-=+*#%@";

/// 2×2 quadrant glyph lookup table. Index = 4-bit fg_mask where
/// bit 3 = top-left, bit 2 = top-right, bit 1 = bottom-left, bit 0 = bottom-right.
/// Each position is set if that sub-pixel is in the FG group (above median iter
/// or exterior in mixed cells).
const quadrant_glyphs = [16][]const u8{
	" ",  // 0b0000
	"▗",  // 0b0001 — br
	"▖",  // 0b0010 — bl
	"▄",  // 0b0011 — bl+br (bottom half)
	"▝",  // 0b0100 — tr
	"▐",  // 0b0101 — tr+br (right half)
	"▞",  // 0b0110 — tr+bl (anti-diagonal)
	"▟",  // 0b0111 — tr+bl+br
	"▘",  // 0b1000 — tl
	"▚",  // 0b1001 — tl+br (diagonal)
	"▌",  // 0b1010 — tl+bl (left half)
	"▙",  // 0b1011 — tl+bl+br
	"▀",  // 0b1100 — tl+tr (top half)
	"▜",  // 0b1101 — tl+tr+br
	"▛",  // 0b1110 — tl+tr+bl
	"█",  // 0b1111 — all
};

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

/// Render a 2×2 block of iteration values into a quadrant char + FG/BG colors.
///
/// The 3-case algorithm:
/// - All 4 interior: space + black (trivial).
/// - Mixed interior/exterior: interior sub-pixels go to BG (black),
///   exterior sub-pixels go to FG (mean of exterior iter values → palette).
/// - All 4 exterior: median-split clustering. Sub-pixels with iter ≥ median
///   go to FG group; rest go to BG. If all four are equal, emit "█" with
///   FG = palette(mean), BG = black (degenerate single-color case).
pub fn iterToBlock(tl: f64, tr: f64, bl: f64, br: f64, max_iter: u32) BlockCell {
	const iters = [4]f64{ tl, tr, bl, br };

	// Determine interior mask. Bit positions: tl=3, tr=2, bl=1, br=0.
	var interior_mask: u4 = 0;
	if (tl == mandelbrot.INTERIOR) interior_mask |= 0b1000;
	if (tr == mandelbrot.INTERIOR) interior_mask |= 0b0100;
	if (bl == mandelbrot.INTERIOR) interior_mask |= 0b0010;
	if (br == mandelbrot.INTERIOR) interior_mask |= 0b0001;

	const black = RGB{ .r = 0, .g = 0, .b = 0 };

	// Case 1: all interior
	if (interior_mask == 0b1111) {
		return .{ .char_bytes = " ", .fg = black, .bg = black, .all_interior = true };
	}

	// Case 3: mixed — interior → BG, exterior → FG
	if (interior_mask != 0b0000) {
		const fg_mask: u4 = ~interior_mask;
		var sum: f64 = 0;
		var count: f64 = 0;
		for (iters, 0..) |v, i| {
			const bit: u4 = @as(u4, 1) << @intCast(3 - i);
			if (fg_mask & bit != 0) {
				sum += v;
				count += 1;
			}
		}
		const mean_iter = if (count > 0) sum / count else 0;
		const fg = iterToColor(mean_iter, max_iter);
		return .{
			.char_bytes = quadrant_glyphs[fg_mask],
			.fg = fg,
			.bg = black,
			.all_interior = false,
		};
	}

	// Case 2: all exterior — median-split two-color clustering
	var sorted = iters;
	std.mem.sort(f64, &sorted, {}, std.sort.asc(f64));
	const median = (sorted[1] + sorted[2]) / 2.0;

	var fg_mask: u4 = 0;
	if (tl >= median) fg_mask |= 0b1000;
	if (tr >= median) fg_mask |= 0b0100;
	if (bl >= median) fg_mask |= 0b0010;
	if (br >= median) fg_mask |= 0b0001;

	// Degenerate case: all values equal → fg_mask is all 1s (all ≥ median).
	if (fg_mask == 0b1111) {
		const mean = (tl + tr + bl + br) / 4.0;
		return .{
			.char_bytes = quadrant_glyphs[0b1111],
			.fg = iterToColor(mean, max_iter),
			.bg = black,
			.all_interior = false,
		};
	}

	var fg_sum: f64 = 0;
	var fg_count: f64 = 0;
	var bg_sum: f64 = 0;
	var bg_count: f64 = 0;
	for (iters, 0..) |v, i| {
		const bit: u4 = @as(u4, 1) << @intCast(3 - i);
		if (fg_mask & bit != 0) {
			fg_sum += v;
			fg_count += 1;
		} else {
			bg_sum += v;
			bg_count += 1;
		}
	}
	const fg_mean = fg_sum / fg_count;
	const bg_mean = bg_sum / bg_count;

	return .{
		.char_bytes = quadrant_glyphs[fg_mask],
		.fg = iterToColor(fg_mean, max_iter),
		.bg = iterToColor(bg_mean, max_iter),
		.all_interior = false,
	};
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

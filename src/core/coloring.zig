// src/core/coloring.zig
// Maps iteration count to terminal cell: ASCII density character + 256 ANSI color.
// Pure function: no I/O, no side effects.

pub const Cell = struct {
	char: u8,
	fg_color: u8,
	bg_color: u8,
};

/// Density characters for exterior points — cyclic mapping.
/// Space excluded: every exterior cell must be visible so fg color shows.
const density_chars = ".:-=+*#%@";

/// Map an iteration count to a renderable terminal cell.
/// Interior points (iter == max_iter) produce a black space.
/// Exterior points get a cyclic ASCII density char + cyclic 256-color gradient.
/// Character and color both cycle independently for maximum visual texture.
pub fn iterToCell(iter: u32, max_iter: u32) Cell {
	if (iter >= max_iter) {
		return .{ .char = ' ', .fg_color = 0, .bg_color = 0 };
	}

	// Cyclic character mapping — every exterior point gets a visible character
	const char = density_chars[iter % density_chars.len];

	const fg = iterToColor256(iter);

	return .{ .char = char, .fg_color = fg, .bg_color = 0 };
}

/// Map iteration count to ANSI 256-color index (16-231 range).
/// Smooth cyclic HSV gradient through the 6x6x6 color cube.
fn iterToColor256(iter: u32) u8 {
	const t = @as(f64, @floatFromInt(iter % 256)) / 256.0;

	const phase = t * 6.0;
	const sector: u32 = @intFromFloat(phase);
	const frac = phase - @as(f64, @floatFromInt(sector));

	var r: u32 = 0;
	var g: u32 = 0;
	var b: u32 = 0;
	const rise: u32 = @intFromFloat(frac * 5.0);
	const fall: u32 = 5 - rise;

	switch (sector % 6) {
		0 => {
			r = 5;
			g = rise;
			b = 0;
		},
		1 => {
			r = fall;
			g = 5;
			b = 0;
		},
		2 => {
			r = 0;
			g = 5;
			b = rise;
		},
		3 => {
			r = 0;
			g = fall;
			b = 5;
		},
		4 => {
			r = rise;
			g = 0;
			b = 5;
		},
		5 => {
			r = 5;
			g = 0;
			b = fall;
		},
		else => unreachable,
	}

	return @intCast(16 + 36 * r + 6 * g + b);
}

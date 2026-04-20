const std = @import("std");
const testing = std.testing;
const coloring = @import("coloring");
const mandelbrot = @import("mandelbrot");

test "interior point renders as black space" {
	const cell = coloring.iterToCell(mandelbrot.INTERIOR, 256);
	try testing.expectEqual(@as(u8, ' '), cell.char);
	try testing.expectEqual(@as(u8, 0), cell.color.r);
	try testing.expectEqual(@as(u8, 0), cell.color.g);
	try testing.expectEqual(@as(u8, 0), cell.color.b);
	try testing.expect(cell.is_interior);
}

test "exterior point at iter=1.0 gets visible character" {
	const cell = coloring.iterToCell(1.0, 256);
	try testing.expect(cell.char != ' ');
	try testing.expect(!cell.is_interior);
}

test "exterior points never produce space character" {
	var i: u32 = 0;
	while (i < 1000) : (i += 1) {
		const smooth: f64 = @as(f64, @floatFromInt(i)) * 0.1 + 0.1;
		const cell = coloring.iterToCell(smooth, 1000);
		try testing.expect(cell.char != ' ');
	}
}

test "density characters cycle across iterations" {
	const density = ".:-=+*#%@";
	var seen = [_]bool{false} ** 9;
	var i: u32 = 0;
	while (i < 100) : (i += 1) {
		const smooth: f64 = @floatFromInt(i);
		const cell = coloring.iterToCell(smooth, 1000);
		for (density, 0..) |ch, idx| {
			if (cell.char == ch) {
				seen[idx] = true;
				break;
			}
		}
	}
	for (seen) |s| {
		try testing.expect(s);
	}
}

test "color values vary across iteration range" {
	// Colors should not all be the same — the palette should produce variety
	var unique_colors: u32 = 0;
	var last_r: u8 = 255;
	var last_g: u8 = 255;
	var i: u32 = 0;
	while (i < 100) : (i += 1) {
		const smooth: f64 = @as(f64, @floatFromInt(i)) + 0.5;
		const cell = coloring.iterToCell(smooth, 256);
		if (cell.color.r != last_r or cell.color.g != last_g) {
			unique_colors += 1;
			last_r = cell.color.r;
			last_g = cell.color.g;
		}
	}
	// Should have at least 5 distinct colors across 100 iterations
	try testing.expect(unique_colors >= 5);
}

test "adjacent smooth iterations produce smooth color transitions" {
	var large_jumps: u32 = 0;
	var i: u32 = 1;
	while (i < 100) : (i += 1) {
		const s1: f64 = @as(f64, @floatFromInt(i - 1)) + 0.5;
		const s2: f64 = @as(f64, @floatFromInt(i)) + 0.5;
		const c1 = coloring.iterToCell(s1, 256);
		const c2 = coloring.iterToCell(s2, 256);
		const dr: i16 = @as(i16, c2.color.r) - @as(i16, c1.color.r);
		const dg: i16 = @as(i16, c2.color.g) - @as(i16, c1.color.g);
		const db: i16 = @as(i16, c2.color.b) - @as(i16, c1.color.b);
		const dist = @abs(dr) + @abs(dg) + @abs(db);
		if (dist > 100) large_jumps += 1;
	}
	// Allow some jumps at palette wrap points but not too many
	try testing.expect(large_jumps < 20);
}

test "iterToBlock all-interior returns space with black" {
	const block = coloring.iterToBlock(mandelbrot.INTERIOR, mandelbrot.INTERIOR, mandelbrot.INTERIOR, mandelbrot.INTERIOR, 256);
	try testing.expect(block.all_interior);
	try testing.expectEqualStrings(" ", block.char_bytes);
	try testing.expectEqual(@as(u8, 0), block.fg.r);
	try testing.expectEqual(@as(u8, 0), block.fg.g);
	try testing.expectEqual(@as(u8, 0), block.fg.b);
	try testing.expectEqual(@as(u8, 0), block.bg.r);
	try testing.expectEqual(@as(u8, 0), block.bg.g);
	try testing.expectEqual(@as(u8, 0), block.bg.b);
}

test "iterToBlock all-exterior uniform returns full block" {
	const block = coloring.iterToBlock(50.0, 50.0, 50.0, 50.0, 256);
	try testing.expect(!block.all_interior);
	try testing.expectEqualStrings("█", block.char_bytes);
	try testing.expectEqual(@as(u8, 0), block.bg.r);
	try testing.expectEqual(@as(u8, 0), block.bg.g);
	try testing.expectEqual(@as(u8, 0), block.bg.b);
	const expected_fg = coloring.iterToColor(50.0, 256);
	try testing.expectEqual(expected_fg.r, block.fg.r);
	try testing.expectEqual(expected_fg.g, block.fg.g);
	try testing.expectEqual(expected_fg.b, block.fg.b);
}

test "iterToBlock all-exterior split returns correct quadrant" {
	// tl=10, tr=20, bl=100, br=110 — median ≈ 60
	// fg_mask: tl(10)<60→0, tr(20)<60→0, bl(100)≥60→1, br(110)≥60→1
	// fg_mask = 0b0011 → "▄" (bottom half)
	const block = coloring.iterToBlock(10.0, 20.0, 100.0, 110.0, 256);
	try testing.expect(!block.all_interior);
	try testing.expectEqualStrings("▄", block.char_bytes);
}

test "iterToBlock mixed interior/exterior returns correct quadrant" {
	// tl=INTERIOR, tr=50, bl=INTERIOR, br=50
	// Mixed case: interior → BG, exterior → FG. tr=bit 2, br=bit 0 → fg_mask=0b0101 → "▐"
	const block = coloring.iterToBlock(mandelbrot.INTERIOR, 50.0, mandelbrot.INTERIOR, 50.0, 256);
	try testing.expect(!block.all_interior);
	try testing.expectEqualStrings("▐", block.char_bytes);
	try testing.expectEqual(@as(u8, 0), block.bg.r);
	try testing.expectEqual(@as(u8, 0), block.bg.g);
	try testing.expectEqual(@as(u8, 0), block.bg.b);
	const expected_fg = coloring.iterToColor(50.0, 256);
	try testing.expectEqual(expected_fg.r, block.fg.r);
}

test "iterToBlock quadrant lookup table — all 16 fg_masks produce expected chars" {
	const fg_val: f64 = 100.0;
	const bg_val: f64 = mandelbrot.INTERIOR;

	const cases = [_]struct { mask: u4, expected: []const u8 }{
		.{ .mask = 0b0000, .expected = " " },
		.{ .mask = 0b0001, .expected = "▗" },
		.{ .mask = 0b0010, .expected = "▖" },
		.{ .mask = 0b0011, .expected = "▄" },
		.{ .mask = 0b0100, .expected = "▝" },
		.{ .mask = 0b0101, .expected = "▐" },
		.{ .mask = 0b0110, .expected = "▞" },
		.{ .mask = 0b0111, .expected = "▟" },
		.{ .mask = 0b1000, .expected = "▘" },
		.{ .mask = 0b1001, .expected = "▚" },
		.{ .mask = 0b1010, .expected = "▌" },
		.{ .mask = 0b1011, .expected = "▙" },
		.{ .mask = 0b1100, .expected = "▀" },
		.{ .mask = 0b1101, .expected = "▜" },
		.{ .mask = 0b1110, .expected = "▛" },
		.{ .mask = 0b1111, .expected = "█" },
	};

	for (cases) |c| {
		const tl = if (c.mask & 0b1000 != 0) fg_val else bg_val;
		const tr = if (c.mask & 0b0100 != 0) fg_val else bg_val;
		const bl = if (c.mask & 0b0010 != 0) fg_val else bg_val;
		const br = if (c.mask & 0b0001 != 0) fg_val else bg_val;
		const block = coloring.iterToBlock(tl, tr, bl, br, 256);
		try testing.expectEqualStrings(c.expected, block.char_bytes);
	}
}

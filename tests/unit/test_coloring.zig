const std = @import("std");
const testing = std.testing;
const coloring = @import("coloring");

test "interior point (iter == max_iter) renders as black space" {
	const cell = coloring.iterToCell(256, 256);
	try testing.expectEqual(@as(u8, ' '), cell.char);
	try testing.expectEqual(@as(u8, 0), cell.bg_color);
}

test "iter=0 maps to first density character (dot)" {
	const cell = coloring.iterToCell(0, 256);
	try testing.expectEqual(@as(u8, '.'), cell.char);
}

test "exterior points never produce space character" {
	const max_iter: u32 = 1000;
	var i: u32 = 0;
	while (i < max_iter) : (i += 1) {
		const cell = coloring.iterToCell(i, max_iter);
		try testing.expect(cell.char != ' ');
	}
}

test "density characters cycle across iterations" {
	const density = ".:-=+*#%@";
	var seen = [_]bool{false} ** 9;
	const max_iter: u32 = 1000;
	var i: u32 = 0;
	while (i < max_iter) : (i += 1) {
		const cell = coloring.iterToCell(i, max_iter);
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

test "color values are in 256-color range (16-231 for color cube)" {
	const max_iter: u32 = 500;
	var i: u32 = 0;
	while (i < max_iter) : (i += 1) {
		const cell = coloring.iterToCell(i, max_iter);
		try testing.expect(cell.fg_color >= 16 and cell.fg_color <= 231);
	}
}

test "adjacent iterations produce smooth color transitions" {
	const max_iter: u32 = 100;
	var large_jumps: u32 = 0;
	var i: u32 = 1;
	while (i < max_iter) : (i += 1) {
		const c1 = coloring.iterToCell(i - 1, max_iter);
		const c2 = coloring.iterToCell(i, max_iter);
		const diff = if (c2.fg_color > c1.fg_color) c2.fg_color - c1.fg_color else c1.fg_color - c2.fg_color;
		if (diff > 36) large_jumps += 1;
	}
	try testing.expect(large_jumps < max_iter / 5);
}

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

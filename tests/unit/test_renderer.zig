const std = @import("std");
const testing = std.testing;
const renderer = @import("renderer");
const mandelbrot = @import("mandelbrot");

test "renderFrame produces output for small terminal" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const state = renderer.RenderState{
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 1.0,
        .max_iter = 50,
        .show_info = false,
    };

    const output = try renderer.renderFrame(state, 10, 5, allocator);
    defer allocator.free(output);

    try testing.expect(output.len > 0);
    // Should contain true-color ANSI escape sequences
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[38;2;") != null);
}

test "renderFrame with info bar includes coordinate info" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const state = renderer.RenderState{
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 1.0,
        .max_iter = 50,
        .show_info = true,
    };

    const output = try renderer.renderFrame(state, 60, 10, allocator);
    defer allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "MANDELBROT") != null);
}

test "renderFrame is deterministic" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const state = renderer.RenderState{
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 1.0,
        .max_iter = 50,
        .show_info = false,
    };

    const output1 = try renderer.renderFrame(state, 10, 5, allocator);
    defer allocator.free(output1);
    const output2 = try renderer.renderFrame(state, 10, 5, allocator);
    defer allocator.free(output2);

    try testing.expectEqualSlices(u8, output1, output2);
}

test "renderFrame interior region contains interior points" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const state = renderer.RenderState{
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 3.0,
        .max_iter = 200,
        .show_info = false,
    };

    const output = try renderer.renderFrame(state, 20, 10, allocator);
    defer allocator.free(output);

    // Interior renders as black (0;0;0) followed by space
    try testing.expect(std.mem.indexOf(u8, output, "0;0;0m ") != null);
}

test "renderFrameFromBuffer produces same output as renderFrame" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const state = renderer.RenderState{
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 1.0,
        .max_iter = 50,
        .show_info = false,
    };

    const width: u16 = 10;
    const height: u16 = 5;

    // Render the normal way (computes internally)
    const output1 = try renderer.renderFrame(state, width, height, allocator);
    defer allocator.free(output1);

    // Compute the buffer manually and render from it
    const pixel_count: usize = @as(usize, width) * @as(usize, height);
    const iter_buf = try allocator.alloc(f64, pixel_count);
    defer allocator.free(iter_buf);

    mandelbrot.computeRegion(.{
        .center_re = state.center_re,
        .center_im = state.center_im,
        .zoom = state.zoom,
        .width = width,
        .height = height,
        .max_iter = state.max_iter,
        .aspect_ratio = 0.5,
    }, iter_buf);

    const output2 = try renderer.renderFrameFromBuffer(state, width, height, iter_buf, allocator);
    defer allocator.free(output2);

    try testing.expectEqualSlices(u8, output1, output2);
}

test "renderFrameFromBlocksBuffer produces ANSI + block chars" {
	var gpa: std.heap.DebugAllocator(.{}) = .init;
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	const state = renderer.RenderState{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.max_iter = 50,
		.show_info = false,
		.glyph_mode = .blocks,
	};

	// 2x2 display grid → 4x4 iter_buf
	const width: u16 = 2;
	const height: u16 = 2;

	// Fill with varying iter values so we get some block chars (not all space)
	var iter_buf: [16]f64 = undefined;
	for (&iter_buf, 0..) |*v, i| {
		v.* = @as(f64, @floatFromInt(i)) * 10.0 + 5.0;
	}

	const output = try renderer.renderFrameFromBlocksBuffer(state, width, height, &iter_buf, allocator);
	defer allocator.free(output);

	try testing.expect(output.len > 0);
	try testing.expect(std.mem.indexOf(u8, output, "\x1b[") != null);
}

test "renderFrameFromBlocksBuffer all-interior produces no block chars" {
	var gpa: std.heap.DebugAllocator(.{}) = .init;
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	const mandelbrot_mod = @import("mandelbrot");

	const state = renderer.RenderState{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.max_iter = 50,
		.show_info = false,
		.glyph_mode = .blocks,
	};

	const width: u16 = 4;
	const height: u16 = 2;
	// 4x2 display → 8x4 iter_buf = 32 values, all INTERIOR
	var iter_buf: [32]f64 = undefined;
	@memset(&iter_buf, mandelbrot_mod.INTERIOR);

	const output = try renderer.renderFrameFromBlocksBuffer(state, width, height, &iter_buf, allocator);
	defer allocator.free(output);

	// All-interior sub-pixels → " " (space) per cell, no block chars
	try testing.expect(std.mem.indexOf(u8, output, "█") == null);
	try testing.expect(std.mem.indexOf(u8, output, "▄") == null);
	try testing.expect(std.mem.indexOf(u8, output, "▌") == null);
}

test "renderFrameFromBlocksBuffer is deterministic" {
	var gpa: std.heap.DebugAllocator(.{}) = .init;
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	const state = renderer.RenderState{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.max_iter = 50,
		.show_info = false,
		.glyph_mode = .blocks,
	};

	const width: u16 = 3;
	const height: u16 = 2;
	// 3x2 display → 6x4 iter_buf = 24 values
	var iter_buf: [24]f64 = undefined;
	for (&iter_buf, 0..) |*v, i| {
		v.* = @as(f64, @floatFromInt(i)) * 5.0;
	}

	const out1 = try renderer.renderFrameFromBlocksBuffer(state, width, height, &iter_buf, allocator);
	defer allocator.free(out1);
	const out2 = try renderer.renderFrameFromBlocksBuffer(state, width, height, &iter_buf, allocator);
	defer allocator.free(out2);

	try testing.expectEqualSlices(u8, out1, out2);
}

const std = @import("std");
const testing = std.testing;
const renderer = @import("renderer");
const mandelbrot = @import("mandelbrot");

test "renderFrame produces output for small terminal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

const std = @import("std");
const testing = std.testing;
const renderer = @import("renderer");

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
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[") != null);
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

    const output = try renderer.renderFrame(state, 40, 10, allocator);
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

test "renderFrame interior region is mostly dark" {
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

    var spaces: usize = 0;
    var total: usize = 0;
    for (output) |byte| {
        if (byte >= 0x20 and byte <= 0x7e) {
            total += 1;
            if (byte == ' ') spaces += 1;
        }
    }
    try testing.expect(spaces > total / 4);
}

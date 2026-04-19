// src/tui/renderer.zig
// Pure function: RenderState + dimensions -> ANSI output buffer.
// No I/O — returns a buffer that the caller writes to the terminal.
// Uses 24-bit true-color escape sequences for smooth Bernstein palette gradients.

const std = @import("std");
const mandelbrot = @import("mandelbrot");
const coloring = @import("coloring");

pub const RenderState = struct {
    center_re: f128,
    center_im: f128,
    zoom: f128,
    max_iter: u32,
    show_info: bool,
};

const ASPECT_RATIO: f64 = 0.5;

/// Render from a pre-computed iteration buffer.
/// iter_buf must have length >= width * render_height (where render_height accounts
/// for the info bar if enabled). The buffer is row-major.
/// Caller owns the returned memory.
pub fn renderFrameFromBuffer(
    state: RenderState,
    width: u16,
    height: u16,
    iter_buf: []const f64,
    allocator: std.mem.Allocator,
) ![]u8 {
    const render_height: u16 = if (state.show_info and height > 1) height - 1 else height;
    const pixel_count: usize = @as(usize, width) * @as(usize, render_height);

    var output: std.ArrayListUnmanaged(u8) = .{};

    // True-color escapes are ~20 bytes per color change: \x1b[38;2;RRR;GGG;BBBm
    try output.ensureTotalCapacity(allocator, 6 + pixel_count * 25 + 300);

    // Cursor home
    try output.appendSlice(allocator, "\x1b[H");

    var last_r: u8 = 255;
    var last_g: u8 = 255;
    var last_b: u8 = 255;
    var last_interior: bool = false;

    var row: u16 = 0;
    while (row < render_height) : (row += 1) {
        var col: u16 = 0;
        while (col < width) : (col += 1) {
            const idx = @as(usize, row) * @as(usize, width) + @as(usize, col);
            const cell = coloring.iterToCell(iter_buf[idx], state.max_iter);

            // Delta color encoding: only emit escape when color changes
            if (cell.is_interior and !last_interior) {
                // Switch to black fg on black bg for interior
                try output.appendSlice(allocator, "\x1b[38;2;0;0;0;48;2;0;0;0m");
                last_interior = true;
            } else if (!cell.is_interior) {
                if (last_interior or cell.color.r != last_r or cell.color.g != last_g or cell.color.b != last_b) {
                    var color_buf: [40]u8 = undefined;
                    const color_str = std.fmt.bufPrint(&color_buf, "\x1b[38;2;{d};{d};{d};48;2;0;0;0m", .{
                        cell.color.r, cell.color.g, cell.color.b,
                    }) catch unreachable;
                    try output.appendSlice(allocator, color_str);
                    last_r = cell.color.r;
                    last_g = cell.color.g;
                    last_b = cell.color.b;
                    last_interior = false;
                }
            }

            try output.append(allocator, cell.char);
        }
        if (row < render_height - 1) {
            try output.appendSlice(allocator, "\r\n");
        }
    }

    // Info bar
    if (state.show_info and height > 1) {
        try output.appendSlice(allocator, "\r\n");
        try output.appendSlice(allocator, "\x1b[0m\x1b[7m");

        var info_buf: [256]u8 = undefined;
        const cre_f64: f64 = @floatCast(state.center_re);
        const cim_f64: f64 = @floatCast(state.center_im);
        const zoom_f64: f64 = @floatCast(state.zoom);

        const info_str = std.fmt.bufPrint(&info_buf, " MANDELBROT_CENTER_RE={d:.15} MANDELBROT_CENTER_IM={d:.15} MANDELBROT_ZOOM={e} mandelbrot | iter={d}", .{
            cre_f64, cim_f64, zoom_f64, state.max_iter,
        }) catch " [info too long]";

        const info_len = @min(info_str.len, @as(usize, width));
        try output.appendSlice(allocator, info_str[0..info_len]);

        var pad: usize = info_len;
        while (pad < width) : (pad += 1) {
            try output.append(allocator, ' ');
        }

        try output.appendSlice(allocator, "\x1b[0m");
    }

    return try output.toOwnedSlice(allocator);
}

/// Render a complete frame as an ANSI-escaped byte buffer.
/// Convenience wrapper: computes the iteration buffer internally, then calls
/// renderFrameFromBuffer. Uses 24-bit true-color (\x1b[38;2;R;G;Bm) for smooth gradients.
/// Caller owns the returned memory.
pub fn renderFrame(
    state: RenderState,
    width: u16,
    height: u16,
    allocator: std.mem.Allocator,
) ![]u8 {
    const render_height: u16 = if (state.show_info and height > 1) height - 1 else height;
    const pixel_count: usize = @as(usize, width) * @as(usize, render_height);

    const iter_buf = try allocator.alloc(f64, pixel_count);
    defer allocator.free(iter_buf);

    mandelbrot.computeRegion(.{
        .center_re = state.center_re,
        .center_im = state.center_im,
        .zoom = state.zoom,
        .width = width,
        .height = render_height,
        .max_iter = state.max_iter,
        .aspect_ratio = ASPECT_RATIO,
    }, iter_buf);

    return renderFrameFromBuffer(state, width, height, iter_buf, allocator);
}

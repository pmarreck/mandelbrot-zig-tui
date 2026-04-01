// src/tui/renderer.zig
// Pure function: RenderState + dimensions -> ANSI output buffer.
// No I/O — returns a buffer that the caller writes to the terminal.

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

/// Render a complete frame as an ANSI-escaped byte buffer.
/// Takes immutable render state and terminal dimensions, returns a fully-formed
/// ANSI escape sequence buffer. The caller owns the returned memory and is
/// responsible for writing it to the terminal and freeing it.
/// Key technique: single-pass row-major scan with delta color encoding to
/// minimize ANSI escape overhead.
pub fn renderFrame(
    state: RenderState,
    width: u16,
    height: u16,
    allocator: std.mem.Allocator,
) ![]u8 {
    const render_height: u16 = if (state.show_info and height > 1) height - 1 else height;
    const pixel_count: usize = @as(usize, width) * @as(usize, render_height);

    const iter_buf = try allocator.alloc(u32, pixel_count);
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

    var output: std.ArrayListUnmanaged(u8) = .{};
    // Ownership transfers to caller via toOwnedSlice — no defer deinit.

    // Pre-allocate: cursor home (3) + per-cell worst case (~30 bytes for color+char) + info bar (~300)
    try output.ensureTotalCapacity(allocator, 6 + pixel_count * 30 + 300);

    // Cursor home
    try output.appendSlice(allocator, "\x1b[H");

    var last_fg: u8 = 255;
    var last_bg: u8 = 255;

    var row: u16 = 0;
    while (row < render_height) : (row += 1) {
        var col: u16 = 0;
        while (col < width) : (col += 1) {
            const idx = @as(usize, row) * @as(usize, width) + @as(usize, col);
            const cell = coloring.iterToCell(iter_buf[idx], state.max_iter);

            // Only emit color escape when fg or bg changes from previous cell
            if (cell.fg_color != last_fg or cell.bg_color != last_bg) {
                var color_buf: [32]u8 = undefined;
                const color_str = std.fmt.bufPrint(&color_buf, "\x1b[38;5;{d};48;5;{d}m", .{
                    cell.fg_color, cell.bg_color,
                }) catch unreachable;
                try output.appendSlice(allocator, color_str);
                last_fg = cell.fg_color;
                last_bg = cell.bg_color;
            }

            try output.append(allocator, cell.char);
        }
        if (row < render_height - 1) {
            try output.appendSlice(allocator, "\r\n");
        }
    }

    // Info bar: reversed-video status line with coordinates and parameters
    if (state.show_info and height > 1) {
        try output.appendSlice(allocator, "\r\n");
        try output.appendSlice(allocator, "\x1b[0m\x1b[7m");

        var info_buf: [256]u8 = undefined;
        const cre_f64: f64 = @floatCast(state.center_re);
        const cim_f64: f64 = @floatCast(state.center_im);
        const zoom_f64: f64 = @floatCast(state.zoom);

        const info_str = std.fmt.bufPrint(&info_buf, " MANDELBROT re={d:.6} im={d:.6} zoom={e} iter={d}", .{
            cre_f64, cim_f64, zoom_f64, state.max_iter,
        }) catch " [info too long]";

        const info_len = @min(info_str.len, @as(usize, width));
        try output.appendSlice(allocator, info_str[0..info_len]);

        // Pad the rest of the info bar width with spaces
        var pad: usize = info_len;
        while (pad < width) : (pad += 1) {
            try output.append(allocator, ' ');
        }

        try output.appendSlice(allocator, "\x1b[0m");
    }

    return try output.toOwnedSlice(allocator);
}

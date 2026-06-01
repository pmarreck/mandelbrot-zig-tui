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
    glyph_mode: coloring.GlyphMode = .density,
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

    var output: std.ArrayListUnmanaged(u8) = .empty;

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

        const info_str = std.fmt.bufPrint(&info_buf, " MANDELBROT_CENTER_RE={d:.15} MANDELBROT_CENTER_IM={d:.15} MANDELBROT_ZOOM={e} mandelbrot | iter={d} glyph=density", .{
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


/// Render a blocks-mode frame from a 2×-resolution iteration buffer.
/// iter_buf must have (width * 2) * (render_height * 2) values, row-major,
/// where render_height = height - 1 if show_info else height.
/// Each terminal cell reads its 2×2 sub-pixels and produces a Unicode block quadrant
/// with FG/BG colors via median-split clustering (see coloring.iterToBlock).
/// Caller owns the returned memory.
pub fn renderFrameFromBlocksBuffer(
	state: RenderState,
	width: u16,
	height: u16,
	iter_buf: []const f64,
	allocator: std.mem.Allocator,
) ![]u8 {
	const render_height: u16 = if (state.show_info and height > 1) height - 1 else height;
	const sub_width: u32 = @as(u32, width) * 2;

	var output: std.ArrayListUnmanaged(u8) = .empty;

	// Each block cell emits ~40 bytes worst case (color escape + 3-byte UTF-8 char).
	try output.ensureTotalCapacity(allocator, 6 + @as(usize, width) * @as(usize, render_height) * 40 + 300);

	// Cursor home
	try output.appendSlice(allocator, "\x1b[H");

	// Track previous FG+BG to emit color escapes only on change.
	var last_fg_r: u8 = 255;
	var last_fg_g: u8 = 255;
	var last_fg_b: u8 = 255;
	var last_bg_r: u8 = 255;
	var last_bg_g: u8 = 255;
	var last_bg_b: u8 = 255;

	var row: u16 = 0;
	while (row < render_height) : (row += 1) {
		var col: u16 = 0;
		while (col < width) : (col += 1) {
			const sub_row: u32 = @as(u32, row) * 2;
			const sub_col: u32 = @as(u32, col) * 2;
			const tl_idx: usize = @as(usize, sub_row) * @as(usize, sub_width) + @as(usize, sub_col);
			const tr_idx: usize = tl_idx + 1;
			const bl_idx: usize = tl_idx + @as(usize, sub_width);
			const br_idx: usize = bl_idx + 1;

			const block = coloring.iterToBlock(
				iter_buf[tl_idx],
				iter_buf[tr_idx],
				iter_buf[bl_idx],
				iter_buf[br_idx],
				state.max_iter,
			);

			// Emit color escape only when FG or BG changes from previous cell
			if (block.fg.r != last_fg_r or block.fg.g != last_fg_g or block.fg.b != last_fg_b or
				block.bg.r != last_bg_r or block.bg.g != last_bg_g or block.bg.b != last_bg_b)
			{
				var color_buf: [64]u8 = undefined;
				const color_str = std.fmt.bufPrint(&color_buf, "\x1b[38;2;{d};{d};{d};48;2;{d};{d};{d}m", .{
					block.fg.r, block.fg.g, block.fg.b,
					block.bg.r, block.bg.g, block.bg.b,
				}) catch unreachable;
				try output.appendSlice(allocator, color_str);
				last_fg_r = block.fg.r;
				last_fg_g = block.fg.g;
				last_fg_b = block.fg.b;
				last_bg_r = block.bg.r;
				last_bg_g = block.bg.g;
				last_bg_b = block.bg.b;
			}

			try output.appendSlice(allocator, block.char_bytes);
		}
		if (row < render_height - 1) {
			try output.appendSlice(allocator, "\r\n");
		}
	}

	// Info bar (identical to density-mode renderer, but with "glyph=blocks")
	if (state.show_info and height > 1) {
		try output.appendSlice(allocator, "\r\n");
		try output.appendSlice(allocator, "\x1b[0m\x1b[7m");

		var info_buf: [256]u8 = undefined;
		const cre_f64: f64 = @floatCast(state.center_re);
		const cim_f64: f64 = @floatCast(state.center_im);
		const zoom_f64: f64 = @floatCast(state.zoom);

		const info_str = std.fmt.bufPrint(&info_buf, " MANDELBROT_CENTER_RE={d:.15} MANDELBROT_CENTER_IM={d:.15} MANDELBROT_ZOOM={e} mandelbrot | iter={d} glyph=blocks", .{
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


/// Render a kitty-graphics-protocol frame from a per-pixel iteration buffer.
/// iter_buf holds (term_width × cell_px_w) × (render_height × cell_px_h) f64
/// values, row-major; each is converted to an RGB triple via coloring.iterToColor
/// and the whole image is transmitted as raw RGB chunked base64 over the
/// kitty graphics escape protocol. The image displays at the current cursor
/// position without moving the terminal cursor; the optional info bar is
/// positioned explicitly so full-height images never scroll the terminal.
/// Caller owns the returned memory.
pub fn renderFrameKitty(
	state: RenderState,
	width: u16,
	height: u16,
	cell_px_w: u16,
	cell_px_h: u16,
	iter_buf: []const f64,
	allocator: std.mem.Allocator,
) ![]u8 {
	const render_height: u16 = if (state.show_info and height > 1) height - 1 else height;
	const px_w: u32 = @as(u32, width) * @as(u32, cell_px_w);
	const px_h: u32 = @as(u32, render_height) * @as(u32, cell_px_h);
	const pixel_count: usize = @as(usize, px_w) * @as(usize, px_h);

	// RGB scratch: 3 bytes per pixel, then base64-chunk it into kitty escapes.
	const rgb_bytes = try allocator.alloc(u8, pixel_count * 3);
	defer allocator.free(rgb_bytes);

	var i: usize = 0;
	while (i < pixel_count) : (i += 1) {
		const color = coloring.iterToColor(iter_buf[i], state.max_iter);
		rgb_bytes[i * 3 + 0] = color.r;
		rgb_bytes[i * 3 + 1] = color.g;
		rgb_bytes[i * 3 + 2] = color.b;
	}

	var output: std.ArrayListUnmanaged(u8) = .empty;
	// Rough envelope: base64 grows by 4/3, plus per-chunk header overhead.
	const est = (rgb_bytes.len * 4 / 3) + (rgb_bytes.len / 3072 + 1) * 48 + 512;
	try output.ensureTotalCapacity(allocator, est);

	// Cursor home so the image lands in the top-left of the screen.
	try output.appendSlice(allocator, "\x1b[H");

	// Kitty graphics chunked transmission.
	// f=24 RGB, t=d direct payload, a=T transmit + display,
	// i=1 image ID (reusing the same slot frees prior frame),
	// q=2 suppress all responses, C=1 prevents cursor movement, m=1/0
	// chunk continuation marker.
	// Per spec the base64 payload of each chunk should be ≤ 4096 chars,
	// so we feed 3072 raw bytes per chunk (3072 * 4/3 = 4096).
	const CHUNK_RAW: usize = 3072;
	const b64 = std.base64.standard.Encoder;

	var offset: usize = 0;
	var first_chunk = true;
	while (offset < rgb_bytes.len) {
		const remaining = rgb_bytes.len - offset;
		const this_chunk = @min(CHUNK_RAW, remaining);
		const is_last = (offset + this_chunk) == rgb_bytes.len;
		const m_flag: u8 = if (is_last) '0' else '1';

		// Header for this chunk. z=INT32_MIN puts the image below text AND
		// below cell background colors (per kitty graphics protocol: any z
		// less than INT32_MIN/2 enables this regime). z=-1 alone would
		// keep the image above cell bg, leaving overlays like the help
		// modal — which uses an explicit black bg to cover image cells —
		// looking transparent. With z=INT32_MIN, cells with any explicit
		// bg color (modal interior, info bar reverse video) fully cover
		// the image; cells we never write keep default attributes and
		// show the image through.
		var hdr_buf: [128]u8 = undefined;
		const hdr = if (first_chunk)
			std.fmt.bufPrint(&hdr_buf, "\x1b_Gf=24,s={d},v={d},a=T,t=d,i=1,q=2,C=1,z=-2147483648,m={c};", .{ px_w, px_h, m_flag }) catch unreachable
		else
			std.fmt.bufPrint(&hdr_buf, "\x1b_Gm={c};", .{m_flag}) catch unreachable;
		try output.appendSlice(allocator, hdr);

		// Reserve worst-case base64 length and encode in place.
		const enc_len = b64.calcSize(this_chunk);
		try output.ensureUnusedCapacity(allocator, enc_len + 2);
		const dst = output.allocatedSlice()[output.items.len .. output.items.len + enc_len];
		_ = b64.encode(dst, rgb_bytes[offset .. offset + this_chunk]);
		output.items.len += enc_len;

		try output.appendSlice(allocator, "\x1b\\");

		offset += this_chunk;
		first_chunk = false;
	}

	// Info bar: explicitly place it on the terminal's last row. This keeps
	// the image command cursor-neutral, including when show_info=false and
	// the image is full-height.
	if (state.show_info and height > 1) {
		var pos_buf: [32]u8 = undefined;
		const pos = std.fmt.bufPrint(&pos_buf, "\x1b[{d};1H", .{height}) catch unreachable;
		try output.appendSlice(allocator, pos);
		try output.appendSlice(allocator, "\x1b[0m\x1b[7m");

		var info_buf: [256]u8 = undefined;
		const cre_f64: f64 = @floatCast(state.center_re);
		const cim_f64: f64 = @floatCast(state.center_im);
		const zoom_f64: f64 = @floatCast(state.zoom);

		const info_str = std.fmt.bufPrint(&info_buf, " MANDELBROT_CENTER_RE={d:.15} MANDELBROT_CENTER_IM={d:.15} MANDELBROT_ZOOM={e} mandelbrot | iter={d} glyph=kitty", .{
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


/// Emit ONLY the kitty-mode info bar at the last row of the terminal. Used
/// by the modal-close fast path: when closing the help modal in kitty mode
/// with an unchanged viewport, the kitty image is still placed in the
/// terminal (clearScreen doesn't remove image placements, only cell text),
/// so all we need to do is wipe modal residue (caller does clearScreen)
/// and re-paint the info bar over its row. Avoids the full ~1 MB RGB
/// encode + base64 transmit cycle of renderFrameKitty.
pub fn renderKittyInfoBarOnly(
	state: RenderState,
	width: u16,
	height: u16,
	allocator: std.mem.Allocator,
) ![]u8 {
	if (!state.show_info or height <= 1) {
		return try allocator.alloc(u8, 0);
	}

	var output: std.ArrayListUnmanaged(u8) = .empty;
	try output.ensureTotalCapacity(allocator, 320);

	// Move cursor to (row=height, col=1) — the info bar's row.
	var pos_buf: [32]u8 = undefined;
	const pos = std.fmt.bufPrint(&pos_buf, "\x1b[{d};1H", .{height}) catch unreachable;
	try output.appendSlice(allocator, pos);
	try output.appendSlice(allocator, "\x1b[0m\x1b[7m");

	var info_buf: [256]u8 = undefined;
	const cre_f64: f64 = @floatCast(state.center_re);
	const cim_f64: f64 = @floatCast(state.center_im);
	const zoom_f64: f64 = @floatCast(state.zoom);

	const info_str = std.fmt.bufPrint(&info_buf, " MANDELBROT_CENTER_RE={d:.15} MANDELBROT_CENTER_IM={d:.15} MANDELBROT_ZOOM={e} mandelbrot | iter={d} glyph=kitty", .{
		cre_f64, cim_f64, zoom_f64, state.max_iter,
	}) catch " [info too long]";

	const info_len = @min(info_str.len, @as(usize, width));
	try output.appendSlice(allocator, info_str[0..info_len]);

	var pad: usize = info_len;
	while (pad < width) : (pad += 1) {
		try output.append(allocator, ' ');
	}

	try output.appendSlice(allocator, "\x1b[0m");
	return try output.toOwnedSlice(allocator);
}


/// Render the help modal as an overlay. Does NOT redraw the underlying frame —
/// the caller is responsible for either rendering a frame first (so the modal
/// appears on top of the current view) or for setting needs_redraw on close so
/// the cells covered by the modal get repainted.
///
/// The modal is a fixed 40×20 cell box, centered when the terminal is large
/// enough; otherwise pinned to the top-left. Content is plain ASCII inside
/// Unicode box-drawing borders so the visible widths line up regardless of
/// font metrics.
pub fn renderHelpModal(
	width: u16,
	height: u16,
	allocator: std.mem.Allocator,
) ![]u8 {
	const modal_lines = [_][]const u8{
		"┌─ mandelbrot - keys & mouse ──────────┐",
		"│                                      │",
		"│  Mouse                               │",
		"│   Left-click    Zoom in 2x at point  │",
		"│   Right-click   Zoom out 2x at point │",
		"│   Drag          Pan                  │",
		"│   Scroll wheel  Zoom in / out        │",
		"│                                      │",
		"│  Keys                                │",
		"│   + / =         Zoom in 2x           │",
		"│   -             Zoom out 2x          │",
		"│   Arrow keys    Pan                  │",
		"│   [ / ]         -/+ max iterations   │",
		"│   g             Cycle glyph mode     │",
		"│   i             Toggle info bar      │",
		"│   ? / h         This help            │",
		"│   q / Ctrl-C    Quit                 │",
		"│                                      │",
		"│        Press any key to close        │",
		"└──────────────────────────────────────┘",
	};
	const modal_w_cells: u16 = 40;
	const modal_h_cells: u16 = @intCast(modal_lines.len);

	const start_col: u16 = if (width > modal_w_cells) (width - modal_w_cells) / 2 + 1 else 1;
	const start_row: u16 = if (height > modal_h_cells) (height - modal_h_cells) / 2 + 1 else 1;

	var output: std.ArrayListUnmanaged(u8) = .empty;
	try output.ensureTotalCapacity(allocator, modal_lines.len * 96);

	// Reset attributes, then white-on-black for modal contents (forces a
	// readable color combo regardless of the underlying frame's last color).
	try output.appendSlice(allocator, "\x1b[0m\x1b[37;40m");

	for (modal_lines, 0..) |line, i| {
		const row: u16 = start_row + @as(u16, @intCast(i));
		var pos_buf: [32]u8 = undefined;
		const pos = std.fmt.bufPrint(&pos_buf, "\x1b[{d};{d}H", .{ row, start_col }) catch continue;
		try output.appendSlice(allocator, pos);
		try output.appendSlice(allocator, line);
	}

	try output.appendSlice(allocator, "\x1b[0m");
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

// src/tui/app.zig
// Event loop and state machine. Orchestrates input, state, and rendering.
// Pure state transitions (processEvent) are separated from I/O (run) for testability.

const std = @import("std");
const terminal = @import("terminal");
const input = @import("input");
const renderer = @import("renderer");
const viewport = @import("viewport");
const cache_mod = @import("cache");
const mandelbrot = @import("mandelbrot");
const pool = @import("pool");
const coloring = @import("coloring");
const animation = @import("animation");
const runtime = @import("runtime");

const ZOOM_FACTOR: f128 = 2.0;
/// Cell-mode aspect ratio (chars are ~2× taller than wide); used by viewport
/// math + density/blocks compute. Kitty mode computes per-pixel and uses 1.0.
const ASPECT_RATIO: f64 = 0.5;

/// Aspect-ratio compensation for the iteration grid in each glyph mode.
/// Density/blocks compute over cell-aligned grids (cells are ~2:1 H:W);
/// kitty computes over native square pixels.
fn computeAspect(mode: coloring.GlyphMode) f64 {
	return switch (mode) {
		.density, .blocks => ASPECT_RATIO,
		.kitty => 1.0,
	};
}

pub const AppState = struct {
	center_re: f128,
	center_im: f128,
	zoom: f128,
	max_iter: u32,
	base_iter: u32,
	show_info: bool,
	term_width: u16,
	term_height: u16,
	needs_redraw: bool,
	running: bool,
	/// Track mouse press position for drag detection.
	/// null = no button currently held.
	drag_start: ?input.MousePos = null,
	/// Set to true once a drag motion event fires. Prevents release from zooming.
	did_drag: bool = false,
	glyph_mode: coloring.GlyphMode = .density,
	/// Cell pixel dimensions for kitty-graphics mode. Default (1,1) is harmless
	/// for density/blocks since neither reads these. main.zig populates them
	/// from terminal.getCellPixelSizePosix at startup.
	cell_px_w: u16 = 1,
	cell_px_h: u16 = 1,
	/// Tracks the glyph_mode of the most recently rendered frame so that when
	/// the user toggles out of kitty mode we can delete the lingering image
	/// from the terminal's image cache before drawing cell-mode output.
	last_rendered_glyph_mode: ?coloring.GlyphMode = null,
	/// Whether the kitty graphics protocol is available in this terminal.
	/// Detected at startup (terminal.detectKittyGraphicsSupport) or forced via
	/// --force-kitty. Gates the kitty option in the g-cycle so users on
	/// non-supporting terminals don't end up with a screenful of escape garbage.
	kitty_available: bool = false,
	/// Whether the help modal is currently displayed. While true, every input
	/// event closes the modal (any key / mouse click) and triggers a redraw of
	/// the underlying frame. processEvent does not propagate the dismissing
	/// event to its normal handler — pressing 'g' to close the modal does not
	/// also cycle the glyph mode.
	show_help: bool = false,
	/// Test instrumentation: when true, renderOneFrame emits an APC sync
	/// marker (\x1b_=FRAME=\x1b\\) after each frame flush. PTY-driven
	/// integration tests block on this marker via tmux pipe-pane to
	/// synchronize event-driven instead of polling-with-sleeps. Set via
	/// the MANDELBROT_FRAME_MARKER env var. Has no visible effect — APC
	/// sequences are silently consumed by terminals that don't recognize them.
	frame_marker: bool = false,
	/// Tracks whether the most recent render was the help modal. On the
	/// transition modal → frame, renderOneFrame issues a clearScreen so
	/// that residual modal box-drawing chars don't ghost on top of the
	/// next frame in kitty mode (where the kitty graphics command places
	/// an image but does not overwrite cell text content).
	last_rendered_modal: bool = false,
};

pub fn defaultState() AppState {
	return .{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.max_iter = 256,
		.base_iter = 256,
		.show_info = true,
		.term_width = 80,
		.term_height = 24,
		.needs_redraw = true,
		.running = true,
	};
}

pub fn run(initial_state: AppState, allocator: std.mem.Allocator) !void {
	var state = initial_state;
	state.needs_redraw = true;

	// Cache + scheduler owned by the event loop.
	// cache_stack holds up to 5 pre-rendered resolution levels; scheduler
	// drives background pre-computation of levels 1-4 after each render.
	var cache_stack = cache_mod.CacheStack.init();
	defer cache_stack.deinit(allocator);

	var scheduler = pool.BackgroundScheduler.init(allocator, &cache_stack);
	defer scheduler.stop();

	const io = runtime.io();
	const stdout_file = std.Io.File.stdout();
	const stdin_file = std.Io.File.stdin();

	try terminal.enterRawMode();
	errdefer terminal.exitRawMode();

	var stdout_buf: [16384]u8 = undefined;
	var stdout_writer = stdout_file.writer(io, &stdout_buf);
	const stdout = &stdout_writer.interface;

	try terminal.hideCursor(stdout);
	try terminal.enableMouseTracking(stdout);
	try terminal.clearScreen(stdout);
	try stdout.flush();

	terminal.setupSigwinch();

	var read_buf: [256]u8 = undefined;

	while (state.running) {
		if (terminal.checkAndClearResizeFlag()) {
			if (terminal.getTermSizePosix()) |size| {
				state.term_width = size.cols;
				state.term_height = size.rows;
				state.needs_redraw = true;
				// Terminal size changed — stop the scheduler so its workers
				// don't race with the next render's cache mutation. We do
				// NOT invalidate here: renderOneFrame's coverage check needs
				// to *see* the old levels in order to extract from them
				// (zoom-in prefetch). When no level matches, renderOneFrame
				// invalidates and re-inits Level 0 itself.
				scheduler.stop();
			} else |_| {}
		}

		if (state.needs_redraw) {
			try renderOneFrame(&state, &cache_stack, &scheduler, allocator, stdout);
		}

		const n = readStdin(io, stdin_file, &read_buf);
		if (n == 0) continue;

		const event = input.parseEvent(read_buf[0..n]);
		const new_state = processEvent(state, event);

		// Viewport changed — stop the background scheduler so its workers
		// can't race with the next render's cache mutation. Crucially, do
		// NOT invalidate the cache here; renderOneFrame needs the deeper
		// levels to *still exist* so findCoveringLevel can extract a 2× /
		// 4× zoom-in hit from them. renderOneFrame invalidates after the
		// extraction succeeds (or after fresh compute, when neither level
		// 0 nor any deeper level satisfied the new viewport).
		if (viewportChanged(state, new_state)) {
			scheduler.stop();
		}
		state = new_state;
	}

	try terminal.deleteKittyImageById(stdout, 1);
	try terminal.disableMouseTracking(stdout);
	try terminal.showCursor(stdout);
	try terminal.clearScreen(stdout);
	try stdout.flush();
	terminal.exitRawMode();
}

/// Non-blocking-ish read from stdin into the caller's buffer. Returns 0 on EOF
/// or error so the event loop can keep ticking. Wraps `readStreaming`'s slice-
/// of-slices contract for the common "single buffer" case.
fn readStdin(io: std.Io, stdin_file: std.Io.File, out: []u8) usize {
	const n = stdin_file.readStreaming(io, &.{out}) catch return 0;
	return n;
}

/// Render a single frame using the current state. Shared between interactive
/// mode (run) and animation mode (runAnimation). Handles cache lookup, parallel
/// compute on miss, dispatch to density/blocks renderer, writeAll, flush, and
/// kick scheduler for background pre-computation.
pub fn renderOneFrame(
	state: *AppState,
	cache_stack: *cache_mod.CacheStack,
	scheduler: *pool.BackgroundScheduler,
	allocator: std.mem.Allocator,
	stdout: *std.Io.Writer,
) !void {
	// Help modal: draw on top of whatever's currently displayed (do not
	// recompute the frame underneath). Closing the modal sets needs_redraw
	// true so the next pass repaints the normal frame.
	if (state.show_help) {
		const modal = try renderer.renderHelpModal(state.term_width, state.term_height, allocator);
		defer allocator.free(modal);
		try stdout.writeAll(modal);
		try stdout.flush();
		state.needs_redraw = false;
		state.last_rendered_modal = true;
		if (state.frame_marker) {
			try stdout.writeAll("\x1b_=FRAME=\x1b\\");
			try stdout.flush();
		}
		return;
	}

	const render_height: u16 = if (state.show_info and state.term_height > 1)
		state.term_height - 1
	else
		state.term_height;

	// Sub-pixel multipliers per axis: 1 for density, 2 for blocks, full
	// cell pixel size for kitty (which renders at native pixel resolution).
	const sub_w: u16 = switch (state.glyph_mode) {
		.density => 1,
		.blocks => 2,
		.kitty => state.cell_px_w,
	};
	const sub_h: u16 = switch (state.glyph_mode) {
		.density => 1,
		.blocks => 2,
		.kitty => state.cell_px_h,
	};
	const aspect: f64 = computeAspect(state.glyph_mode);
	const buf_width: u16 = state.term_width * sub_w;
	const buf_height: u16 = render_height * sub_h;
	const pixel_count = @as(usize, buf_width) * @as(usize, buf_height);

	const iter_buf = try allocator.alloc(f64, pixel_count);
	defer allocator.free(iter_buf);

	// Compute the expected viewport quantities once — used for both the
	// Level 0 exact-match check and the deeper-level coverage search.
	const w_f128: f128 = @floatFromInt(buf_width);
	const h_f128: f128 = @floatFromInt(buf_height);
	const aspect_f128: f128 = @floatCast(aspect);
	const expected_range_re: f128 = 4.0 / state.zoom;
	const expected_range_im: f128 = expected_range_re * (h_f128 / w_f128) / aspect_f128;
	const expected_origin_re: f128 = state.center_re - expected_range_re / 2.0;
	const expected_origin_im: f128 = state.center_im - expected_range_im / 2.0;
	const expected_step_re: f128 = expected_range_re / w_f128;
	const expected_step_im: f128 = expected_range_im / h_f128;

	// Path 1: Level 0 exact match. Same viewport as the previous render
	// (e.g. info-bar toggle, modal close) — instant memcpy from the cache.
	var cache_hit = false;
	if (cache_stack.levels[0]) |level| {
		if (level.complete and
			level.width == buf_width and
			level.height == buf_height and
			level.max_iter == state.max_iter and
			level.origin_re == expected_origin_re and
			level.origin_im == expected_origin_im and
			level.step_re == expected_step_re and
			level.step_im == expected_step_im)
		{
			@memcpy(iter_buf, level.data[0..pixel_count]);
			cache_hit = true;
		}
	}

	if (!cache_hit) {
		scheduler.stop();

		// Path 2: deeper-level coverage hit. When the user zooms in 2× (at
		// center or at any cursor position), the new viewport's step is
		// bit-exactly half of Level 0's, matching Level 1's step. If Level 1
		// is complete and its bbox contains the new viewport, we extract
		// the right W×H sub-grid in O(W*H) memory bandwidth instead of
		// running the full escape-time loop. Same trick works for 4× zoom
		// via Level 2, though no UI action triggers that today.
		var extracted = false;
		if (cache_stack.findCoveringLevel(
			expected_origin_re,
			expected_origin_im,
			expected_step_re,
			expected_step_im,
			buf_width,
			buf_height,
			state.max_iter,
		)) |coverage| {
			cache_stack.extractInto(coverage, buf_width, buf_height, iter_buf);
			extracted = true;
		}

		// Either way (extracted or about-to-fresh-compute), the prior cache
		// is no longer aligned with the new viewport — invalidate and
		// rebuild Level 0 with whatever data we end up with.
		cache_stack.invalidateAll(allocator);

		try cache_stack.initForViewport(
			allocator,
			state.center_re,
			state.center_im,
			state.zoom,
			buf_width,
			buf_height,
			state.max_iter,
			aspect,
		);

		// Path 3: fresh compute. Reached only when neither Level 0 nor any
		// deeper level satisfied the new viewport.
		if (!extracted) {
			try mandelbrot.parallelComputeRegion(.{
				.center_re = state.center_re,
				.center_im = state.center_im,
				.zoom = state.zoom,
				.width = buf_width,
				.height = buf_height,
				.max_iter = state.max_iter,
				.aspect_ratio = aspect,
			}, iter_buf, null);
		}

		if (cache_stack.levels[0]) |*level| {
			@memcpy(level.data, iter_buf);
			level.complete = true;
		}
	}

	const render_state = renderer.RenderState{
		.center_re = state.center_re,
		.center_im = state.center_im,
		.zoom = state.zoom,
		.max_iter = state.max_iter,
		.show_info = state.show_info,
		.glyph_mode = state.glyph_mode,
	};

	// Mode-transition / modal-close terminal cleanups. These all run BEFORE
	// the kitty fast-path check below — they wipe stale cell text from the
	// previous frame (modal box chars, residual density glyphs) so the image
	// underneath comes through cleanly when we don't re-emit it.

	// Transition out of kitty mode: free the placed image and clear cells.
	if (state.glyph_mode != .kitty and state.last_rendered_glyph_mode == .kitty) {
		try terminal.deleteKittyImageById(stdout, 1);
		try terminal.clearScreen(stdout);
	}

	// Transition INTO kitty mode from a different mode: clear residual cell
	// text/bg from the previous mode. With z=INT32_MIN on the kitty image,
	// non-default bg attrs in cells fully cover the image; without this
	// clear, leftover glyphs ghost on top of the new kitty frame.
	if (state.glyph_mode == .kitty and state.last_rendered_glyph_mode != null and state.last_rendered_glyph_mode.? != .kitty) {
		try terminal.clearScreen(stdout);
	}

	// Modal close → clearScreen so modal box-drawing chars don't ghost
	// through. Cell-mode renders fill every cell anyway, but kitty's
	// image-placement command alone doesn't overwrite cell text.
	if (state.last_rendered_modal and !state.show_help) {
		try terminal.clearScreen(stdout);
	}

	// Fast path: kitty mode with an unchanged viewport (e.g. modal close).
	// `cache_hit` from the Level 0 exact-match check above tells us the
	// terminal's already-placed kitty image is the right image for the
	// current state — clearScreen wipes cell text but does NOT remove
	// image placements, so we just need to redraw the info bar over its
	// row. Image reappears automatically because cells we don't touch
	// keep default attributes and let the z=INT32_MIN image show through.
	//
	// Crucially, this is gated by `cache_hit` from path 1 (Level 0 exact
	// match for the *new* viewport). Path 2 (deeper-level extract) and
	// path 3 (fresh compute) BOTH replace iter_buf with new data and
	// reinit Level 0 to the new viewport — they correspond to a viewport
	// CHANGE, where the terminal's existing image is now stale and must
	// be retransmitted. Only path 1 means "nothing has actually changed
	// in the iteration grid".
	if (cache_hit and
		state.glyph_mode == .kitty and
		state.last_rendered_glyph_mode == .kitty)
	{
		// Re-place the kitty image. The image data is still in the
		// terminal's storage by ID 1 from the prior frame, but the
		// PLACEMENT may have been erased by clearScreen above (terminal-
		// dependent: kitty preserves placements through ED, ghostty does
		// not). a=p re-creates the placement at cursor home using the
		// stored image data — tiny escape, no retransmission.
		try stdout.writeAll("\x1b[H");
		try terminal.placeKittyImageById(stdout, 1);
		const info = try renderer.renderKittyInfoBarOnly(
			render_state,
			state.term_width,
			state.term_height,
			allocator,
		);
		defer allocator.free(info);
		try stdout.writeAll(info);
		try stdout.flush();
		state.needs_redraw = false;
		state.last_rendered_modal = false;
		// last_rendered_glyph_mode stays .kitty
		if (state.frame_marker) {
			try stdout.writeAll("\x1b_=FRAME=\x1b\\");
			try stdout.flush();
		}
		scheduler.requestWork();
		return;
	}

	const frame = switch (state.glyph_mode) {
		.density => try renderer.renderFrameFromBuffer(render_state, state.term_width, state.term_height, iter_buf, allocator),
		.blocks => try renderer.renderFrameFromBlocksBuffer(render_state, state.term_width, state.term_height, iter_buf, allocator),
		.kitty => try renderer.renderFrameKitty(render_state, state.term_width, state.term_height, state.cell_px_w, state.cell_px_h, iter_buf, allocator),
	};
	defer allocator.free(frame);

	try stdout.writeAll(frame);
	try stdout.flush();
	state.needs_redraw = false;
	state.last_rendered_glyph_mode = state.glyph_mode;
	state.last_rendered_modal = false;

	if (state.frame_marker) {
		try stdout.writeAll("\x1b_=FRAME=\x1b\\");
		try stdout.flush();
	}

	scheduler.requestWork();
}

/// Animation mode: render `config.num_frames` progressive zoom frames,
/// pace to target fps, then either exit or fall through to interactive mode.
/// Reuses renderOneFrame so density/blocks/cache/scheduler all work identically to interactive.
pub fn runAnimation(
	config: animation.AnimationConfig,
	initial_state: AppState,
	allocator: std.mem.Allocator,
) !void {
	var state = initial_state;

	const is_tty = terminal.stdinIsTty();

	// Cache + scheduler owned here (same as run())
	var cache_stack = cache_mod.CacheStack.init();
	defer cache_stack.deinit(allocator);

	var scheduler = pool.BackgroundScheduler.init(allocator, &cache_stack);
	defer scheduler.stop();

	const io = runtime.io();
	const stdout_file = std.Io.File.stdout();

	var stdout_buf: [16384]u8 = undefined;
	var stdout_writer = stdout_file.writer(io, &stdout_buf);
	const stdout = &stdout_writer.interface;

	if (is_tty) {
		try terminal.enterRawMode();
		errdefer terminal.exitRawMode();

		try terminal.hideCursor(stdout);
		try terminal.enableMouseTracking(stdout);
		try terminal.clearScreen(stdout);
		try stdout.flush();

		terminal.setupSigwinch();
	}

	// Animation loop
	const target_frame_ns: u64 = 1_000_000_000 / config.fps;

	var stderr_buf: [4096]u8 = undefined;
	var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
	const stderr = &stderr_writer.interface;

	// Frame timing stats
	var total_elapsed_ns: u64 = 0;
	var min_frame_ns: u64 = std.math.maxInt(u64);
	var max_frame_ns: u64 = 0;
	var overrun_count: u32 = 0;

	const overall_start = std.Io.Timestamp.now(io, .awake);

	var frame_idx: u32 = 0;
	while (frame_idx < config.num_frames) : (frame_idx += 1) {
		const frame_start = std.Io.Timestamp.now(io, .awake);

		const params = animation.frameAt(config, frame_idx);
		state.center_re = params.center_re;
		state.center_im = params.center_im;
		state.zoom = params.zoom;
		state.max_iter = params.max_iter;
		state.needs_redraw = true;

		try renderOneFrame(&state, &cache_stack, &scheduler, allocator, stdout);

		const frame_end = std.Io.Timestamp.now(io, .awake);
		const elapsed_ns_i: i96 = frame_end.nanoseconds - frame_start.nanoseconds;
		const elapsed_u64: u64 = if (elapsed_ns_i > 0) @intCast(elapsed_ns_i) else 0;
		total_elapsed_ns += elapsed_u64;
		if (elapsed_u64 < min_frame_ns) min_frame_ns = elapsed_u64;
		if (elapsed_u64 > max_frame_ns) max_frame_ns = elapsed_u64;

		const target_ns_i: i96 = @intCast(target_frame_ns);
		if (elapsed_ns_i < target_ns_i) {
			const remaining_ns: u64 = @intCast(target_ns_i - elapsed_ns_i);
			// .awake clock matches the timestamps above; convert ns -> Duration.
			std.Io.sleep(io, .fromNanoseconds(@intCast(remaining_ns)), .awake) catch {};
		} else {
			overrun_count += 1;
		}
	}

	const overall_end = std.Io.Timestamp.now(io, .awake);
	const overall_elapsed_i96: i96 = overall_end.nanoseconds - overall_start.nanoseconds;
	const overall_elapsed_u64: u64 = if (overall_elapsed_i96 > 0) @intCast(overall_elapsed_i96) else 0;
	const overall_elapsed_sec: f64 = @as(f64, @floatFromInt(overall_elapsed_u64)) / 1_000_000_000.0;
	const target_duration_sec: f64 = @as(f64, @floatFromInt(config.num_frames)) / @as(f64, @floatFromInt(config.fps));
	const mean_frame_ms: f64 = @as(f64, @floatFromInt(total_elapsed_ns)) / @as(f64, @floatFromInt(config.num_frames)) / 1_000_000.0;
	const min_frame_ms: f64 = @as(f64, @floatFromInt(min_frame_ns)) / 1_000_000.0;
	const max_frame_ms: f64 = @as(f64, @floatFromInt(max_frame_ns)) / 1_000_000.0;
	const target_frame_ms: f64 = @as(f64, @floatFromInt(target_frame_ns)) / 1_000_000.0;
	const overrun_pct: f64 = @as(f64, @floatFromInt(overrun_count)) / @as(f64, @floatFromInt(config.num_frames)) * 100.0;

	// Hold on final frame if requested (honored in both tty and non-tty modes).
	// This runs BEFORE the stats print so the held frame isn't polluted by
	// stderr output scrolling underneath it.
	if (config.exit_after and config.hold_ms > 0) {
		std.Io.sleep(io, .fromMilliseconds(@intCast(config.hold_ms)), .awake) catch {};
	}

	try stderr.print("Animation complete: {d} frames in {d:.2}s (target {d:.2}s, {d} fps)\n", .{
		config.num_frames, overall_elapsed_sec, target_duration_sec, config.fps,
	});
	try stderr.print("  Min: {d:.1} ms   Max: {d:.1} ms   Mean: {d:.1} ms\n", .{
		min_frame_ms, max_frame_ms, mean_frame_ms,
	});
	try stderr.print("  >= target ({d:.1} ms): {d} frames ({d:.0}%)\n", .{
		target_frame_ms, overrun_count, overrun_pct,
	});
	try stderr.flush();

	// Non-tty mode: always exit (no interactive mode possible without stdin)
	// tty mode: exit only if exit_after set, otherwise fall through to interactive
	if (!is_tty or config.exit_after) {
		if (is_tty) {
			try terminal.deleteKittyImageById(stdout, 1);
			try terminal.disableMouseTracking(stdout);
			try terminal.showCursor(stdout);
			try terminal.clearScreen(stdout);
			try stdout.flush();
			terminal.exitRawMode();
		} else {
			try stdout.flush();
		}
		return;
	}

	// Fall through to interactive event loop using the final state (tty-only path).
	var read_buf: [256]u8 = undefined;
	const stdin_file = std.Io.File.stdin();

	while (state.running) {
		if (terminal.checkAndClearResizeFlag()) {
			if (terminal.getTermSizePosix()) |size| {
				state.term_width = size.cols;
				state.term_height = size.rows;
				state.needs_redraw = true;
				// See run() above: stop scheduler, do NOT invalidate —
				// renderOneFrame's coverage check needs the deeper levels.
				scheduler.stop();
			} else |_| {}
		}

		if (state.needs_redraw) {
			try renderOneFrame(&state, &cache_stack, &scheduler, allocator, stdout);
		}

		const n = readStdin(io, stdin_file, &read_buf);
		if (n == 0) continue;

		const event = input.parseEvent(read_buf[0..n]);
		const new_state = processEvent(state, event);

		if (viewportChanged(state, new_state)) {
			scheduler.stop();
		}
		state = new_state;
	}

	try terminal.deleteKittyImageById(stdout, 1);
	try terminal.disableMouseTracking(stdout);
	try terminal.showCursor(stdout);
	try terminal.clearScreen(stdout);
	try stdout.flush();
	terminal.exitRawMode();
}

/// Returns true if any viewport-defining field differs between two AppStates.
/// Used by the event loop to decide when to invalidate the cache: cache layout
/// depends on center/zoom/max_iter/term_width/term_height — any change to
/// these fields makes the existing cache stale.
fn viewportChanged(old: AppState, new: AppState) bool {
	return old.center_re != new.center_re or
		old.center_im != new.center_im or
		old.zoom != new.zoom or
		old.max_iter != new.max_iter or
		old.term_width != new.term_width or
		old.term_height != new.term_height or
		old.glyph_mode != new.glyph_mode;
}

/// Pure state transition function -- given current state and an event, returns new state.
/// No I/O, no side effects: testable as a pure function.
pub fn processEvent(state: AppState, event: input.Event) AppState {
	var s = state;

	// Modal capture: while help is showing, every input dismisses it and is
	// consumed (does not propagate to normal handlers). Resize is exempt — we
	// still want the modal to redraw at the new center on terminal resize.
	if (s.show_help) {
		switch (event) {
			.resize => {
				s.needs_redraw = true;
				return s;
			},
			.unknown => return s,
			else => {
				s.show_help = false;
				s.needs_redraw = true;
				return s;
			},
		}
	}

	switch (event) {
		.key_q, .ctrl_c => {
			s.running = false;
		},
		.key_plus => {
			const view = toViewState(s);
			const new_view = viewport.zoomAt(view, ZOOM_FACTOR, s.term_width / 2, s.term_height / 2, s.term_width, s.term_height, ASPECT_RATIO);
			applyViewState(&s, new_view);
			s.needs_redraw = true;
		},
		.key_minus => {
			const view = toViewState(s);
			const new_view = viewport.zoomAt(view, 1.0 / ZOOM_FACTOR, s.term_width / 2, s.term_height / 2, s.term_width, s.term_height, ASPECT_RATIO);
			applyViewState(&s, new_view);
			s.needs_redraw = true;
		},
		.mouse_left_press => |pos| {
			s.drag_start = pos;
			s.did_drag = false;
		},
		.mouse_left_release => |pos| {
			if (!s.did_drag) {
				// Clean click (no drag): zoom in at release position
				const view = toViewState(s);
				const new_view = viewport.zoomAt(view, ZOOM_FACTOR, pos.col, pos.row, s.term_width, s.term_height, ASPECT_RATIO);
				applyViewState(&s, new_view);
				s.needs_redraw = true;
			}
			s.drag_start = null;
			s.did_drag = false;
		},
		.mouse_drag => |pos| {
			// Live pan during drag: shift center by delta from last position
			s.did_drag = true;
			if (s.drag_start) |start| {
				const start_pt = viewport.screenToComplex(.{
					.col = start.col, .row = start.row,
					.center_re = s.center_re, .center_im = s.center_im,
					.zoom = s.zoom, .width = s.term_width, .height = s.term_height,
					.aspect_ratio = ASPECT_RATIO,
				});
				const end_pt = viewport.screenToComplex(.{
					.col = pos.col, .row = pos.row,
					.center_re = s.center_re, .center_im = s.center_im,
					.zoom = s.zoom, .width = s.term_width, .height = s.term_height,
					.aspect_ratio = ASPECT_RATIO,
				});
				s.center_re += start_pt.re - end_pt.re;
				s.center_im += start_pt.im - end_pt.im;
				s.drag_start = pos; // Update start to current for next delta
				s.needs_redraw = true;
			}
		},
		.mouse_right_press => {},
		.mouse_right_release => |pos| {
			// Right-click release: zoom out at release position
			const view = toViewState(s);
			const new_view = viewport.zoomAt(view, 1.0 / ZOOM_FACTOR, pos.col, pos.row, s.term_width, s.term_height, ASPECT_RATIO);
			applyViewState(&s, new_view);
			s.needs_redraw = true;
		},
		.scroll_up => |pos| {
			const view = toViewState(s);
			const new_view = viewport.zoomAt(view, ZOOM_FACTOR, pos.col, pos.row, s.term_width, s.term_height, ASPECT_RATIO);
			applyViewState(&s, new_view);
			s.needs_redraw = true;
		},
		.scroll_down => |pos| {
			const view = toViewState(s);
			const new_view = viewport.zoomAt(view, 1.0 / ZOOM_FACTOR, pos.col, pos.row, s.term_width, s.term_height, ASPECT_RATIO);
			applyViewState(&s, new_view);
			s.needs_redraw = true;
		},
		.arrow_up, .arrow_down, .arrow_left, .arrow_right => {
			const dir: viewport.Direction = switch (event) {
				.arrow_up => .up,
				.arrow_down => .down,
				.arrow_left => .left,
				.arrow_right => .right,
				else => unreachable,
			};
			const view = toViewState(s);
			const new_view = viewport.pan(view, dir, s.term_width, s.term_height, ASPECT_RATIO);
			applyViewState(&s, new_view);
			s.needs_redraw = true;
		},
		.key_bracket_open => {
			if (s.base_iter > 50) {
				s.base_iter -= 50;
				s.max_iter = viewport.adaptiveMaxIter(s.zoom, s.base_iter);
				s.needs_redraw = true;
			}
		},
		.key_bracket_close => {
			s.base_iter += 50;
			s.max_iter = viewport.adaptiveMaxIter(s.zoom, s.base_iter);
			s.needs_redraw = true;
		},
		.key_i => {
			s.show_info = !s.show_info;
			s.needs_redraw = true;
		},
		.key_g => {
			// Cycle glyph mode: density → blocks → (kitty if available) → density
			s.glyph_mode = switch (s.glyph_mode) {
				.density => .blocks,
				.blocks => if (s.kitty_available) .kitty else .density,
				.kitty => .density,
			};
			s.needs_redraw = true;
		},
		.resize => {
			s.needs_redraw = true;
		},
		.key_h, .key_question => {
			s.show_help = true;
			s.needs_redraw = true;
		},
		.key_escape => {},
		.unknown => {},
	}
	return s;
}

fn toViewState(s: AppState) viewport.ViewState {
	return .{
		.center_re = s.center_re,
		.center_im = s.center_im,
		.zoom = s.zoom,
		.base_iter = s.base_iter,
		.max_iter = s.max_iter,
	};
}

fn applyViewState(s: *AppState, v: viewport.ViewState) void {
	s.center_re = v.center_re;
	s.center_im = v.center_im;
	s.zoom = v.zoom;
	s.max_iter = v.max_iter;
}

// ── Tests ───────────────────────────────────────────────────────────

test "defaultState has sane defaults" {
	const s = defaultState();
	try std.testing.expect(s.running);
	try std.testing.expect(s.needs_redraw);
	try std.testing.expect(s.show_info);
	try std.testing.expectEqual(@as(f128, -0.5), s.center_re);
	try std.testing.expectEqual(@as(f128, 0.0), s.center_im);
	try std.testing.expectEqual(@as(f128, 1.0), s.zoom);
	try std.testing.expectEqual(@as(u32, 256), s.max_iter);
}

test "processEvent: q quits" {
	var s = defaultState();
	s = processEvent(s, .key_q);
	try std.testing.expect(!s.running);
}

test "processEvent: ctrl_c quits" {
	var s = defaultState();
	s = processEvent(s, .ctrl_c);
	try std.testing.expect(!s.running);
}

test "processEvent: i toggles info bar" {
	var s = defaultState();
	try std.testing.expect(s.show_info);
	s = processEvent(s, .key_i);
	try std.testing.expect(!s.show_info);
	s = processEvent(s, .key_i);
	try std.testing.expect(s.show_info);
}

test "processEvent: plus zooms in" {
	var s = defaultState();
	const old_zoom = s.zoom;
	s = processEvent(s, .key_plus);
	try std.testing.expect(s.zoom > old_zoom);
	try std.testing.expect(s.needs_redraw);
}

test "processEvent: minus zooms out" {
	var s = defaultState();
	// First zoom in so we have room to zoom out
	s = processEvent(s, .key_plus);
	const zoomed_in = s.zoom;
	s = processEvent(s, .key_minus);
	try std.testing.expect(s.zoom < zoomed_in);
	try std.testing.expect(s.needs_redraw);
}

test "processEvent: arrow keys pan" {
	var s = defaultState();
	const orig_re = s.center_re;
	s = processEvent(s, .arrow_right);
	try std.testing.expect(s.center_re > orig_re);
	try std.testing.expect(s.needs_redraw);
}

test "processEvent: bracket_close increases iterations" {
	var s = defaultState();
	const orig_iter = s.base_iter;
	s = processEvent(s, .key_bracket_close);
	try std.testing.expect(s.base_iter > orig_iter);
}

test "processEvent: bracket_open decreases iterations with floor" {
	var s = defaultState();
	s = processEvent(s, .key_bracket_open);
	try std.testing.expect(s.base_iter < 256);
	// Set base_iter to minimum and verify it doesn't go below
	s.base_iter = 50;
	s = processEvent(s, .key_bracket_open);
	try std.testing.expectEqual(@as(u32, 50), s.base_iter);
}

test "processEvent: unknown does nothing" {
	const s = defaultState();
	const s2 = processEvent(s, .unknown);
	try std.testing.expectEqual(s.center_re, s2.center_re);
	try std.testing.expectEqual(s.center_im, s2.center_im);
	try std.testing.expectEqual(s.zoom, s2.zoom);
	try std.testing.expect(s2.running);
}

test "processEvent: left click (press+release at same pos) zooms in" {
	var s = defaultState();
	const old_zoom = s.zoom;
	s = processEvent(s, .{ .mouse_left_press = .{ .col = 10, .row = 5 } });
	try std.testing.expect(s.drag_start != null);
	s = processEvent(s, .{ .mouse_left_release = .{ .col = 10, .row = 5 } });
	try std.testing.expect(s.zoom > old_zoom);
	try std.testing.expect(s.needs_redraw);
	try std.testing.expect(s.drag_start == null);
}

test "processEvent: left drag pans without zooming" {
	var s = defaultState();
	const old_zoom = s.zoom;
	const old_re = s.center_re;
	s = processEvent(s, .{ .mouse_left_press = .{ .col = 10, .row = 5 } });
	s = processEvent(s, .{ .mouse_drag = .{ .col = 20, .row = 5 } });
	s = processEvent(s, .{ .mouse_drag = .{ .col = 30, .row = 5 } });
	s = processEvent(s, .{ .mouse_left_release = .{ .col = 30, .row = 5 } });
	// Zoom should not change — drag cancels zoom
	try std.testing.expectEqual(old_zoom, s.zoom);
	// Center should have shifted from the drag
	try std.testing.expect(s.center_re != old_re);
	// did_drag should be cleared after release
	try std.testing.expect(!s.did_drag);
}

test "processEvent: resize triggers redraw" {
	var s = defaultState();
	s.needs_redraw = false;
	s = processEvent(s, .resize);
	try std.testing.expect(s.needs_redraw);
}

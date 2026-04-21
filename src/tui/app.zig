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

const ZOOM_FACTOR: f128 = 2.0;
const ASPECT_RATIO: f64 = 0.5;

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

	const stdout_file = std.fs.File.stdout();
	const stdin_file = std.fs.File.stdin();

	try terminal.enterRawMode();
	errdefer terminal.exitRawMode();

	var stdout_buf: [16384]u8 = undefined;
	var stdout_writer = stdout_file.writer(&stdout_buf);
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
				// Terminal size changed — cache is invalid.
				// stop() bumps generation and joins the coordinator to prevent
				// a data race with invalidateAll (cancel() alone would not).
				scheduler.stop();
				cache_stack.invalidateAll(allocator);
			} else |_| {}
		}

		if (state.needs_redraw) {
			try renderOneFrame(&state, &cache_stack, &scheduler, allocator, stdout);
		}

		const n = stdin_file.read(&read_buf) catch 0;
		if (n == 0) continue;

		const event = input.parseEvent(read_buf[0..n]);
		const new_state = processEvent(state, event);

		// If the viewport changed, the cache is stale. stop() joins the
		// coordinator before we invalidate levels, avoiding a use-after-free
		// race. The next render pass refills Level 0 and respawns via requestWork.
		if (viewportChanged(state, new_state)) {
			scheduler.stop();
			cache_stack.invalidateAll(allocator);
		}
		state = new_state;
	}

	try terminal.disableMouseTracking(stdout);
	try terminal.showCursor(stdout);
	try terminal.clearScreen(stdout);
	try stdout.flush();
	terminal.exitRawMode();
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
	const render_height: u16 = if (state.show_info and state.term_height > 1)
		state.term_height - 1
	else
		state.term_height;

	// Sub-pixel multiplier: 1 for density mode, 2 for blocks mode
	const sub_mul: u16 = switch (state.glyph_mode) {
		.density => 1,
		.blocks => 2,
	};
	const buf_width: u16 = state.term_width * sub_mul;
	const buf_height: u16 = render_height * sub_mul;
	const pixel_count = @as(usize, buf_width) * @as(usize, buf_height);

	const iter_buf = try allocator.alloc(f64, pixel_count);
	defer allocator.free(iter_buf);

	// Check cache Level 0 first
	var cache_hit = false;
	if (cache_stack.levels[0]) |level| {
		if (level.complete and level.width == buf_width and level.height == buf_height) {
			@memcpy(iter_buf, level.data[0..pixel_count]);
			cache_hit = true;
		}
	}

	if (!cache_hit) {
		scheduler.stop();
		cache_stack.invalidateAll(allocator);

		try cache_stack.initForViewport(
			allocator,
			state.center_re,
			state.center_im,
			state.zoom,
			buf_width,
			buf_height,
			state.max_iter,
			ASPECT_RATIO,
		);

		try mandelbrot.parallelComputeRegion(.{
			.center_re = state.center_re,
			.center_im = state.center_im,
			.zoom = state.zoom,
			.width = buf_width,
			.height = buf_height,
			.max_iter = state.max_iter,
			.aspect_ratio = ASPECT_RATIO,
		}, iter_buf, null);

		if (cache_stack.levels[0]) |*level| {
			@memcpy(level.data, iter_buf);
			level.complete = true;
		}
	}

	// Dispatch to the correct renderer based on glyph mode
	const render_state = renderer.RenderState{
		.center_re = state.center_re,
		.center_im = state.center_im,
		.zoom = state.zoom,
		.max_iter = state.max_iter,
		.show_info = state.show_info,
		.glyph_mode = state.glyph_mode,
	};

	const frame = switch (state.glyph_mode) {
		.density => try renderer.renderFrameFromBuffer(render_state, state.term_width, state.term_height, iter_buf, allocator),
		.blocks => try renderer.renderFrameFromBlocksBuffer(render_state, state.term_width, state.term_height, iter_buf, allocator),
	};
	defer allocator.free(frame);

	try stdout.writeAll(frame);
	try stdout.flush();
	state.needs_redraw = false;

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

	const stdout_file = std.fs.File.stdout();

	var stdout_buf: [16384]u8 = undefined;
	var stdout_writer = stdout_file.writer(&stdout_buf);
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
	var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
	const stderr = &stderr_writer.interface;

	// Frame timing stats
	var total_elapsed_ns: u64 = 0;
	var min_frame_ns: u64 = std.math.maxInt(u64);
	var max_frame_ns: u64 = 0;
	var overrun_count: u32 = 0;

	const overall_start = std.time.nanoTimestamp();

	var frame_idx: u32 = 0;
	while (frame_idx < config.num_frames) : (frame_idx += 1) {
		const frame_start = std.time.nanoTimestamp();

		const params = animation.frameAt(config, frame_idx);
		state.center_re = params.center_re;
		state.center_im = params.center_im;
		state.zoom = params.zoom;
		state.max_iter = params.max_iter;
		state.needs_redraw = true;

		try renderOneFrame(&state, &cache_stack, &scheduler, allocator, stdout);

		const elapsed_ns: i128 = std.time.nanoTimestamp() - frame_start;
		const elapsed_u64: u64 = if (elapsed_ns > 0) @intCast(elapsed_ns) else 0;
		total_elapsed_ns += elapsed_u64;
		if (elapsed_u64 < min_frame_ns) min_frame_ns = elapsed_u64;
		if (elapsed_u64 > max_frame_ns) max_frame_ns = elapsed_u64;

		const target_ns: i128 = @intCast(target_frame_ns);
		if (elapsed_ns < target_ns) {
			std.Thread.sleep(@intCast(target_ns - elapsed_ns));
		} else {
			overrun_count += 1;
		}
	}

	const overall_elapsed: i128 = std.time.nanoTimestamp() - overall_start;
	const overall_elapsed_sec: f64 = @as(f64, @floatFromInt(@as(u64, @intCast(overall_elapsed)))) / 1_000_000_000.0;
	const target_duration_sec: f64 = @as(f64, @floatFromInt(config.num_frames)) / @as(f64, @floatFromInt(config.fps));
	const mean_frame_ms: f64 = @as(f64, @floatFromInt(total_elapsed_ns)) / @as(f64, @floatFromInt(config.num_frames)) / 1_000_000.0;
	const min_frame_ms: f64 = @as(f64, @floatFromInt(min_frame_ns)) / 1_000_000.0;
	const max_frame_ms: f64 = @as(f64, @floatFromInt(max_frame_ns)) / 1_000_000.0;
	const target_frame_ms: f64 = @as(f64, @floatFromInt(target_frame_ns)) / 1_000_000.0;
	const overrun_pct: f64 = @as(f64, @floatFromInt(overrun_count)) / @as(f64, @floatFromInt(config.num_frames)) * 100.0;

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

	// Hold on final frame if requested (honored in both tty and non-tty modes)
	if (config.exit_after and config.hold_ms > 0) {
		std.Thread.sleep(config.hold_ms * std.time.ns_per_ms);
	}

	// Non-tty mode: always exit (no interactive mode possible without stdin)
	// tty mode: exit only if exit_after set, otherwise fall through to interactive
	if (!is_tty or config.exit_after) {
		if (is_tty) {
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
	const stdin_file = std.fs.File.stdin();

	while (state.running) {
		if (terminal.checkAndClearResizeFlag()) {
			if (terminal.getTermSizePosix()) |size| {
				state.term_width = size.cols;
				state.term_height = size.rows;
				state.needs_redraw = true;
				scheduler.stop();
				cache_stack.invalidateAll(allocator);
			} else |_| {}
		}

		if (state.needs_redraw) {
			try renderOneFrame(&state, &cache_stack, &scheduler, allocator, stdout);
		}

		const n = stdin_file.read(&read_buf) catch 0;
		if (n == 0) continue;

		const event = input.parseEvent(read_buf[0..n]);
		const new_state = processEvent(state, event);

		if (viewportChanged(state, new_state)) {
			scheduler.stop();
			cache_stack.invalidateAll(allocator);
		}
		state = new_state;
	}

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
			// Cycle glyph mode: density → blocks → density
			s.glyph_mode = switch (s.glyph_mode) {
				.density => .blocks,
				.blocks => .density,
			};
			s.needs_redraw = true;
		},
		.resize => {
			s.needs_redraw = true;
		},
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

// src/tui/app.zig
// Event loop and state machine. Orchestrates input, state, and rendering.
// Pure state transitions (processEvent) are separated from I/O (run) for testability.

const std = @import("std");
const terminal = @import("terminal");
const input = @import("input");
const renderer = @import("renderer");
const viewport = @import("viewport");

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
			} else |_| {}
		}

		if (state.needs_redraw) {
			const frame = try renderer.renderFrame(.{
				.center_re = state.center_re,
				.center_im = state.center_im,
				.zoom = state.zoom,
				.max_iter = state.max_iter,
				.show_info = state.show_info,
			}, state.term_width, state.term_height, allocator);
			defer allocator.free(frame);

			try stdout.writeAll(frame);
			try stdout.flush();
			state.needs_redraw = false;
		}

		const n = stdin_file.read(&read_buf) catch 0;
		if (n == 0) continue;

		const event = input.parseEvent(read_buf[0..n]);
		state = processEvent(state, event);
	}

	try terminal.disableMouseTracking(stdout);
	try terminal.showCursor(stdout);
	try terminal.clearScreen(stdout);
	try stdout.flush();
	terminal.exitRawMode();
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
		.mouse_left => |pos| {
			const view = toViewState(s);
			const new_view = viewport.zoomAt(view, ZOOM_FACTOR, pos.col, pos.row, s.term_width, s.term_height, ASPECT_RATIO);
			applyViewState(&s, new_view);
			s.needs_redraw = true;
		},
		.mouse_right => |pos| {
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

test "processEvent: mouse_left zooms in at position" {
	var s = defaultState();
	const old_zoom = s.zoom;
	s = processEvent(s, .{ .mouse_left = .{ .col = 10, .row = 5 } });
	try std.testing.expect(s.zoom > old_zoom);
	try std.testing.expect(s.needs_redraw);
}

test "processEvent: resize triggers redraw" {
	var s = defaultState();
	s.needs_redraw = false;
	s = processEvent(s, .resize);
	try std.testing.expect(s.needs_redraw);
}

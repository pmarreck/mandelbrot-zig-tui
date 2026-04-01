const std = @import("std");
const app = @import("app");
const terminal = @import("terminal");
const viewport = @import("viewport");
const renderer = @import("renderer");

const version = "0.1.0";

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	var stderr_buf: [4096]u8 = undefined;
	var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
	const stderr = &stderr_writer.interface;

	if (comptime @import("builtin").mode == .Debug) {
		try stderr.print("\x1b[33mDEBUG BUILD\x1b[0m\n", .{});
		try stderr.flush();
	}

	const args = try std.process.argsAlloc(allocator);
	defer std.process.argsFree(allocator, args);

	var single_frame = false;
	for (args[1..]) |arg| {
		if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
			var stdout_buf: [4096]u8 = undefined;
			var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
			const stdout = &stdout_writer.interface;
			try stdout.print(
				\\mandelbrot -- interactive TUI Mandelbrot set explorer
				\\
				\\Usage: mandelbrot [OPTIONS]
				\\
				\\Options:
				\\  -h, --help       Show this help
				\\  --about          Show version and platform info
				\\  --single-frame   Render one frame to stdout and exit
				\\  --no-color       Disable ANSI colors
				\\  --no-ansi        Disable all ANSI escapes
				\\  --simple         Plain ASCII mode (no color, ANSI, or emoji)
				\\
				\\Environment variables (for view injection / bookmarking):
				\\  MANDELBROT_CENTER_RE   Center real coordinate
				\\  MANDELBROT_CENTER_IM   Center imaginary coordinate
				\\  MANDELBROT_ZOOM        Zoom level
				\\  MANDELBROT_MAX_ITER    Max iteration count
				\\  MANDELBROT_COLS        Override terminal width
				\\  MANDELBROT_ROWS        Override terminal height
				\\
				\\Controls:
				\\  Left-click     Zoom in 2x at click point
				\\  Right-click    Zoom out 2x at click point
				\\  +/=            Zoom in 2x at center
				\\  -              Zoom out 2x at center
				\\  Arrow keys     Pan
				\\  [/]            Decrease/increase max iterations
				\\  i              Toggle info bar
				\\  q / Ctrl-C     Quit
				\\
			, .{});
			try stdout.flush();
			return;
		}
		if (std.mem.eql(u8, arg, "--about")) {
			var stdout_buf: [4096]u8 = undefined;
			var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
			const stdout = &stdout_writer.interface;
			try stdout.print("mandelbrot v{s} ({s}-{s})\n", .{
				version,
				@tagName(@import("builtin").cpu.arch),
				@tagName(@import("builtin").os.tag),
			});
			try stdout.flush();
			return;
		}
		if (std.mem.eql(u8, arg, "--single-frame")) {
			single_frame = true;
		}
	}

	var state = app.defaultState();

	if (parseF128Env("MANDELBROT_CENTER_RE")) |v| state.center_re = v;
	if (parseF128Env("MANDELBROT_CENTER_IM")) |v| state.center_im = v;
	if (parseF128Env("MANDELBROT_ZOOM")) |v| state.zoom = v;
	if (parseU32Env("MANDELBROT_MAX_ITER")) |v| {
		state.max_iter = v;
		state.base_iter = v;
	}

	const cols_override = parseU16Env("MANDELBROT_COLS");
	const rows_override = parseU16Env("MANDELBROT_ROWS");
	if (cols_override) |v| state.term_width = v;
	if (rows_override) |v| state.term_height = v;

	if (cols_override == null and rows_override == null) {
		if (terminal.getTermSizePosix()) |size| {
			state.term_width = size.cols;
			state.term_height = size.rows;
		} else |_| {}
	}

	if (single_frame) {
		const frame = try renderer.renderFrame(.{
			.center_re = state.center_re,
			.center_im = state.center_im,
			.zoom = state.zoom,
			.max_iter = state.max_iter,
			.show_info = state.show_info,
		}, state.term_width, state.term_height, allocator);
		defer allocator.free(frame);

		var stdout_buf: [4096]u8 = undefined;
		var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
		const stdout = &stdout_writer.interface;
		try stdout.writeAll(frame);
		try stdout.print("\n", .{});
		try stdout.flush();
		return;
	}

	try app.run(state, allocator);
}

fn parseF128Env(name: []const u8) ?f128 {
	const val = std.posix.getenv(name) orelse return null;
	const f = std.fmt.parseFloat(f64, val) catch return null;
	return @as(f128, f);
}

fn parseU32Env(name: []const u8) ?u32 {
	const val = std.posix.getenv(name) orelse return null;
	return std.fmt.parseInt(u32, val, 10) catch null;
}

fn parseU16Env(name: []const u8) ?u16 {
	const val = std.posix.getenv(name) orelse return null;
	return std.fmt.parseInt(u16, val, 10) catch null;
}

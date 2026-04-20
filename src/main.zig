const std = @import("std");
const app = @import("app");
const terminal = @import("terminal");
const viewport = @import("viewport");
const renderer = @import("renderer");
const mandelbrot = @import("mandelbrot");
const coloring = @import("coloring");

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
	var bench_zoom_n: ?u32 = null;
	var bench_quiet = false;
	var cli_glyph_mode: ?coloring.GlyphMode = null;

	var i: usize = 1;
	while (i < args.len) : (i += 1) {
		const arg = args[i];
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
				\\  -h, --help                 Show this help
				\\  --about                    Show version and platform info
				\\  --single-frame             Render one frame to stdout and exit
				\\  --bench-zoom-sequence N    Render N zoom-in frames for perf testing, print timing, exit
				\\  --bench-quiet              With --bench-zoom-sequence: suppress per-frame output
				\\  --glyph=MODE               Initial glyph mode: density (default) or blocks
				\\  --no-color                 Disable ANSI colors
				\\  --no-ansi                  Disable all ANSI escapes
				\\  --simple                   Plain ASCII mode (no color, ANSI, or emoji)
				\\
				\\Environment variables (for view injection / bookmarking):
				\\  MANDELBROT_CENTER_RE   Center real coordinate
				\\  MANDELBROT_CENTER_IM   Center imaginary coordinate
				\\  MANDELBROT_ZOOM        Zoom level
				\\  MANDELBROT_MAX_ITER    Max iteration count
				\\  MANDELBROT_COLS        Override terminal width
				\\  MANDELBROT_ROWS        Override terminal height
				\\  MANDELBROT_SUBBLOCK    Set to true/1/yes/on to start in blocks mode
				\\
				\\Controls:
				\\  Left-click     Zoom in 2x at click point
				\\  Right-click    Zoom out 2x at click point
				\\  +/=            Zoom in 2x at center
				\\  -              Zoom out 2x at center
				\\  Arrow keys     Pan
				\\  [/]            Decrease/increase max iterations
				\\  i              Toggle info bar
				\\  g              Cycle glyph mode (density, blocks)
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
			continue;
		}
		if (std.mem.eql(u8, arg, "--bench-zoom-sequence")) {
			if (i + 1 >= args.len) {
				try stderr.writeAll("--bench-zoom-sequence requires N argument\n");
				try stderr.flush();
				return error.BadCliArg;
			}
			bench_zoom_n = std.fmt.parseInt(u32, args[i + 1], 10) catch {
				try stderr.writeAll("--bench-zoom-sequence N must be a positive integer\n");
				try stderr.flush();
				return error.BadCliArg;
			};
			i += 1; // Skip the N value
			continue;
		}
		if (std.mem.eql(u8, arg, "--bench-quiet")) {
			bench_quiet = true;
			continue;
		}
		if (std.mem.startsWith(u8, arg, "--glyph=")) {
			const mode_str = arg["--glyph=".len..];
			if (std.mem.eql(u8, mode_str, "density")) {
				cli_glyph_mode = .density;
			} else if (std.mem.eql(u8, mode_str, "blocks")) {
				cli_glyph_mode = .blocks;
			} else {
				try stderr.writeAll("--glyph= must be 'density' or 'blocks'\n");
				try stderr.flush();
				return error.BadCliArg;
			}
			continue;
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

	// Glyph mode precedence: default (density) → env var → CLI flag
	if (parseBoolEnv("MANDELBROT_SUBBLOCK")) {
		state.glyph_mode = .blocks;
	}
	if (cli_glyph_mode) |m| {
		state.glyph_mode = m;
	}

	if (bench_zoom_n) |n| {
		try runBenchZoomSequence(allocator, state, n, bench_quiet);
		return;
	}

	if (single_frame) {
		const render_state = renderer.RenderState{
			.center_re = state.center_re,
			.center_im = state.center_im,
			.zoom = state.zoom,
			.max_iter = state.max_iter,
			.show_info = state.show_info,
			.glyph_mode = state.glyph_mode,
		};
		const frame = switch (state.glyph_mode) {
			.density => try renderer.renderFrame(render_state, state.term_width, state.term_height, allocator),
			.blocks => blk: {
				const render_height: u16 = if (state.show_info and state.term_height > 1)
					state.term_height - 1
				else
					state.term_height;
				const buf_width: u16 = state.term_width * 2;
				const buf_height: u16 = render_height * 2;
				const pixel_count = @as(usize, buf_width) * @as(usize, buf_height);
				const iter_buf = try allocator.alloc(f64, pixel_count);
				defer allocator.free(iter_buf);
				try mandelbrot.parallelComputeRegion(.{
					.center_re = state.center_re,
					.center_im = state.center_im,
					.zoom = state.zoom,
					.width = buf_width,
					.height = buf_height,
					.max_iter = state.max_iter,
					.aspect_ratio = 0.5,
				}, iter_buf, null);
				break :blk try renderer.renderFrameFromBlocksBuffer(render_state, state.term_width, state.term_height, iter_buf, allocator);
			},
		};
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

fn parseBoolEnv(name: []const u8) bool {
	const val = std.posix.getenv(name) orelse return false;
	// Case-insensitive compare against true/1/yes/on
	var buf: [16]u8 = undefined;
	if (val.len >= buf.len) return false;
	for (val, 0..) |c, i| buf[i] = std.ascii.toLower(c);
	const lower = buf[0..val.len];
	return std.mem.eql(u8, lower, "true") or
		std.mem.eql(u8, lower, "1") or
		std.mem.eql(u8, lower, "yes") or
		std.mem.eql(u8, lower, "on");
}

fn runBenchZoomSequence(
	allocator: std.mem.Allocator,
	initial_state: app.AppState,
	n: u32,
	quiet: bool,
) !void {
	var stderr_buf: [4096]u8 = undefined;
	var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
	const stderr = &stderr_writer.interface;

	// Canonical bench target: seahorse valley at 120x40. Env vars can override.
	var state = initial_state;
	if (std.posix.getenv("MANDELBROT_CENTER_RE") == null) state.center_re = -0.7435;
	if (std.posix.getenv("MANDELBROT_CENTER_IM") == null) state.center_im = 0.1314;
	if (std.posix.getenv("MANDELBROT_ZOOM") == null) state.zoom = 1.0;
	if (std.posix.getenv("MANDELBROT_COLS") == null) state.term_width = 120;
	if (std.posix.getenv("MANDELBROT_ROWS") == null) state.term_height = 40;

	try stderr.print("=== Zoom Sequence Benchmark ({d}x{d}, base_iter={d}, N={d}) ===\n", .{
		state.term_width, state.term_height, state.base_iter, n,
	});
	try stderr.flush();

	var total_compute_ns: u64 = 0;
	var total_render_ns: u64 = 0;
	var timer = try std.time.Timer.start();

	var frame: u32 = 0;
	while (frame < n) : (frame += 1) {
		const render_height: u16 = if (state.show_info and state.term_height > 1)
			state.term_height - 1
		else
			state.term_height;
		const pixel_count = @as(usize, state.term_width) * @as(usize, render_height);

		const iter_buf = try allocator.alloc(f64, pixel_count);
		defer allocator.free(iter_buf);

		timer.reset();
		try mandelbrot.parallelComputeRegion(.{
			.center_re = state.center_re,
			.center_im = state.center_im,
			.zoom = state.zoom,
			.width = state.term_width,
			.height = render_height,
			.max_iter = state.max_iter,
			.aspect_ratio = 0.5,
		}, iter_buf, null);
		const compute_ns = timer.read();
		total_compute_ns += compute_ns;

		timer.reset();
		const frame_bytes = try renderer.renderFrameFromBuffer(.{
			.center_re = state.center_re,
			.center_im = state.center_im,
			.zoom = state.zoom,
			.max_iter = state.max_iter,
			.show_info = state.show_info,
		}, state.term_width, state.term_height, iter_buf, allocator);
		defer allocator.free(frame_bytes);
		const render_ns = timer.read();
		total_render_ns += render_ns;

		if (!quiet) {
			const compute_ms = @as(f64, @floatFromInt(compute_ns)) / 1_000_000.0;
			const render_ms = @as(f64, @floatFromInt(render_ns)) / 1_000_000.0;
			const total_ms = compute_ms + render_ms;
			const zoom_f64: f64 = @floatCast(state.zoom);
			try stderr.print("  Frame {d} (zoom={e:.1}): compute={d:.2}ms  render={d:.2}ms  total={d:.2}ms\n", .{
				frame + 1, zoom_f64, compute_ms, render_ms, total_ms,
			});
		}

		// Zoom in 2x at center for next frame
		state.zoom *= 2.0;
		state.max_iter = viewport.adaptiveMaxIter(state.zoom, state.base_iter);
	}

	const total_ns = total_compute_ns + total_render_ns;
	const total_ms = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0;
	const avg_ms = total_ms / @as(f64, @floatFromInt(n));
	try stderr.print("  Total: {d:.2}ms  Avg/frame: {d:.2}ms  (compute: {d:.2}ms, render: {d:.2}ms)\n", .{
		total_ms,
		avg_ms,
		@as(f64, @floatFromInt(total_compute_ns)) / 1_000_000.0,
		@as(f64, @floatFromInt(total_render_ns)) / 1_000_000.0,
	});
	try stderr.flush();
}

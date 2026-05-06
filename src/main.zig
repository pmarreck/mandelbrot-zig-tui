const std = @import("std");
const app = @import("app");
const terminal = @import("terminal");
const viewport = @import("viewport");
const renderer = @import("renderer");
const mandelbrot = @import("mandelbrot");
const coloring = @import("coloring");
const animation = @import("animation");

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
	var force_kitty = false;
	var raw_anim = animation.RawAnimationFlags{};
	var cli_center_re: ?f128 = null;
	var cli_center_im: ?f128 = null;
	var cli_zoom: ?f128 = null;
	var cli_max_iter: ?u32 = null;
	var cli_cols: ?u16 = null;
	var cli_rows: ?u16 = null;

	// Helper: if arg starts with prefix ("--flag="), return the value part.
	// Otherwise if arg == prefix without =, consume the next arg as the value.
	// Returns null if the flag doesn't match.
	const ArgHelper = struct {
		fn match(arg_val: []const u8, flag_name: []const u8, args_slice: [][:0]u8, idx: *usize) ?[]const u8 {
			// Try --flag=VALUE
			var eq_prefix_buf: [64]u8 = undefined;
			const eq_prefix = std.fmt.bufPrint(&eq_prefix_buf, "{s}=", .{flag_name}) catch return null;
			if (std.mem.startsWith(u8, arg_val, eq_prefix)) {
				return arg_val[eq_prefix.len..];
			}
			// Try --flag VALUE
			if (std.mem.eql(u8, arg_val, flag_name)) {
				if (idx.* + 1 >= args_slice.len) return null;
				idx.* += 1;
				return args_slice[idx.*];
			}
			return null;
		}
	};

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
				\\  --glyph=MODE               Initial glyph mode: density (default), blocks, or kitty
				\\  --blocks                   Shortcut for --glyph=blocks (same as MANDELBROT_SUBBLOCK=1)
				\\  --kitty                    Shortcut for --glyph=kitty (true per-pixel via kitty graphics)
				\\  --force-kitty              Treat the terminal as kitty-graphics capable even if
				\\                             auto-detection fails (e.g. SSH sessions where env vars are stripped)
				\\  --center-re F              Override MANDELBROT_CENTER_RE
				\\  --center-im F              Override MANDELBROT_CENTER_IM
				\\  --zoom F                   Override MANDELBROT_ZOOM
				\\  --max-iter N               Override MANDELBROT_MAX_ITER
				\\  --cols N                   Override MANDELBROT_COLS
				\\  --rows N                   Override MANDELBROT_ROWS
				\\
				\\Animation (all require --animate):
				\\  --animate                  Enable animation mode
				\\  --zoom-from F              Starting zoom (default 1.0)
				\\  --zoom-to F                Ending zoom (required; must differ from from)
				\\  --duration SEC             Total animation duration in seconds (required)
				\\  --fps N                    Frames per second (default 30)
				\\  --exit-after               Exit when animation completes (default: drop to interactive)
				\\  --hold-ms N                With --exit-after: pause N ms on final frame
				\\  --start-center-re F        Override start center real coord
				\\  --start-center-im F        Override start center imag coord
				\\  --end-center-re F          Override end center real coord
				\\  --end-center-im F          Override end center imag coord
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
				\\  g              Cycle glyph mode (density, blocks, kitty)
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
		if (std.mem.eql(u8, arg, "--blocks")) {
			cli_glyph_mode = .blocks;
			continue;
		}
		if (std.mem.eql(u8, arg, "--kitty")) {
			cli_glyph_mode = .kitty;
			continue;
		}
		if (std.mem.eql(u8, arg, "--force-kitty")) {
			force_kitty = true;
			continue;
		}
		if (std.mem.startsWith(u8, arg, "--glyph=")) {
			const mode_str = arg["--glyph=".len..];
			if (std.mem.eql(u8, mode_str, "density")) {
				cli_glyph_mode = .density;
			} else if (std.mem.eql(u8, mode_str, "blocks")) {
				cli_glyph_mode = .blocks;
			} else if (std.mem.eql(u8, mode_str, "kitty")) {
				cli_glyph_mode = .kitty;
			} else {
				try stderr.writeAll("--glyph= must be 'density', 'blocks', or 'kitty'\n");
				try stderr.flush();
				return error.BadCliArg;
			}
			continue;
		}
		// Animation boolean flags
		if (std.mem.eql(u8, arg, "--animate")) {
			raw_anim.animate = true;
			continue;
		}
		if (std.mem.eql(u8, arg, "--exit-after")) {
			raw_anim.exit_after = true;
			continue;
		}
		// Animation value flags
		if (ArgHelper.match(arg, "--zoom-from", args, &i)) |v| {
			raw_anim.zoom_from = parseFlagF128(v) orelse {
				try stderr.writeAll("--zoom-from must be a number\n");
				try stderr.flush();
				return error.BadCliArg;
			};
			continue;
		}
		if (ArgHelper.match(arg, "--zoom-to", args, &i)) |v| {
			raw_anim.zoom_to = parseFlagF128(v) orelse {
				try stderr.writeAll("--zoom-to must be a number\n");
				try stderr.flush();
				return error.BadCliArg;
			};
			continue;
		}
		if (ArgHelper.match(arg, "--duration", args, &i)) |v| {
			raw_anim.duration_sec = parseFlagF64(v) orelse {
				try stderr.writeAll("--duration must be a number in seconds\n");
				try stderr.flush();
				return error.BadCliArg;
			};
			continue;
		}
		if (ArgHelper.match(arg, "--fps", args, &i)) |v| {
			raw_anim.fps = parseFlagU32(v) orelse {
				try stderr.writeAll("--fps must be a positive integer\n");
				try stderr.flush();
				return error.BadCliArg;
			};
			continue;
		}
		if (ArgHelper.match(arg, "--hold-ms", args, &i)) |v| {
			raw_anim.hold_ms = parseFlagU64(v) orelse {
				try stderr.writeAll("--hold-ms must be a non-negative integer\n");
				try stderr.flush();
				return error.BadCliArg;
			};
			continue;
		}
		if (ArgHelper.match(arg, "--start-center-re", args, &i)) |v| {
			raw_anim.start_center_re = parseFlagF128(v);
			continue;
		}
		if (ArgHelper.match(arg, "--start-center-im", args, &i)) |v| {
			raw_anim.start_center_im = parseFlagF128(v);
			continue;
		}
		if (ArgHelper.match(arg, "--end-center-re", args, &i)) |v| {
			raw_anim.end_center_re = parseFlagF128(v);
			continue;
		}
		if (ArgHelper.match(arg, "--end-center-im", args, &i)) |v| {
			raw_anim.end_center_im = parseFlagF128(v);
			continue;
		}
		// General-purpose viewport overrides
		if (ArgHelper.match(arg, "--center-re", args, &i)) |v| {
			cli_center_re = parseFlagF128(v);
			continue;
		}
		if (ArgHelper.match(arg, "--center-im", args, &i)) |v| {
			cli_center_im = parseFlagF128(v);
			continue;
		}
		if (ArgHelper.match(arg, "--zoom", args, &i)) |v| {
			cli_zoom = parseFlagF128(v);
			continue;
		}
		if (ArgHelper.match(arg, "--max-iter", args, &i)) |v| {
			cli_max_iter = parseFlagU32(v);
			continue;
		}
		if (ArgHelper.match(arg, "--cols", args, &i)) |v| {
			cli_cols = parseFlagU16(v);
			continue;
		}
		if (ArgHelper.match(arg, "--rows", args, &i)) |v| {
			cli_rows = parseFlagU16(v);
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

	// Cell pixel size (only meaningful for kitty mode, but cheap to query
	// always). Falls back to a reasonable default if the terminal does not
	// populate xpixel/ypixel via TIOCGWINSZ.
	const cell_px = terminal.getCellPixelSizePosix();
	state.cell_px_w = cell_px.width;
	state.cell_px_h = cell_px.height;

	// Resolve kitty graphics availability: detect from env, with --force-kitty
	// as the override for SSH sessions / unknown emulators. If the user asked
	// for kitty mode (--kitty / --glyph=kitty) without it being available,
	// bail with a clear hint rather than spewing escape sequences.
	state.kitty_available = force_kitty or terminal.detectKittyGraphicsSupport();
	if (cli_glyph_mode == .kitty and !state.kitty_available) {
		try stderr.writeAll(
			\\kitty graphics protocol not detected in this terminal.
			\\If your terminal supports kitty graphics (kitty, Ghostty, WezTerm,
			\\recent Konsole) and detection failed (e.g. via SSH), pass --force-kitty.
			\\
		);
		try stderr.flush();
		return error.BadCliArg;
	}

	// Glyph mode precedence: default (density) → env var → CLI flag
	if (parseBoolEnv("MANDELBROT_SUBBLOCK")) {
		state.glyph_mode = .blocks;
	}
	if (cli_glyph_mode) |m| {
		state.glyph_mode = m;
	}

	// CLI flags override env vars
	if (cli_center_re) |v| state.center_re = v;
	if (cli_center_im) |v| state.center_im = v;
	if (cli_zoom) |v| state.zoom = v;
	if (cli_max_iter) |v| {
		state.max_iter = v;
		state.base_iter = v;
	}
	if (cli_cols) |v| state.term_width = v;
	if (cli_rows) |v| state.term_height = v;

	// Populate animation's focal coords + base_iter from the resolved state
	raw_anim.focal_re = state.center_re;
	raw_anim.focal_im = state.center_im;
	raw_anim.base_iter = state.base_iter;

	// If --animate specified, validate and run animation mode
	if (raw_anim.animate) {
		const config = animation.validate(raw_anim) catch |err| {
			const msg = switch (err) {
				error.MissingDuration => "animation requires --duration SEC\n",
				error.ZoomFromEqualsTo => "--zoom-from and --zoom-to must differ\n",
				error.HoldWithoutExit => "--hold-ms requires --exit-after\n",
				error.BadFps => "--fps must be a positive integer\n",
				error.BadDuration => "--duration must be positive\n",
				error.AnimationFlagsWithoutAnimate => "internal error: animate=true but validation says otherwise\n",
			};
			try stderr.writeAll(msg);
			try stderr.flush();
			std.process.exit(2);
		};
		try app.runAnimation(config, state, allocator);
		return;
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
			.kitty => blk: {
				const render_height: u16 = if (state.show_info and state.term_height > 1)
					state.term_height - 1
				else
					state.term_height;
				const buf_width: u16 = state.term_width * state.cell_px_w;
				const buf_height: u16 = render_height * state.cell_px_h;
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
					.aspect_ratio = 1.0,
				}, iter_buf, null);
				break :blk try renderer.renderFrameKitty(render_state, state.term_width, state.term_height, state.cell_px_w, state.cell_px_h, iter_buf, allocator);
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

/// Parse an f128 value from a CLI flag string. Parses as f64 then widens to f128
/// since Zig 0.15 parseFloat doesn't support f128 directly.
fn parseFlagF128(val: []const u8) ?f128 {
	const f = std.fmt.parseFloat(f64, val) catch return null;
	return @as(f128, f);
}

fn parseFlagF64(val: []const u8) ?f64 {
	return std.fmt.parseFloat(f64, val) catch null;
}

fn parseFlagU32(val: []const u8) ?u32 {
	return std.fmt.parseInt(u32, val, 10) catch null;
}

fn parseFlagU64(val: []const u8) ?u64 {
	return std.fmt.parseInt(u64, val, 10) catch null;
}

fn parseFlagU16(val: []const u8) ?u16 {
	return std.fmt.parseInt(u16, val, 10) catch null;
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

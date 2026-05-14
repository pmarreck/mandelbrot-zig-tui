// src/tui/terminal.zig
// Terminal control module: raw mode, mouse tracking, SIGWINCH, cursor.
// This is the ONLY file in the project that performs terminal I/O.

const std = @import("std");
const posix = std.posix;
const runtime = @import("runtime");
/// Saved original termios for restoration on exit.
var original_termios: ?posix.termios = null;

/// Atomic flag set by SIGWINCH handler, polled by the event loop.
var resize_flag = std.atomic.Value(bool).init(false);

// ── Raw mode ────────────────────────────────────────────────────────

/// Save the current termios and switch stdin to raw mode.
/// Disables echo, canonical processing, signal generation, and extended
/// input processing. Sets VMIN=0, VTIME=1 (100 ms read timeout).
pub fn enterRawMode() !void {
	const fd = posix.STDIN_FILENO;
	var raw = try posix.tcgetattr(fd);
	original_termios = raw;

	// Input flags: disable CR→NL, disable XON/XOFF flow control,
	// disable stripping high bit, disable break-signal, disable parity check.
	raw.iflag.ICRNL = false;
	raw.iflag.IXON = false;
	raw.iflag.BRKINT = false;
	raw.iflag.INPCK = false;
	raw.iflag.ISTRIP = false;

	// Output flags: disable post-processing.
	raw.oflag.OPOST = false;

	// Control flags: set 8-bit characters.
	raw.cflag.CSIZE = .CS8;

	// Local flags: disable echo, canonical mode, signals, extended input.
	raw.lflag.ECHO = false;
	raw.lflag.ICANON = false;
	raw.lflag.ISIG = false;
	raw.lflag.IEXTEN = false;

	// Read behaviour: return after 0 bytes available, with 100 ms timeout.
	raw.cc[@intFromEnum(posix.V.MIN)] = 0;
	raw.cc[@intFromEnum(posix.V.TIME)] = 1;

	try posix.tcsetattr(fd, .FLUSH, raw);
}

/// Restore the original termios that was saved by `enterRawMode`.
pub fn exitRawMode() void {
	if (original_termios) |orig| {
		posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, orig) catch {};
		original_termios = null;
	}
}

// ── Mouse tracking ──────────────────────────────────────────────────

/// Enable button-event + SGR mouse tracking.
/// 1002 = report press/release/motion-while-held. 1006 = SGR format (coords > 223).
pub fn enableMouseTracking(writer: anytype) !void {
	try writer.writeAll("\x1b[?1002h\x1b[?1006h");
}

/// Disable SGR + button-event mouse tracking (reverse order of enable).
pub fn disableMouseTracking(writer: anytype) !void {
	try writer.writeAll("\x1b[?1006l\x1b[?1002l");
}

// ── Cursor ──────────────────────────────────────────────────────────

pub fn hideCursor(writer: anytype) !void {
	try writer.writeAll("\x1b[?25l");
}

pub fn showCursor(writer: anytype) !void {
	try writer.writeAll("\x1b[?25h");
}

// ── Screen ──────────────────────────────────────────────────────────

pub fn clearScreen(writer: anytype) !void {
	try writer.writeAll("\x1b[2J\x1b[H");
}

// ── Kitty graphics ──────────────────────────────────────────────────

/// Detect kitty-graphics-protocol support. Order:
///   1. KITTY_WINDOW_ID — set by kitty itself, definitive.
///   2. Active probe (preferred) — sends a tiny "a=q" query and listens for
///      the OK response. Authoritative for any terminal that implements the
///      spec, regardless of what it calls itself in TERM/TERM_PROGRAM. Only
///      attempted when stdin is a TTY (we need to read the response).
///   3. Env-var heuristic fallback — for non-TTY stdin (piped input) or
///      terminals that swallow the probe but report themselves through
///      TERM_PROGRAM. Conservative; intentionally a last resort.
/// --force-kitty in main.zig bypasses all of this when the user knows better.
pub fn detectKittyGraphicsSupport() bool {
	if (std.posix.getenv("KITTY_WINDOW_ID") != null) return true;
	if (probeKittyGraphicsSupport()) return true;
	return detectKittyGraphicsByEnv();
}

/// Last-resort name-based detection for terminals known to implement kitty
/// graphics. Used only when the active probe cannot run (e.g. stdin is not
/// a TTY, such as `cmd | mandelbrot`). Don't rely on this if you can probe.
fn detectKittyGraphicsByEnv() bool {
	if (std.posix.getenv("TERM_PROGRAM")) |tp| {
		if (std.mem.eql(u8, tp, "ghostty")) return true;
		if (std.mem.eql(u8, tp, "WezTerm")) return true;
		if (std.mem.eql(u8, tp, "kitty")) return true;
	}
	if (std.posix.getenv("TERM")) |term| {
		if (std.mem.eql(u8, term, "xterm-kitty")) return true;
		if (std.mem.eql(u8, term, "xterm-ghostty")) return true;
	}
	return false;
}

/// Active probe via the kitty graphics protocol's `a=q` query operation.
/// Sends a 1×1 raw-RGB query frame and polls stdin for ~200 ms for the
/// `\x1b_Gi=31;OK\x1b\\` response. Terminals that don't implement kitty
/// graphics ignore the APC sequence silently, so we time out and return false.
///
/// Briefly puts stdin in raw mode (saving + restoring original termios)
/// because the response would otherwise be processed as keystrokes by the
/// shell-managed terminal mode.
pub fn probeKittyGraphicsSupport() bool {
	if (!stdinIsTty()) return false;

	const stdin_fd = posix.STDIN_FILENO;
	const stdout_fd = posix.STDOUT_FILENO;

	const orig = posix.tcgetattr(stdin_fd) catch return false;
	var raw = orig;
	raw.iflag.ICRNL = false;
	raw.iflag.IXON = false;
	raw.lflag.ECHO = false;
	raw.lflag.ICANON = false;
	raw.cc[@intFromEnum(posix.V.MIN)] = 0;
	raw.cc[@intFromEnum(posix.V.TIME)] = 0;
	posix.tcsetattr(stdin_fd, .FLUSH, raw) catch return false;
	defer posix.tcsetattr(stdin_fd, .FLUSH, orig) catch {};

	// 1×1 RGB query. AAAA decodes to 3 zero bytes (one black pixel).
	// i=31 is an arbitrary id we'll look for in the response so we don't
	// confuse it with replies to other queries that may be in flight.
	const query = "\x1b_Gi=31,a=q,t=d,f=24,s=1,v=1;AAAA\x1b\\";
	_ = posix.write(stdout_fd, query) catch return false;

	var buf: [256]u8 = undefined;
	var total: usize = 0;
	var pfd = [_]posix.pollfd{.{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 }};
	var remaining_ms: i32 = 200;
	while (remaining_ms > 0 and total < buf.len) {
		const slice_ms: i32 = @min(remaining_ms, 50);
		const ready = posix.poll(&pfd, slice_ms) catch break;
		remaining_ms -= slice_ms;
		if (ready == 0) continue;
		if (pfd[0].revents & posix.POLL.IN != 0) {
			const n = posix.read(stdin_fd, buf[total..]) catch break;
			if (n == 0) break;
			total += n;
			// Response is bracketed by ESC \ (ST). When we see it, stop.
			if (total >= 2 and buf[total - 2] == 0x1b and buf[total - 1] == '\\') break;
		}
	}

	return std.mem.indexOf(u8, buf[0..total], "i=31;OK") != null;
}

/// Delete a kitty-graphics-protocol image from the terminal's image cache by ID.
/// Sent as an APC sequence; terminals that do not implement kitty graphics
/// silently discard unknown APC commands, so this is safe to send unconditionally
/// during cleanup. q=2 suppresses any response.
pub fn deleteKittyImageById(writer: anytype, id: u32) !void {
	var buf: [64]u8 = undefined;
	const seq = std.fmt.bufPrint(&buf, "\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{id}) catch return;
	try writer.writeAll(seq);
}

/// Place an EXISTING kitty-graphics-protocol image (already in the terminal's
/// image cache from a prior a=T transmission) at the current cursor position
/// using its ID. Used after clearScreen to restore the image — `\x1b[2J`
/// erases image placements on some terminals (e.g. ghostty) while preserving
/// the underlying image data. a=p re-creates the placement without
/// retransmitting the (multi-megabyte) base64 RGB payload. q=2 suppresses
/// any response.
pub fn placeKittyImageById(writer: anytype, id: u32) !void {
	var buf: [64]u8 = undefined;
	const seq = std.fmt.bufPrint(&buf, "\x1b_Ga=p,i={d},q=2\x1b\\", .{id}) catch return;
	try writer.writeAll(seq);
}

// ── SIGWINCH ────────────────────────────────────────────────────────

/// Install a SIGWINCH handler that sets the atomic resize flag.
/// The event loop should poll `checkAndClearResizeFlag()` each iteration.
pub fn setupSigwinch() void {
	const act = posix.Sigaction{
		.handler = .{ .handler = handleSigwinch },
		.mask = std.mem.zeroes(posix.sigset_t),
		.flags = 0,
	};
	posix.sigaction(posix.SIG.WINCH, &act, null);
}

/// Signal handler — only touches the atomic flag, nothing else.
/// The 0.16 stdlib redefined `Sigaction.handler_fn` to take `posix.SIG`
/// (an OS-specific enum) instead of `i32`. We accept the enum and ignore it.
fn handleSigwinch(_: posix.SIG) callconv(.c) void {
	resize_flag.store(true, .seq_cst);
}

/// Atomically read and clear the resize flag. Returns true if a resize
/// occurred since the last call.
pub fn checkAndClearResizeFlag() bool {
	return resize_flag.swap(false, .seq_cst);
}

// ── Terminal size ───────────────────────────────────────────────────

pub const TermSize = struct {
	cols: u16,
	rows: u16,
};

/// Query the terminal dimensions via ioctl(TIOCGWINSZ).
/// Returns true if stdin is connected to a terminal (tty).
/// Used by animation mode to decide whether to enter raw mode.
pub fn stdinIsTty() bool {
	return std.Io.File.stdin().isTty(runtime.io()) catch false;
}


pub fn getTermSizePosix() !TermSize {
	var ws = posix.winsize{
		.row = 0,
		.col = 0,
		.xpixel = 0,
		.ypixel = 0,
	};

	const fd = posix.STDOUT_FILENO;
	const err = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
	if (posix.errno(err) != .SUCCESS) {
		return error.IoctlFailed;
	}

	return TermSize{
		.cols = ws.col,
		.rows = ws.row,
	};
}

pub const CellPixelSize = struct {
	width: u16,
	height: u16,
};

/// Default cell pixel size when the terminal does not report it. Roughly the
/// size of a 9pt monospace cell on a modern HiDPI screen — close enough to keep
/// kitty mode usable as a fallback.
const DEFAULT_CELL_PX = CellPixelSize{ .width = 8, .height = 16 };

/// Query the terminal cell size in pixels via TIOCGWINSZ (xpixel/ypixel).
/// Most modern emulators (kitty, Ghostty, WezTerm, GNOME Terminal, xterm)
/// populate these fields. Returns DEFAULT_CELL_PX as a fallback when the
/// kernel reports zero pixels (older terminals, some serial consoles).
pub fn getCellPixelSizePosix() CellPixelSize {
	var ws = posix.winsize{
		.row = 0,
		.col = 0,
		.xpixel = 0,
		.ypixel = 0,
	};

	const fd = posix.STDOUT_FILENO;
	const err = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
	if (posix.errno(err) != .SUCCESS) return DEFAULT_CELL_PX;
	if (ws.col == 0 or ws.row == 0 or ws.xpixel == 0 or ws.ypixel == 0) return DEFAULT_CELL_PX;

	return .{
		.width = @intCast(ws.xpixel / ws.col),
		.height = @intCast(ws.ypixel / ws.row),
	};
}

// ── Compile-time verification ───────────────────────────────────────

test "terminal module compiles" {
	// Force the compiler to analyse every public declaration.
	comptime {
		_ = &enterRawMode;
		_ = &exitRawMode;
		_ = &enableMouseTracking;
		_ = &disableMouseTracking;
		_ = &hideCursor;
		_ = &showCursor;
		_ = &clearScreen;
		_ = &setupSigwinch;
		_ = &checkAndClearResizeFlag;
		_ = &getTermSizePosix;
		_ = &getCellPixelSizePosix;
		_ = &deleteKittyImageById;
		_ = &placeKittyImageById;
		_ = &detectKittyGraphicsSupport;
		_ = &stdinIsTty;
	}
}

test "writer-based functions instantiate with fixed buffer writer" {
	// Instantiate every anytype-writer function with a concrete type
	// so the compiler fully analyses the function bodies.
	var buf: [256]u8 = undefined;
	var w: std.Io.Writer = .fixed(&buf);

	try enableMouseTracking(&w);
	try disableMouseTracking(&w);
	try hideCursor(&w);
	try showCursor(&w);
	try clearScreen(&w);
}

test "SIGWINCH flag starts clear and round-trips" {
	// Flag should start as false.
	try std.testing.expect(!checkAndClearResizeFlag());
	// Manually store true, then clear should return true once.
	resize_flag.store(true, .seq_cst);
	try std.testing.expect(checkAndClearResizeFlag());
	try std.testing.expect(!checkAndClearResizeFlag());
}

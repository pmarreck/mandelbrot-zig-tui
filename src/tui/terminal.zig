// src/tui/terminal.zig
// Terminal control module: raw mode, mouse tracking, SIGWINCH, cursor.
// This is the ONLY file in the project that performs terminal I/O.

const std = @import("std");
const posix = std.posix;
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

/// Enable X10 + SGR mouse tracking (press/release with column > 223).
pub fn enableMouseTracking(writer: anytype) !void {
	try writer.writeAll("\x1b[?1000h\x1b[?1006h");
}

/// Disable SGR + X10 mouse tracking (reverse order of enable).
pub fn disableMouseTracking(writer: anytype) !void {
	try writer.writeAll("\x1b[?1006l\x1b[?1000l");
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
fn handleSigwinch(_: i32) callconv(.c) void {
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
	}
}

test "writer-based functions instantiate with fixed buffer writer" {
	// Instantiate every anytype-writer function with a concrete type
	// so the compiler fully analyses the function bodies.
	var buf: [256]u8 = undefined;
	var fbs = std.io.fixedBufferStream(&buf);
	const writer = fbs.writer();

	try enableMouseTracking(writer);
	try disableMouseTracking(writer);
	try hideCursor(writer);
	try showCursor(writer);
	try clearScreen(writer);
}

test "SIGWINCH flag starts clear and round-trips" {
	// Flag should start as false.
	try std.testing.expect(!checkAndClearResizeFlag());
	// Manually store true, then clear should return true once.
	resize_flag.store(true, .seq_cst);
	try std.testing.expect(checkAndClearResizeFlag());
	try std.testing.expect(!checkAndClearResizeFlag());
}

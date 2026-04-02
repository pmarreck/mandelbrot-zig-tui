// src/tui/input.zig
// Parses raw terminal bytes into typed Event values.
// Pure function: no I/O, no side effects.

const std = @import("std");

pub const MousePos = struct {
	col: u16,
	row: u16,
};

pub const Event = union(enum) {
	key_q,
	key_plus,
	key_minus,
	key_bracket_open,
	key_bracket_close,
	key_i,
	arrow_up,
	arrow_down,
	arrow_left,
	arrow_right,
	mouse_left: MousePos,
	mouse_right: MousePos,
	scroll_up: MousePos,
	scroll_down: MousePos,
	ctrl_c,
	resize,
	unknown,
};

/// Parse raw bytes from stdin into a typed Event.
/// Handles single-byte keypresses, CSI escape sequences (arrows),
/// SGR mouse protocol (\x1b[<btn;col;rowM), and Ctrl-C.
pub fn parseEvent(bytes: []const u8) Event {
	if (bytes.len == 0) return .unknown;

	if (bytes.len == 1) {
		return switch (bytes[0]) {
			'q' => .key_q,
			'+', '=' => .key_plus,
			'-' => .key_minus,
			'[' => .key_bracket_open,
			']' => .key_bracket_close,
			'i' => .key_i,
			0x03 => .ctrl_c,
			else => .unknown,
		};
	}

	if (bytes.len >= 3 and bytes[0] == 0x1b and bytes[1] == '[') {
		if (bytes.len == 3) {
			return switch (bytes[2]) {
				'A' => .arrow_up,
				'B' => .arrow_down,
				'C' => .arrow_right,
				'D' => .arrow_left,
				else => .unknown,
			};
		}

		if (bytes[2] == '<') {
			return parseSgrMouse(bytes[3..]);
		}
	}

	return .unknown;
}

/// Parse the payload of an SGR mouse sequence (after "\x1b[<").
/// Format: btn;col;row[Mm] where col/row are 1-based.
fn parseSgrMouse(bytes: []const u8) Event {
	var parts: [3]u16 = .{ 0, 0, 0 };
	var part_idx: usize = 0;
	var terminated = false;

	for (bytes) |byte| {
		if (byte == ';') {
			part_idx += 1;
			if (part_idx >= 3) return .unknown;
		} else if (byte == 'M' or byte == 'm') {
			terminated = true;
			break;
		} else if (byte >= '0' and byte <= '9') {
			parts[part_idx] = parts[part_idx] *% 10 +% @as(u16, byte - '0');
		} else {
			return .unknown;
		}
	}

	if (!terminated or part_idx != 2) return .unknown;

	const button = parts[0];
	const col = if (parts[1] > 0) parts[1] - 1 else 0;
	const row = if (parts[2] > 0) parts[2] - 1 else 0;

	const pos = MousePos{ .col = col, .row = row };

	// SGR button encoding: bits 0-1 = button (0=left, 1=middle, 2=right)
	// bit 6 (64) = scroll wheel. 64=scroll up, 65=scroll down.
	if (button >= 64) {
		return switch (button) {
			64 => .{ .scroll_up = pos },
			65 => .{ .scroll_down = pos },
			else => .unknown,
		};
	}
	return switch (button & 0x03) {
		0 => .{ .mouse_left = pos },
		2 => .{ .mouse_right = pos },
		else => .unknown,
	};
}

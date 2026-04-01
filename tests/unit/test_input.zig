const std = @import("std");
const testing = std.testing;
const input = @import("input");

test "parse 'q' as key_q" {
	const event = input.parseEvent("q");
	try testing.expectEqual(input.Event.key_q, event);
}

test "parse '+' as key_plus" {
	const event = input.parseEvent("+");
	try testing.expectEqual(input.Event.key_plus, event);
}

test "parse '-' as key_minus" {
	const event = input.parseEvent("-");
	try testing.expectEqual(input.Event.key_minus, event);
}

test "parse '[' as key_bracket_open" {
	const event = input.parseEvent("[");
	try testing.expectEqual(input.Event.key_bracket_open, event);
}

test "parse ']' as key_bracket_close" {
	const event = input.parseEvent("]");
	try testing.expectEqual(input.Event.key_bracket_close, event);
}

test "parse 'i' as key_i" {
	const event = input.parseEvent("i");
	try testing.expectEqual(input.Event.key_i, event);
}

test "parse Ctrl-C (0x03) as ctrl_c" {
	const event = input.parseEvent(&[_]u8{0x03});
	try testing.expectEqual(input.Event.ctrl_c, event);
}

test "parse arrow up escape sequence" {
	const event = input.parseEvent("\x1b[A");
	try testing.expectEqual(input.Event.arrow_up, event);
}

test "parse arrow down escape sequence" {
	const event = input.parseEvent("\x1b[B");
	try testing.expectEqual(input.Event.arrow_down, event);
}

test "parse arrow right escape sequence" {
	const event = input.parseEvent("\x1b[C");
	try testing.expectEqual(input.Event.arrow_right, event);
}

test "parse arrow left escape sequence" {
	const event = input.parseEvent("\x1b[D");
	try testing.expectEqual(input.Event.arrow_left, event);
}

test "parse SGR mouse left-click at col=40, row=12" {
	const event = input.parseEvent("\x1b[<0;41;13M");
	switch (event) {
		.mouse_left => |pos| {
			try testing.expectEqual(@as(u16, 40), pos.col);
			try testing.expectEqual(@as(u16, 12), pos.row);
		},
		else => return error.TestUnexpectedResult,
	}
}

test "parse SGR mouse right-click at col=10, row=5" {
	const event = input.parseEvent("\x1b[<2;11;6M");
	switch (event) {
		.mouse_right => |pos| {
			try testing.expectEqual(@as(u16, 10), pos.col);
			try testing.expectEqual(@as(u16, 5), pos.row);
		},
		else => return error.TestUnexpectedResult,
	}
}

test "unknown bytes parse as unknown" {
	const event = input.parseEvent(&[_]u8{0xFF});
	try testing.expectEqual(input.Event.unknown, event);
}

const std = @import("std");
const mandelbrot = @import("core/mandelbrot.zig");
const terminal = @import("tui/terminal.zig");
pub fn main() !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    if (comptime @import("builtin").mode == .Debug) {
        try stderr.print("\x1b[33mDEBUG BUILD\x1b[0m\n", .{});
        try stderr.flush();
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("Mandelbrot TUI — scaffolding complete\n", .{});
    try stdout.flush();
}

test "placeholder" {
    try std.testing.expect(true);
}

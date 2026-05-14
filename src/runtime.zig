// src/runtime.zig
// Process-wide runtime singletons for Zig 0.16's dependency-injected I/O model.
//
// Zig 0.16 moved I/O behind an `std.Io` interface that the migration doc says
// should be threaded as a function parameter (like `allocator`). Threading it
// through every TUI / pool / terminal callsite for a single-process CLI is
// proportionally invasive — see the dirtree firsthand note in the migration
// doc. The pragmatic shortcut is: capture `init.io` (and friends) once in
// `main()`, expose accessors for the rest of the program.
//
// The `builtin.is_test` fallback lets unit tests that don't go through `main`
// still build — they get `std.testing.io` automatically.

const std = @import("std");
const builtin = @import("builtin");

var captured_io: ?std.Io = null;
var captured_env: ?*const std.process.Environ.Map = null;

/// Called from `main` to capture the canonical I/O implementation.
pub fn set(io_val: std.Io, env: *const std.process.Environ.Map) void {
    captured_io = io_val;
    captured_env = env;
}

/// Get the I/O implementation. In tests, falls back to `std.testing.io`.
pub fn io() std.Io {
    if (captured_io) |v| return v;
    if (builtin.is_test) return std.testing.io;
    // If a non-test callsite hits this before `main` has called `set`, that's a
    // bug. Panic so we notice immediately.
    @panic("runtime.io() called before runtime.set() — initialize in main()");
}

/// Look up an environment variable. Returns null if unset or runtime hasn't been
/// initialised (which matches "no env" semantics for tests).
pub fn getEnv(name: []const u8) ?[]const u8 {
    if (captured_env) |env| return env.get(name);
    return null;
}

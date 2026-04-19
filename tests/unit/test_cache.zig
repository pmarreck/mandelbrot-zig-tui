const std = @import("std");
const testing = std.testing;
const cache = @import("cache");

test "CacheLevel init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var level = try cache.CacheLevel.init(allocator, .{
        .origin_re = -2.5,
        .origin_im = -1.0,
        .step_re = 0.05,
        .step_im = 0.05,
        .width = 80,
        .height = 40,
        .max_iter = 256,
    });
    defer level.deinit(allocator);

    try testing.expectEqual(@as(u32, 80), level.width);
    try testing.expectEqual(@as(u32, 40), level.height);
    try testing.expect(!level.complete);
    try testing.expectEqual(@as(usize, 3200), level.data.len);
}

test "CacheLevel pointAt returns correct complex coordinate" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var level = try cache.CacheLevel.init(allocator, .{
        .origin_re = -2.0,
        .origin_im = -1.0,
        .step_re = 0.1,
        .step_im = 0.1,
        .width = 40,
        .height = 20,
        .max_iter = 256,
    });
    defer level.deinit(allocator);

    // Point at (0, 0) should be at origin + half step (pixel center)
    const p = level.pointAt(0, 0);
    try testing.expectApproxEqAbs(@as(f64, -1.95), @as(f64, @floatCast(p.re)), 0.001);
    try testing.expectApproxEqAbs(@as(f64, -0.95), @as(f64, @floatCast(p.im)), 0.001);

    // Point at (1, 0) should be one step_re to the right
    const p2 = level.pointAt(1, 0);
    try testing.expectApproxEqAbs(@as(f64, -1.85), @as(f64, @floatCast(p2.re)), 0.001);
}

test "CacheLevel get/set data by grid coords" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var level = try cache.CacheLevel.init(allocator, .{
        .origin_re = 0.0,
        .origin_im = 0.0,
        .step_re = 1.0,
        .step_im = 1.0,
        .width = 10,
        .height = 10,
        .max_iter = 256,
    });
    defer level.deinit(allocator);

    level.set(3, 5, 42.0);
    try testing.expectEqual(@as(f64, 42.0), level.get(3, 5));
}

test "CacheLevel containsViewport checks bounds" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var level = try cache.CacheLevel.init(allocator, .{
        .origin_re = -2.0,
        .origin_im = -1.0,
        .step_re = 0.1,
        .step_im = 0.1,
        .width = 40,
        .height = 20,
        .max_iter = 256,
    });
    defer level.deinit(allocator);

    // Viewport fully inside: should contain
    try testing.expect(level.containsViewport(-1.0, 0.0, 0.05, 0.05, 20, 10));
    // Viewport extending beyond: should not contain
    try testing.expect(!level.containsViewport(-3.0, 0.0, 0.1, 0.1, 40, 20));
}

test "CacheLevel sampleStride extracts points at regular intervals" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var level = try cache.CacheLevel.init(allocator, .{
        .origin_re = 0.0,
        .origin_im = 0.0,
        .step_re = 1.0,
        .step_im = 1.0,
        .width = 8,
        .height = 8,
        .max_iter = 256,
    });
    defer level.deinit(allocator);

    // Fill with a pattern: value = row * 10 + col
    var r: u32 = 0;
    while (r < 8) : (r += 1) {
        var c: u32 = 0;
        while (c < 8) : (c += 1) {
            level.set(c, r, @as(f64, @floatFromInt(r * 10 + c)));
        }
    }

    // Sample at stride 2 starting from (0, 0) — 4x4 output
    var out: [16]f64 = undefined;
    level.sampleStride(0, 0, 2, 4, 4, &out);

    // out[0] should be level.get(0, 0) = 0
    try testing.expectEqual(@as(f64, 0), out[0]);
    // out[1] should be level.get(2, 0) = 2
    try testing.expectEqual(@as(f64, 2), out[1]);
    // out[4] should be level.get(0, 2) = 20
    try testing.expectEqual(@as(f64, 20), out[4]);
    // out[5] should be level.get(2, 2) = 22
    try testing.expectEqual(@as(f64, 22), out[5]);
}

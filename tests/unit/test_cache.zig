const std = @import("std");
const testing = std.testing;
const cache = @import("cache");

test "CacheLevel init and deinit" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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

    // Point at (0, 0) should be at origin (grid-vertex model)
    const p = level.pointAt(0, 0);
    try testing.expectApproxEqAbs(@as(f64, -2.0), @as(f64, @floatCast(p.re)), 0.001);
    try testing.expectApproxEqAbs(@as(f64, -1.0), @as(f64, @floatCast(p.im)), 0.001);

    // Point at (1, 0) should be one step_re to the right
    const p2 = level.pointAt(1, 0);
    try testing.expectApproxEqAbs(@as(f64, -1.9), @as(f64, @floatCast(p2.re)), 0.001);
}

test "CacheLevel get/set data by grid coords" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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

test "CacheStack init creates empty stack" {
    const stack = cache.CacheStack.init();
    for (stack.levels) |level| {
        try testing.expect(level == null);
    }
}

test "CacheStack initForViewport creates Level 0" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stack = cache.CacheStack.init();
    defer stack.deinit(allocator);

    try stack.initForViewport(allocator, -0.5, 0.0, 1.0, 80, 24, 256, 0.5);

    try testing.expect(stack.levels[0] != null);
    try testing.expectEqual(@as(u32, 80), stack.levels[0].?.width);
    try testing.expectEqual(@as(u32, 24), stack.levels[0].?.height);
    // Other levels should be null initially
    try testing.expect(stack.levels[1] == null);
}

test "CacheStack createLevel creates a 2x level with parent bounds" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stack = cache.CacheStack.init();
    defer stack.deinit(allocator);

    try stack.initForViewport(allocator, -0.5, 0.0, 1.0, 10, 10, 256, 0.5);
    try stack.createLevel(allocator, 1);

    try testing.expect(stack.levels[1] != null);
    // Level 1 should be 2x the dimensions of Level 0
    try testing.expectEqual(@as(u32, 20), stack.levels[1].?.width);
    try testing.expectEqual(@as(u32, 20), stack.levels[1].?.height);
    // Level 1 origin should match Level 0 origin
    try testing.expectEqual(stack.levels[0].?.origin_re, stack.levels[1].?.origin_re);
    // Level 1 step should be half of Level 0
    try testing.expectEqual(stack.levels[0].?.step_re / 2.0, stack.levels[1].?.step_re);
}

test "CacheStack findCoveringLevel: 2x zoom-in at center hits Level 1" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stack = cache.CacheStack.init();
    defer stack.deinit(allocator);

    // Initial viewport: 10×10 cells, centered at origin, zoom=1.
    // After initForViewport: Level 0 step = 4.0 / 1.0 / 10 = 0.4 (×aspect for im).
    try stack.initForViewport(allocator, 0.0, 0.0, 1.0, 10, 10, 256, 1.0);
    try stack.createLevel(allocator, 1);
    stack.levels[1].?.complete = true;

    const lvl0 = stack.levels[0].?;
    // 2x zoom-in at center of original viewport: same center, half the step.
    const new_step_re = lvl0.step_re / 2.0;
    const new_step_im = lvl0.step_im / 2.0;
    // New origin: center - 5 * new_step (since W=10).
    const new_origin_re = 0.0 - 5.0 * new_step_re;
    const new_origin_im = 0.0 - 5.0 * new_step_im;

    const cov = stack.findCoveringLevel(
        new_origin_re, new_origin_im, new_step_re, new_step_im,
        10, 10, 256,
    );
    try testing.expect(cov != null);
    try testing.expectEqual(@as(u8, 1), cov.?.level_idx);
    // Center crop of Level 1 (20×20) → offset (5, 5).
    try testing.expectEqual(@as(u32, 5), cov.?.col_offset);
    try testing.expectEqual(@as(u32, 5), cov.?.row_offset);
}

test "CacheStack findCoveringLevel: incomplete level is rejected" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stack = cache.CacheStack.init();
    defer stack.deinit(allocator);

    try stack.initForViewport(allocator, 0.0, 0.0, 1.0, 10, 10, 256, 1.0);
    try stack.createLevel(allocator, 1);
    // Level 1 created but NOT marked complete — coverage should miss it.

    const lvl0 = stack.levels[0].?;
    const cov = stack.findCoveringLevel(
        0.0 - 5.0 * (lvl0.step_re / 2.0),
        0.0 - 5.0 * (lvl0.step_im / 2.0),
        lvl0.step_re / 2.0,
        lvl0.step_im / 2.0,
        10, 10, 256,
    );
    try testing.expect(cov == null);
}

test "CacheStack findCoveringLevel: zoom-out (step doesn't match) misses" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stack = cache.CacheStack.init();
    defer stack.deinit(allocator);

    try stack.initForViewport(allocator, 0.0, 0.0, 1.0, 10, 10, 256, 1.0);
    try stack.createLevel(allocator, 1);
    stack.levels[1].?.complete = true;

    const lvl0 = stack.levels[0].?;
    // 2× zoom-OUT: new step is 2× old step, no level has that.
    const cov = stack.findCoveringLevel(
        0.0 - 5.0 * (lvl0.step_re * 2.0),
        0.0 - 5.0 * (lvl0.step_im * 2.0),
        lvl0.step_re * 2.0,
        lvl0.step_im * 2.0,
        10, 10, 256,
    );
    try testing.expect(cov == null);
}

test "CacheStack findCoveringLevel: max_iter mismatch is allowed (zoom-in semantics)" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stack = cache.CacheStack.init();
    defer stack.deinit(allocator);

    // Level 0 / Level 1 built with max_iter=256 (the current viewport).
    try stack.initForViewport(allocator, 0.0, 0.0, 1.0, 10, 10, 256, 1.0);
    try stack.createLevel(allocator, 1);
    stack.levels[1].?.complete = true;

    const lvl0 = stack.levels[0].?;
    // Simulate a 2x zoom-in: same center, half step. adaptiveMaxIter would
    // bump the new viewport's max_iter to 306 (256 + 50). Pre-fix this
    // mismatch caused findCoveringLevel to return null and fall through to
    // a fresh compute; now it should still hit (with documented halo
    // trade-off near the set boundary).
    const cov = stack.findCoveringLevel(
        0.0 - 5.0 * (lvl0.step_re / 2.0),
        0.0 - 5.0 * (lvl0.step_im / 2.0),
        lvl0.step_re / 2.0,
        lvl0.step_im / 2.0,
        10, 10, 306,
    );
    try testing.expect(cov != null);
    try testing.expectEqual(@as(u8, 1), cov.?.level_idx);
}

test "CacheStack findCoveringLevel: 2x zoom-in at corner exceeds level bbox" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stack = cache.CacheStack.init();
    defer stack.deinit(allocator);

    try stack.initForViewport(allocator, 0.0, 0.0, 1.0, 10, 10, 256, 1.0);
    try stack.createLevel(allocator, 1);
    stack.levels[1].?.complete = true;

    const lvl0 = stack.levels[0].?;
    // Click at top-left corner (col=0, row=0) → new center is at far edge of viewport.
    // New viewport extends past the cached bbox → no coverage.
    const click_re = lvl0.origin_re;
    const click_im = lvl0.origin_im;
    const new_step_re = lvl0.step_re / 2.0;
    const new_step_im = lvl0.step_im / 2.0;
    const new_origin_re = click_re - 5.0 * new_step_re;
    const new_origin_im = click_im - 5.0 * new_step_im;

    const cov = stack.findCoveringLevel(
        new_origin_re, new_origin_im, new_step_re, new_step_im,
        10, 10, 256,
    );
    try testing.expect(cov == null);
}

test "CacheStack extractInto: copies the right sub-grid" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stack = cache.CacheStack.init();
    defer stack.deinit(allocator);

    try stack.initForViewport(allocator, 0.0, 0.0, 1.0, 4, 4, 256, 1.0);
    try stack.createLevel(allocator, 1); // 8×8

    // Fill Level 1 with row*100 + col so we can spot offsets.
    var r: u32 = 0;
    while (r < 8) : (r += 1) {
        var c: u32 = 0;
        while (c < 8) : (c += 1) {
            stack.levels[1].?.set(c, r, @floatFromInt(r * 100 + c));
        }
    }
    stack.levels[1].?.complete = true;

    var out: [16]f64 = undefined;
    const cov = cache.CacheStack.Coverage{ .level_idx = 1, .col_offset = 2, .row_offset = 2 };
    stack.extractInto(cov, 4, 4, &out);

    // Expected: 4×4 sub-grid starting at (2,2) of Level 1.
    // Row 0: (2,2)=202, (3,2)=203, (4,2)=204, (5,2)=205
    try testing.expectEqual(@as(f64, 202), out[0]);
    try testing.expectEqual(@as(f64, 203), out[1]);
    try testing.expectEqual(@as(f64, 204), out[2]);
    try testing.expectEqual(@as(f64, 205), out[3]);
    // Row 3 (out): src row 5 → (2,5)=502, (3,5)=503, (4,5)=504, (5,5)=505
    try testing.expectEqual(@as(f64, 502), out[12]);
    try testing.expectEqual(@as(f64, 505), out[15]);
}

test "CacheStack invalidateAll clears everything" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stack = cache.CacheStack.init();
    defer stack.deinit(allocator);

    try stack.initForViewport(allocator, -0.5, 0.0, 1.0, 10, 10, 256, 0.5);
    try stack.createLevel(allocator, 1);

    stack.invalidateAll(allocator);

    for (stack.levels) |level| {
        try testing.expect(level == null);
    }
}

test "CacheStack nextIncompleteLevel finds first gap" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stack = cache.CacheStack.init();
    defer stack.deinit(allocator);

    try stack.initForViewport(allocator, -0.5, 0.0, 1.0, 10, 10, 256, 0.5);
    stack.levels[0].?.complete = true;

    // Level 1 doesn't exist yet — should be the next to compute
    try testing.expectEqual(@as(?u8, 1), stack.nextIncompleteLevel());
}

test "CacheStack nextIncompleteLevel returns null when all complete" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stack = cache.CacheStack.init();
    defer stack.deinit(allocator);

    try stack.initForViewport(allocator, -0.5, 0.0, 1.0, 10, 10, 256, 0.5);
    try stack.createLevel(allocator, 1);
    try stack.createLevel(allocator, 2);
    try stack.createLevel(allocator, 3);
    try stack.createLevel(allocator, 4);

    // Mark all complete
    for (&stack.levels) |*level| {
        if (level.*) |*l| l.complete = true;
    }

    try testing.expectEqual(@as(?u8, null), stack.nextIncompleteLevel());
}

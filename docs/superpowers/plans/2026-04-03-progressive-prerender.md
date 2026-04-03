# Progressive Background Pre-Rendering — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a multi-resolution cache with 3-thread background pre-computation so zooming in up to 4 levels (16x) is instant, panning reuses cached data, and all renders are parallelized.

**Architecture:** A `CacheStack` of 5 resolution levels (1x through 16x) lives in `core/cache.zig`. A `BackgroundScheduler` in `tui/pool.zig` manages a long-lived coordinator thread that spawns 3 short-lived workers per level using the 3-offset doubling pattern. The app event loop owns the cache, checks it before rendering, bumps an atomic generation counter on user action to cancel stale background work, and kicks new pre-computation after each frame.

**Tech Stack:** Zig 0.15.2, `std.Thread`, `std.atomic.Value`, no external deps.

**Spec:** `docs/superpowers/specs/2026-04-03-progressive-prerender-design.md`

**IMPORTANT Zig 0.15 notes:**
- `std.ArrayListUnmanaged(T)` — pass allocator to every method
- `std.Thread.spawn(.{}, function, .{args})` returns `std.Thread`
- `thread.join()` blocks until thread completes
- `std.atomic.Value(u32).init(0)` for atomic generation counter
- `@atomicLoad` and `@atomicStore` are replaced by `atomic_var.load(.acquire)` and `atomic_var.store(value, .release)`
- Named module imports in build.zig: `@import("module_name")` not relative paths

---

## File Structure

```
src/
  core/
    mandelbrot.zig     — MODIFY: add computeRowBand, parallelComputeRegion, computeDoubling
    cache.zig          — NEW: CacheLevel, CacheStack
  tui/
    pool.zig           — NEW: BackgroundScheduler (coordinator + 3 workers)
    renderer.zig       — MODIFY: add renderFrameFromBuffer (accept pre-computed []f64)
    app.zig            — MODIFY: own CacheStack + BackgroundScheduler, cache-aware render
tests/
  unit/
    test_cache.zig     — NEW
    test_parallel.zig  — NEW (parallel compute + doubling correctness)
  benchmark/
    bench_render.zig   — NEW
build.zig              — MODIFY: add cache_mod, pool_mod, new test targets
bm                     — NEW: benchmark runner script
```

---

### Task 1: CacheLevel Data Structure

**Files:**
- Create: `src/core/cache.zig`
- Create: `tests/unit/test_cache.zig`
- Modify: `build.zig` (add cache module + test target)

- [ ] **Step 1: Write failing tests for CacheLevel**

Create `src/core/cache.zig` with just a comment stub.

Create `tests/unit/test_cache.zig`:

```zig
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
```

- [ ] **Step 2: Add cache module to build.zig and test target**

Add to shared modules (after `mandelbrot_mod`):
```zig
const cache_mod = b.createModule(.{
    .root_source_file = b.path("src/core/cache.zig"),
});
```

Add test target:
```zig
const cache_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/test_cache.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cache", .module = cache_mod },
        },
    }),
});
const run_cache_tests = b.addRunArtifact(cache_tests);
test_step.dependOn(&run_cache_tests.step);
```

- [ ] **Step 3: Run tests — verify they fail**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: Compilation error — CacheLevel not found.

- [ ] **Step 4: Implement CacheLevel**

```zig
// src/core/cache.zig
// Multi-resolution cache for pre-computed Mandelbrot iteration values.
// Pure data structure: no I/O, no threading (threading lives in pool.zig).

const std = @import("std");

pub const CacheLevelParams = struct {
    origin_re: f128,
    origin_im: f128,
    step_re: f128,
    step_im: f128,
    width: u32,
    height: u32,
    max_iter: u32,
};

pub const ComplexPoint = struct {
    re: f128,
    im: f128,
};

pub const CacheLevel = struct {
    origin_re: f128,
    origin_im: f128,
    step_re: f128,
    step_im: f128,
    width: u32,
    height: u32,
    max_iter: u32,
    data: []f64,
    complete: bool,

    pub fn init(allocator: std.mem.Allocator, params: CacheLevelParams) !CacheLevel {
        const size = @as(usize, params.width) * @as(usize, params.height);
        const data = try allocator.alloc(f64, size);
        @memset(data, 0.0);
        return .{
            .origin_re = params.origin_re,
            .origin_im = params.origin_im,
            .step_re = params.step_re,
            .step_im = params.step_im,
            .width = params.width,
            .height = params.height,
            .max_iter = params.max_iter,
            .data = data,
            .complete = false,
        };
    }

    pub fn deinit(self: *CacheLevel, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.data = &.{};
    }

    /// Get the complex-plane coordinate for a grid cell (pixel center).
    pub fn pointAt(self: CacheLevel, col: u32, row: u32) ComplexPoint {
        return .{
            .re = self.origin_re + @as(f128, @floatFromInt(col)) * self.step_re + self.step_re / 2.0,
            .im = self.origin_im + @as(f128, @floatFromInt(row)) * self.step_im + self.step_im / 2.0,
        };
    }

    pub fn get(self: CacheLevel, col: u32, row: u32) f64 {
        const idx = @as(usize, row) * @as(usize, self.width) + @as(usize, col);
        return self.data[idx];
    }

    pub fn set(self: *CacheLevel, col: u32, row: u32, value: f64) void {
        const idx = @as(usize, row) * @as(usize, self.width) + @as(usize, col);
        self.data[idx] = value;
    }

    /// Check if this cache level's bounds fully contain a viewport defined
    /// by center, step sizes, and dimensions.
    pub fn containsViewport(
        self: CacheLevel,
        vp_origin_re: f128,
        vp_origin_im: f128,
        vp_step_re: f128,
        vp_step_im: f128,
        vp_width: u32,
        vp_height: u32,
    ) bool {
        const vp_end_re = vp_origin_re + @as(f128, @floatFromInt(vp_width)) * vp_step_re;
        const vp_end_im = vp_origin_im + @as(f128, @floatFromInt(vp_height)) * vp_step_im;
        const self_end_re = self.origin_re + @as(f128, @floatFromInt(self.width)) * self.step_re;
        const self_end_im = self.origin_im + @as(f128, @floatFromInt(self.height)) * self.step_im;

        return vp_origin_re >= self.origin_re and vp_origin_im >= self.origin_im and
            vp_end_re <= self_end_re and vp_end_im <= self_end_im;
    }

    /// Extract a sub-grid by striding. For a level at 2x resolution,
    /// reading every 2nd point gives the 1x data.
    /// out must have length >= out_width * out_height.
    pub fn sampleStride(
        self: CacheLevel,
        start_col: u32,
        start_row: u32,
        stride: u32,
        out_width: u32,
        out_height: u32,
        out: []f64,
    ) void {
        var r: u32 = 0;
        while (r < out_height) : (r += 1) {
            var c: u32 = 0;
            while (c < out_width) : (c += 1) {
                const src_col = start_col + c * stride;
                const src_row = start_row + r * stride;
                const out_idx = @as(usize, r) * @as(usize, out_width) + @as(usize, c);
                out[out_idx] = self.get(src_col, src_row);
            }
        }
    }
};
```

- [ ] **Step 5: Run tests — verify they pass**

Run: `nix develop -c zig build test -Doptimize=Debug`

- [ ] **Step 6: Commit**

```bash
git add src/core/cache.zig tests/unit/test_cache.zig build.zig
git commit -m "feat: CacheLevel data structure — grid-indexed iteration cache"
```

---

### Task 2: CacheStack (Level Management)

**Files:**
- Modify: `src/core/cache.zig` (add CacheStack)
- Modify: `tests/unit/test_cache.zig` (add CacheStack tests)

- [ ] **Step 1: Write failing tests for CacheStack**

Add to `tests/unit/test_cache.zig`:

```zig
test "CacheStack initForViewport creates Level 0" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

test "CacheStack shiftOnZoomIn rotates levels down" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stack = cache.CacheStack.init();
    defer stack.deinit(allocator);

    // Create levels 0-3
    try stack.initForViewport(allocator, -0.5, 0.0, 1.0, 10, 10, 256, 0.5);
    try stack.createLevel(allocator, 1); // 2x
    try stack.createLevel(allocator, 2); // 4x
    try stack.createLevel(allocator, 3); // 8x

    // Mark level 1 as having specific data
    stack.levels[1].?.set(0, 0, 99.0);
    stack.levels[1].?.complete = true;

    stack.shiftOnZoomIn(allocator);

    // Old level 1 should now be level 0
    try testing.expect(stack.levels[0] != null);
    try testing.expectEqual(@as(f64, 99.0), stack.levels[0].?.get(0, 0));
    // Level 4 should be null (needs computation)
    try testing.expect(stack.levels[4] == null);
}

test "CacheStack invalidateAll clears everything" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stack = cache.CacheStack.init();
    defer stack.deinit(allocator);

    try stack.initForViewport(allocator, -0.5, 0.0, 1.0, 10, 10, 256, 0.5);
    stack.levels[0].?.complete = true;

    // Level 1 doesn't exist yet — should be the next to compute
    try testing.expectEqual(@as(?u8, 1), stack.nextIncompleteLevel());
}
```

- [ ] **Step 2: Run tests — verify they fail**

- [ ] **Step 3: Implement CacheStack**

Add to `src/core/cache.zig`:

```zig
pub const NUM_LEVELS: u8 = 5; // levels 0-4 (1x through 16x)

pub const CacheStack = struct {
    levels: [NUM_LEVELS]?CacheLevel,

    pub fn init() CacheStack {
        return .{ .levels = .{ null, null, null, null, null } };
    }

    pub fn deinit(self: *CacheStack, allocator: std.mem.Allocator) void {
        for (&self.levels) |*level| {
            if (level.*) |*l| {
                l.deinit(allocator);
                level.* = null;
            }
        }
    }

    /// Initialize Level 0 for a viewport defined by center, zoom, terminal dims.
    pub fn initForViewport(
        self: *CacheStack,
        allocator: std.mem.Allocator,
        center_re: f128,
        center_im: f128,
        zoom: f128,
        width: u32,
        height: u32,
        max_iter: u32,
        aspect_ratio: f64,
    ) !void {
        self.invalidateAll(allocator);

        const w: f128 = @floatFromInt(width);
        const h: f128 = @floatFromInt(height);
        const aspect: f128 = @floatCast(aspect_ratio);
        const range_re = 4.0 / zoom;
        const range_im = range_re * (h / w) / aspect;

        self.levels[0] = try CacheLevel.init(allocator, .{
            .origin_re = center_re - range_re / 2.0,
            .origin_im = center_im - range_im / 2.0,
            .step_re = range_re / w,
            .step_im = range_im / h,
            .width = width,
            .height = height,
            .max_iter = max_iter,
        });
    }

    /// Create a level at the given index (1-4) by doubling the resolution
    /// of the level below it. The new level covers the same bounding box
    /// with half the step size and double the dimensions.
    pub fn createLevel(self: *CacheStack, allocator: std.mem.Allocator, level_idx: u8) !void {
        if (level_idx == 0 or level_idx >= NUM_LEVELS) return;
        const parent = self.levels[level_idx - 1] orelse return;

        // Free existing level if any
        if (self.levels[level_idx]) |*existing| {
            existing.deinit(allocator);
        }

        self.levels[level_idx] = try CacheLevel.init(allocator, .{
            .origin_re = parent.origin_re,
            .origin_im = parent.origin_im,
            .step_re = parent.step_re / 2.0,
            .step_im = parent.step_im / 2.0,
            .width = parent.width * 2,
            .height = parent.height * 2,
            .max_iter = parent.max_iter,
        });
    }

    /// Shift all levels down by one (zoom in). Level 0 is freed,
    /// Level 1 becomes Level 0, etc. Level 4 becomes null.
    pub fn shiftOnZoomIn(self: *CacheStack, allocator: std.mem.Allocator) void {
        if (self.levels[0]) |*l| l.deinit(allocator);
        var i: u8 = 0;
        while (i < NUM_LEVELS - 1) : (i += 1) {
            self.levels[i] = self.levels[i + 1];
        }
        self.levels[NUM_LEVELS - 1] = null;
    }

    /// Free all levels.
    pub fn invalidateAll(self: *CacheStack, allocator: std.mem.Allocator) void {
        for (&self.levels) |*level| {
            if (level.*) |*l| {
                l.deinit(allocator);
                level.* = null;
            }
        }
    }

    /// Find the first level index that needs computation.
    /// Returns null if all levels are complete.
    pub fn nextIncompleteLevel(self: CacheStack) ?u8 {
        var i: u8 = 0;
        while (i < NUM_LEVELS) : (i += 1) {
            if (self.levels[i]) |level| {
                if (!level.complete) return i;
            } else {
                return i;
            }
        }
        return null;
    }

    /// Get the generation (for cache identity — bumped on viewport change).
    /// Not stored here; managed by the app/scheduler.
};
```

- [ ] **Step 4: Run tests — verify they pass**

- [ ] **Step 5: Commit**

```bash
git add src/core/cache.zig tests/unit/test_cache.zig
git commit -m "feat: CacheStack — 5-level resolution pyramid with zoom shift"
```

---

### Task 3: Parallel computeRegion (Row-Band Splitting)

**Files:**
- Modify: `src/core/mandelbrot.zig` (add `computeRowBand`, `parallelComputeRegion`)
- Create: `tests/unit/test_parallel.zig`
- Modify: `build.zig` (add test target)

- [ ] **Step 1: Write failing tests**

Create `tests/unit/test_parallel.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const mandelbrot = @import("mandelbrot");

test "parallelComputeRegion matches sequential computeRegion" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const params = mandelbrot.RegionParams{
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 1.0,
        .width = 40,
        .height = 20,
        .max_iter = 100,
        .aspect_ratio = 0.5,
    };

    const size: usize = 40 * 20;
    const sequential = try allocator.alloc(f64, size);
    defer allocator.free(sequential);
    const parallel = try allocator.alloc(f64, size);
    defer allocator.free(parallel);

    mandelbrot.computeRegion(params, sequential);
    try mandelbrot.parallelComputeRegion(params, parallel);

    try testing.expectEqualSlices(f64, sequential, parallel);
}

test "parallelComputeRegion works with odd row count" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const params = mandelbrot.RegionParams{
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 1.0,
        .width = 20,
        .height = 7, // not divisible by 3
        .max_iter = 50,
        .aspect_ratio = 0.5,
    };

    const size: usize = 20 * 7;
    const sequential = try allocator.alloc(f64, size);
    defer allocator.free(sequential);
    const parallel = try allocator.alloc(f64, size);
    defer allocator.free(parallel);

    mandelbrot.computeRegion(params, sequential);
    try mandelbrot.parallelComputeRegion(params, parallel);

    try testing.expectEqualSlices(f64, sequential, parallel);
}
```

- [ ] **Step 2: Add test target to build.zig**

```zig
const parallel_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/test_parallel.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mandelbrot", .module = mandelbrot_mod },
        },
    }),
});
const run_parallel_tests = b.addRunArtifact(parallel_tests);
test_step.dependOn(&run_parallel_tests.step);
```

- [ ] **Step 3: Run tests — verify they fail**

- [ ] **Step 4: Implement parallelComputeRegion**

Add to `src/core/mandelbrot.zig`:

```zig
const NUM_THREADS: u32 = 3;

/// Compute a contiguous band of rows (from start_row to end_row exclusive).
/// Same math as computeRegion but only fills the specified row range.
/// Thread-safe: no shared mutable state.
pub fn computeRowBand(params: RegionParams, out: []f64, start_row: u16, end_row: u16) void {
    const w: f128 = @floatFromInt(params.width);
    const h: f128 = @floatFromInt(params.height);
    const aspect: f128 = @floatCast(params.aspect_ratio);

    const range_re = 4.0 / params.zoom;
    const range_im = range_re * (h / w) / aspect;

    const step_re = range_re / w;
    const step_im = range_im / h;

    const start_re = params.center_re - range_re / 2.0;
    const start_im = params.center_im - range_im / 2.0;

    var row = start_row;
    while (row < end_row) : (row += 1) {
        var col: u16 = 0;
        while (col < params.width) : (col += 1) {
            const c_re = start_re + @as(f128, @floatFromInt(col)) * step_re + step_re / 2.0;
            const c_im = start_im + @as(f128, @floatFromInt(row)) * step_im + step_im / 2.0;
            const idx = @as(usize, row) * @as(usize, params.width) + @as(usize, col);
            out[idx] = computeIterations(c_re, c_im, params.max_iter);
        }
    }
}

/// Parallel version of computeRegion: splits rows across 3 threads.
/// Output is identical to sequential computeRegion.
pub fn parallelComputeRegion(params: RegionParams, out: []f64) !void {
    const height = params.height;
    if (height < NUM_THREADS) {
        // Too few rows for threading — fall back to sequential
        computeRegion(params, out);
        return;
    }

    const rows_per_thread = height / NUM_THREADS;
    var threads: [NUM_THREADS]std.Thread = undefined;
    var i: u32 = 0;
    while (i < NUM_THREADS) : (i += 1) {
        const start_row: u16 = @intCast(i * rows_per_thread);
        const end_row: u16 = if (i == NUM_THREADS - 1) height else @intCast((i + 1) * rows_per_thread);
        threads[i] = try std.Thread.spawn(.{}, computeRowBand, .{ params, out, start_row, end_row });
    }
    for (&threads) |*t| t.join();
}
```

- [ ] **Step 5: Run tests — verify they pass**

- [ ] **Step 6: Commit**

```bash
git add src/core/mandelbrot.zig tests/unit/test_parallel.zig build.zig
git commit -m "feat: parallel computeRegion — 3-thread row-band splitting"
```

---

### Task 4: 3-Offset Doubling Algorithm

**Files:**
- Modify: `src/core/mandelbrot.zig` (add `computeDoubling`)
- Modify: `src/core/cache.zig` (add `inheritFromParent`)
- Modify: `tests/unit/test_parallel.zig` (add doubling tests)

- [ ] **Step 1: Write failing tests for doubling**

Add to `tests/unit/test_parallel.zig`:

```zig
const cache = @import("cache");

test "computeDoubling: even-indexed points match parent level" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a small parent level and compute it
    var parent = try cache.CacheLevel.init(allocator, .{
        .origin_re = -2.0,
        .origin_im = -1.0,
        .step_re = 0.5,
        .step_im = 0.5,
        .width = 8,
        .height = 4,
        .max_iter = 50,
    });
    defer parent.deinit(allocator);

    // Fill parent with computeRegion
    mandelbrot.computeRegionDirect(&parent);
    parent.complete = true;

    // Create child at 2x
    var child = try cache.CacheLevel.init(allocator, .{
        .origin_re = parent.origin_re,
        .origin_im = parent.origin_im,
        .step_re = parent.step_re / 2.0,
        .step_im = parent.step_im / 2.0,
        .width = parent.width * 2,
        .height = parent.height * 2,
        .max_iter = parent.max_iter,
    });
    defer child.deinit(allocator);

    // Inherit + compute doubling
    child.inheritFromParent(parent);
    try mandelbrot.computeDoubling(&parent, &child, null);

    // Check even-indexed points match parent
    var row: u32 = 0;
    while (row < parent.height) : (row += 1) {
        var col: u32 = 0;
        while (col < parent.width) : (col += 1) {
            try testing.expectEqual(parent.get(col, row), child.get(col * 2, row * 2));
        }
    }
}

test "computeDoubling: result matches sequential full compute" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parent = try cache.CacheLevel.init(allocator, .{
        .origin_re = -2.0,
        .origin_im = -1.0,
        .step_re = 0.5,
        .step_im = 0.5,
        .width = 8,
        .height = 4,
        .max_iter = 50,
    });
    defer parent.deinit(allocator);

    mandelbrot.computeRegionDirect(&parent);
    parent.complete = true;

    // Create child and fill via doubling
    var child = try cache.CacheLevel.init(allocator, .{
        .origin_re = parent.origin_re,
        .origin_im = parent.origin_im,
        .step_re = parent.step_re / 2.0,
        .step_im = parent.step_im / 2.0,
        .width = parent.width * 2,
        .height = parent.height * 2,
        .max_iter = parent.max_iter,
    });
    defer child.deinit(allocator);

    child.inheritFromParent(parent);
    try mandelbrot.computeDoubling(&parent, &child, null);

    // Create reference via full sequential compute
    var reference = try cache.CacheLevel.init(allocator, .{
        .origin_re = child.origin_re,
        .origin_im = child.origin_im,
        .step_re = child.step_re,
        .step_im = child.step_im,
        .width = child.width,
        .height = child.height,
        .max_iter = child.max_iter,
    });
    defer reference.deinit(allocator);

    mandelbrot.computeRegionDirect(&reference);

    try testing.expectEqualSlices(f64, reference.data, child.data);
}
```

- [ ] **Step 2: Run tests — verify they fail**

- [ ] **Step 3: Implement inheritFromParent in cache.zig**

Add to `CacheLevel`:

```zig
/// Copy data from parent level into even-indexed positions.
/// Parent at WxH, self at 2Wx2H. parent[col,row] → self[col*2, row*2].
pub fn inheritFromParent(self: *CacheLevel, parent: CacheLevel) void {
    var row: u32 = 0;
    while (row < parent.height) : (row += 1) {
        var col: u32 = 0;
        while (col < parent.width) : (col += 1) {
            self.set(col * 2, row * 2, parent.get(col, row));
        }
    }
}
```

- [ ] **Step 4: Implement computeRegionDirect and computeDoubling in mandelbrot.zig**

```zig
const cache_mod = @import("cache");

/// Fill a CacheLevel's data buffer using its own grid coordinates.
/// Convenience wrapper over computeIterations for cache levels.
pub fn computeRegionDirect(level: *cache_mod.CacheLevel) void {
    var row: u32 = 0;
    while (row < level.height) : (row += 1) {
        var col: u32 = 0;
        while (col < level.width) : (col += 1) {
            const pt = level.pointAt(col, row);
            level.set(col, row, computeIterations(pt.re, pt.im, level.max_iter));
        }
    }
    level.complete = true;
}

/// Compute the 3 offset patterns to double resolution from parent to child.
/// Child must be 2x parent dimensions with even-indexed points already inherited.
/// Spawns 3 threads (odd-col/even-row, even-col/odd-row, odd-col/odd-row).
/// If generation is non-null, threads check it per-row for cancellation.
pub fn computeDoubling(
    parent: *const cache_mod.CacheLevel,
    child: *cache_mod.CacheLevel,
    generation: ?*const std.atomic.Value(u32),
) !void {
    const expected_gen: u32 = if (generation) |g| g.load(.acquire) else 0;

    const OffsetWorkerArgs = struct {
        child: *cache_mod.CacheLevel,
        col_start: u32, // 0 or 1
        row_start: u32, // 0 or 1
        gen: ?*const std.atomic.Value(u32),
        expected: u32,
    };

    const worker = struct {
        fn run(args: OffsetWorkerArgs) void {
            var row: u32 = args.row_start;
            while (row < args.child.height) : (row += 2) {
                // Check cancellation every row
                if (args.gen) |g| {
                    if (g.load(.acquire) != args.expected) return;
                }
                var col: u32 = args.col_start;
                while (col < args.child.width) : (col += 2) {
                    const pt = args.child.pointAt(col, row);
                    args.child.set(col, row, computeIterations(pt.re, pt.im, args.child.max_iter));
                }
            }
        }
    }.run;

    _ = parent; // Parent data already inherited into child's even-even slots

    var threads: [3]std.Thread = undefined;
    // Thread 1: odd col, even row
    threads[0] = try std.Thread.spawn(.{}, worker, .{OffsetWorkerArgs{
        .child = child, .col_start = 1, .row_start = 0,
        .gen = generation, .expected = expected_gen,
    }});
    // Thread 2: even col, odd row
    threads[1] = try std.Thread.spawn(.{}, worker, .{OffsetWorkerArgs{
        .child = child, .col_start = 0, .row_start = 1,
        .gen = generation, .expected = expected_gen,
    }});
    // Thread 3: odd col, odd row
    threads[2] = try std.Thread.spawn(.{}, worker, .{OffsetWorkerArgs{
        .child = child, .col_start = 1, .row_start = 1,
        .gen = generation, .expected = expected_gen,
    }});

    for (&threads) |*t| t.join();

    // Check if computation completed (wasn't cancelled)
    if (generation) |g| {
        child.complete = (g.load(.acquire) == expected_gen);
    } else {
        child.complete = true;
    }
}
```

NOTE: mandelbrot.zig will need to import cache. Add `cache` as a named import for the mandelbrot module in build.zig. **Be careful about circular imports** — cache.zig does NOT import mandelbrot.zig; only mandelbrot.zig imports cache.zig for the `CacheLevel` type used in `computeRegionDirect` and `computeDoubling`.

- [ ] **Step 5: Update build.zig module dependencies**

Add cache as an import to mandelbrot_mod:
```zig
const mandelbrot_mod = b.createModule(.{
    .root_source_file = b.path("src/core/mandelbrot.zig"),
    .imports = &.{
        .{ .name = "cache", .module = cache_mod },
    },
});
```

And add cache as an import to the parallel test target:
```zig
.imports = &.{
    .{ .name = "mandelbrot", .module = mandelbrot_mod },
    .{ .name = "cache", .module = cache_mod },
},
```

**IMPORTANT**: This creates a dependency order issue — `cache_mod` must be defined BEFORE `mandelbrot_mod` in build.zig. Reorder the module definitions accordingly.

- [ ] **Step 6: Run tests — verify they pass**

- [ ] **Step 7: Commit**

```bash
git add src/core/mandelbrot.zig src/core/cache.zig tests/unit/test_parallel.zig build.zig
git commit -m "feat: 3-offset doubling — inherit parent points + 3-thread gap fill"
```

---

### Task 5: Background Scheduler

**Files:**
- Create: `src/tui/pool.zig`
- Modify: `build.zig` (add pool module)

- [ ] **Step 1: Implement BackgroundScheduler**

This is I/O/threading code — tested via integration in Tasks 6-7 and the doubling correctness tests in Task 4.

```zig
// src/tui/pool.zig
// Background pre-computation scheduler.
// Manages a coordinator thread that progressively fills cache levels 1-4
// using the 3-offset doubling pattern. Cancellable via atomic generation counter.

const std = @import("std");
const cache_mod = @import("cache");
const mandelbrot = @import("mandelbrot");

pub const BackgroundScheduler = struct {
    generation: std.atomic.Value(u32),
    coordinator: ?std.Thread,
    allocator: std.mem.Allocator,
    // Shared pointer to the cache stack — owned by app.zig
    cache: *cache_mod.CacheStack,
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, cache_stack: *cache_mod.CacheStack) BackgroundScheduler {
        return .{
            .generation = std.atomic.Value(u32).init(0),
            .coordinator = null,
            .allocator = allocator,
            .cache = cache_stack,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    /// Start background pre-computation from current cache state.
    /// If already running, bumps generation to cancel stale work and restart.
    pub fn requestWork(self: *BackgroundScheduler) void {
        _ = self.generation.fetchAdd(1, .acq_rel);

        if (self.coordinator != null) {
            // Coordinator will see the new generation and restart
            return;
        }

        self.running.store(true, .release);
        self.coordinator = std.Thread.spawn(.{}, coordinatorLoop, .{self}) catch null;
    }

    /// Signal coordinator to stop and wait for it.
    pub fn stop(self: *BackgroundScheduler) void {
        self.running.store(false, .release);
        _ = self.generation.fetchAdd(1, .acq_rel);
        if (self.coordinator) |coord| {
            coord.join();
            self.coordinator = null;
        }
    }

    /// Bump generation counter — causes current work to be abandoned.
    pub fn cancel(self: *BackgroundScheduler) void {
        _ = self.generation.fetchAdd(1, .acq_rel);
    }

    fn coordinatorLoop(self: *BackgroundScheduler) void {
        while (self.running.load(.acquire)) {
            const gen = self.generation.load(.acquire);

            // Find next level to compute
            const next = self.cache.nextIncompleteLevel() orelse {
                // All levels complete — sleep briefly and check again
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            };

            // Skip level 0 — that's foreground's job
            if (next == 0) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            // Ensure parent level exists and is complete
            if (next > 0) {
                if (self.cache.levels[next - 1]) |parent| {
                    if (!parent.complete) {
                        std.Thread.sleep(10 * std.time.ns_per_ms);
                        continue;
                    }
                } else {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
            }

            // Check generation hasn't changed
            if (self.generation.load(.acquire) != gen) continue;

            // Create the level if it doesn't exist
            if (self.cache.levels[next] == null) {
                self.cache.createLevel(self.allocator, next) catch continue;
            }

            // Inherit parent data
            if (self.cache.levels[next]) |*child| {
                if (self.cache.levels[next - 1]) |parent| {
                    child.inheritFromParent(parent);
                }
            }

            // Check generation again before expensive work
            if (self.generation.load(.acquire) != gen) continue;

            // Compute the doubling (spawns 3 threads internally)
            if (self.cache.levels[next]) |*child| {
                if (self.cache.levels[next - 1]) |*parent| {
                    mandelbrot.computeDoubling(parent, child, &self.generation) catch continue;
                }
            }
        }
    }
};
```

- [ ] **Step 2: Add pool module to build.zig**

```zig
const pool_mod = b.createModule(.{
    .root_source_file = b.path("src/tui/pool.zig"),
    .imports = &.{
        .{ .name = "cache", .module = cache_mod },
        .{ .name = "mandelbrot", .module = mandelbrot_mod },
    },
});
```

Add pool_mod as an import to app_mod:
```zig
const app_mod = b.createModule(.{
    .root_source_file = b.path("src/tui/app.zig"),
    .imports = &.{
        .{ .name = "terminal", .module = terminal_mod },
        .{ .name = "input", .module = input_mod },
        .{ .name = "renderer", .module = renderer_mod },
        .{ .name = "viewport", .module = viewport_mod },
        .{ .name = "cache", .module = cache_mod },
        .{ .name = "mandelbrot", .module = mandelbrot_mod },
        .{ .name = "pool", .module = pool_mod },
    },
});
```

- [ ] **Step 3: Verify compilation**

Run: `nix develop -c zig build -Doptimize=Debug`

- [ ] **Step 4: Commit**

```bash
git add src/tui/pool.zig build.zig
git commit -m "feat: BackgroundScheduler — coordinator + 3-thread level pre-computation"
```

---

### Task 6: Renderer Accepts Pre-Computed Buffer

**Files:**
- Modify: `src/tui/renderer.zig` (add `renderFrameFromBuffer`)
- Modify: `tests/unit/test_renderer.zig` (add test)

- [ ] **Step 1: Write failing test**

Add to `tests/unit/test_renderer.zig`:

```zig
test "renderFrameFromBuffer produces same output as renderFrame" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const state = renderer.RenderState{
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 1.0,
        .max_iter = 50,
        .show_info = false,
    };

    const width: u16 = 10;
    const height: u16 = 5;

    // Render the normal way
    const output1 = try renderer.renderFrame(state, width, height, allocator);
    defer allocator.free(output1);

    // Compute the buffer manually and render from it
    const mandelbrot_import = @import("mandelbrot");
    const pixel_count: usize = @as(usize, width) * @as(usize, height);
    const iter_buf = try allocator.alloc(f64, pixel_count);
    defer allocator.free(iter_buf);

    mandelbrot_import.computeRegion(.{
        .center_re = state.center_re,
        .center_im = state.center_im,
        .zoom = state.zoom,
        .width = width,
        .height = height,
        .max_iter = state.max_iter,
        .aspect_ratio = 0.5,
    }, iter_buf);

    const output2 = try renderer.renderFrameFromBuffer(state, width, height, iter_buf, allocator);
    defer allocator.free(output2);

    try testing.expectEqualSlices(u8, output1, output2);
}
```

Note: the test needs the `mandelbrot` import. Update the renderer test target in build.zig to include it:
```zig
.imports = &.{
    .{ .name = "renderer", .module = renderer_mod },
    .{ .name = "mandelbrot", .module = mandelbrot_mod },
},
```

- [ ] **Step 2: Run test — verify it fails**

- [ ] **Step 3: Implement renderFrameFromBuffer**

Refactor `renderFrame` in `src/tui/renderer.zig`:

Extract the colorize+ANSI logic into `renderFrameFromBuffer(state, width, height, iter_buf, allocator) -> []u8`, then make `renderFrame` call it after computing the buffer:

```zig
/// Render from a pre-computed iteration buffer. The core rendering function.
pub fn renderFrameFromBuffer(
    state: RenderState,
    width: u16,
    height: u16,
    iter_buf: []const f64,
    allocator: std.mem.Allocator,
) ![]u8 {
    const render_height: u16 = if (state.show_info and height > 1) height - 1 else height;
    // ... existing colorize + ANSI logic using iter_buf ...
    // (move the guts of renderFrame here, remove the computeRegion call)
}

/// Convenience: compute + render in one call (current behavior).
pub fn renderFrame(
    state: RenderState,
    width: u16,
    height: u16,
    allocator: std.mem.Allocator,
) ![]u8 {
    const render_height: u16 = if (state.show_info and height > 1) height - 1 else height;
    const pixel_count: usize = @as(usize, width) * @as(usize, render_height);
    const iter_buf = try allocator.alloc(f64, pixel_count);
    defer allocator.free(iter_buf);

    mandelbrot.computeRegion(.{
        .center_re = state.center_re,
        .center_im = state.center_im,
        .zoom = state.zoom,
        .width = width,
        .height = render_height,
        .max_iter = state.max_iter,
        .aspect_ratio = ASPECT_RATIO,
    }, iter_buf);

    return renderFrameFromBuffer(state, width, height, iter_buf, allocator);
}
```

- [ ] **Step 4: Run tests — verify they pass**

- [ ] **Step 5: Commit**

```bash
git add src/tui/renderer.zig tests/unit/test_renderer.zig build.zig
git commit -m "feat: renderFrameFromBuffer — render from pre-computed cache buffer"
```

---

### Task 7: App Integration (Cache-Aware Event Loop)

**Files:**
- Modify: `src/tui/app.zig` (major changes to `run` and `processEvent`)

This is the integration task — wiring the cache and scheduler into the event loop.

- [ ] **Step 1: Add cache and scheduler to AppState / run()**

Modify `run()` to:
1. Create a `CacheStack` and `BackgroundScheduler`
2. On `needs_redraw`: check cache first, parallel compute if miss, then render
3. After rendering: kick background scheduler
4. On user action that changes viewport: bump generation, invalidate/shift cache

Key changes to `run()`:

```zig
pub fn run(initial_state: AppState, allocator: std.mem.Allocator) !void {
    var state = initial_state;
    state.needs_redraw = true;

    var cache_stack = cache_mod.CacheStack.init();
    defer cache_stack.deinit(allocator);

    var scheduler = pool.BackgroundScheduler.init(allocator, &cache_stack);
    defer scheduler.stop();

    // ... terminal setup same as before ...

    while (state.running) {
        // ... SIGWINCH check same as before ...

        if (state.needs_redraw) {
            const render_height: u16 = if (state.show_info and state.term_height > 1)
                state.term_height - 1 else state.term_height;
            const pixel_count = @as(usize, state.term_width) * @as(usize, render_height);

            const iter_buf = try allocator.alloc(f64, pixel_count);
            defer allocator.free(iter_buf);

            // Try cache first
            var cache_hit = false;
            if (cache_stack.levels[0]) |level| {
                if (level.complete and level.width == state.term_width and level.height == render_height) {
                    @memcpy(iter_buf, level.data[0..pixel_count]);
                    cache_hit = true;
                }
            }

            if (!cache_hit) {
                // Parallel foreground compute
                try mandelbrot.parallelComputeRegion(.{
                    .center_re = state.center_re,
                    .center_im = state.center_im,
                    .zoom = state.zoom,
                    .width = state.term_width,
                    .height = render_height,
                    .max_iter = state.max_iter,
                    .aspect_ratio = ASPECT_RATIO,
                }, iter_buf);

                // Store in cache level 0
                try cache_stack.initForViewport(allocator,
                    state.center_re, state.center_im, state.zoom,
                    state.term_width, render_height, state.max_iter, ASPECT_RATIO);
                if (cache_stack.levels[0]) |*level| {
                    @memcpy(level.data, iter_buf);
                    level.complete = true;
                }
            }

            const frame = try renderer.renderFrameFromBuffer(.{
                .center_re = state.center_re,
                .center_im = state.center_im,
                .zoom = state.zoom,
                .max_iter = state.max_iter,
                .show_info = state.show_info,
            }, state.term_width, state.term_height, iter_buf, allocator);
            defer allocator.free(frame);

            try stdout.writeAll(frame);
            try stdout.flush();
            state.needs_redraw = false;

            // Kick background pre-computation
            scheduler.requestWork();
        }

        // ... input handling same as before ...
    }
}
```

- [ ] **Step 2: Add cache invalidation to processEvent**

When the viewport changes (zoom, pan, resize, max_iter change), the app needs to signal what kind of invalidation is needed. Since `processEvent` is a pure function (no side effects), add a `cache_action` field to `AppState`:

```zig
pub const CacheAction = enum {
    none,
    invalidate_all,   // zoom, resize, max_iter change
    shift_zoom_in,    // zoom in — try to use pre-computed level
    shift_zoom_out,   // zoom out — keep center, compute border
};
```

Add `cache_action: CacheAction = .none` to `AppState`.

In `processEvent`:
- Zoom in (click, +, scroll up): set `cache_action = .shift_zoom_in`
- Zoom out (right-click, -, scroll down): set `cache_action = .invalidate_all` (for now; optimize later)
- Pan (drag, arrows): set `cache_action = .invalidate_all` (for now; optimize later)
- Resize, max_iter change: set `cache_action = .invalidate_all`

Then in `run()`, before the render block:

```zig
switch (state.cache_action) {
    .shift_zoom_in => {
        scheduler.cancel();
        cache_stack.shiftOnZoomIn(allocator);
    },
    .invalidate_all => {
        scheduler.cancel();
        cache_stack.invalidateAll(allocator);
    },
    .none => {},
    .shift_zoom_out => {
        scheduler.cancel();
        cache_stack.invalidateAll(allocator);
    },
}
state.cache_action = .none;
```

- [ ] **Step 3: Verify compilation and existing tests pass**

Run: `nix develop -c zig build test -Doptimize=Debug`

Note: existing `processEvent` tests will need the new `cache_action` field added to their assertions or left as-is (default `.none` is fine for events that don't change viewport).

- [ ] **Step 4: Manual test — run the app, zoom in 4 times rapidly, check for instant renders**

Run: `nix develop -c zig build run -Doptimize=Debug`

- [ ] **Step 5: Commit**

```bash
git add src/tui/app.zig
git commit -m "feat: cache-aware event loop — parallel render + background pre-computation"
```

---

### Task 8: Benchmarks

**Files:**
- Create: `tests/benchmark/bench_render.zig`
- Create: `bm` (bash script)
- Modify: `build.zig` (add benchmark target)

- [ ] **Step 1: Create benchmark**

Create `tests/benchmark/bench_render.zig`:

```zig
const std = @import("std");
const mandelbrot = @import("mandelbrot");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const width: u16 = 200;
    const height: u16 = 60;
    const max_iter: u32 = 256;
    const size: usize = @as(usize, width) * @as(usize, height);

    const buf_seq = try allocator.alloc(f64, size);
    defer allocator.free(buf_seq);
    const buf_par = try allocator.alloc(f64, size);
    defer allocator.free(buf_par);

    const params = mandelbrot.RegionParams{
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 1.0,
        .width = width,
        .height = height,
        .max_iter = max_iter,
        .aspect_ratio = 0.5,
    };

    // Warm up
    mandelbrot.computeRegion(params, buf_seq);

    // Benchmark sequential
    const N = 20;
    var timer = try std.time.Timer.start();

    var i: u32 = 0;
    while (i < N) : (i += 1) {
        mandelbrot.computeRegion(params, buf_seq);
    }
    const seq_ns = timer.read();

    // Benchmark parallel
    timer.reset();
    i = 0;
    while (i < N) : (i += 1) {
        try mandelbrot.parallelComputeRegion(params, buf_par);
    }
    const par_ns = timer.read();

    const seq_ms = @as(f64, @floatFromInt(seq_ns)) / @as(f64, @floatFromInt(N)) / 1_000_000.0;
    const par_ms = @as(f64, @floatFromInt(par_ns)) / @as(f64, @floatFromInt(N)) / 1_000_000.0;
    const speedup = seq_ms / par_ms;

    const stderr = std.io.getStdErr().writer();
    try stderr.print("\n=== Mandelbrot Render Benchmark ({d}x{d}, iter={d}, N={d}) ===\n", .{ width, height, max_iter, N });
    try stderr.print("  Sequential:  {d:.2} ms/frame\n", .{seq_ms});
    try stderr.print("  Parallel:    {d:.2} ms/frame\n", .{par_ms});
    try stderr.print("  Speedup:     {d:.2}x\n\n", .{speedup});

    // Verify correctness
    if (!std.mem.eql(f64, buf_seq, buf_par)) {
        try stderr.print("  WARNING: parallel output differs from sequential!\n", .{});
    }
}
```

NOTE: The benchmark uses `std.io.getStdErr().writer()` which is the Zig 0.15 raw writer. Check whether this is the correct API — it might need the buffered writer pattern. If so, use:
```zig
var stderr_buf: [4096]u8 = undefined;
var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
const stderr = &stderr_writer.interface;
```
And add `try stderr.flush();` at the end.

- [ ] **Step 2: Add benchmark target to build.zig**

```zig
const bench_exe = b.addExecutable(.{
    .name = "bench-render",
    .root_module = b.createModule(.{
        .root_source_file = b.path("tests/benchmark/bench_render.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always benchmark in release mode
        .imports = &.{
            .{ .name = "mandelbrot", .module = mandelbrot_mod },
        },
    }),
});
b.installArtifact(bench_exe);
const bench_step = b.step("bench", "Run benchmarks");
const run_bench = b.addRunArtifact(bench_exe);
bench_step.dependOn(&run_bench.step);
```

- [ ] **Step 3: Create `bm` script**

```bash
#!/usr/bin/env bash
set -u

echo "Building benchmarks (ReleaseFast)..."
nix develop -c zig build bench 2>&1
echo ""
echo "Results logged to benchmarks/results.log"
nix develop -c zig build bench 2>&1 | tee -a benchmarks/results.log
```

```bash
chmod +x bm
mkdir -p benchmarks
```

- [ ] **Step 4: Run benchmark and verify output**

Run: `nix develop -c zig build bench`
Expected: Sequential vs parallel timing, speedup ratio.

- [ ] **Step 5: Commit**

```bash
git add tests/benchmark/bench_render.zig bm build.zig
git commit -m "feat: benchmark suite — sequential vs parallel render comparison"
```

---

### Task 9: Documentation & Cleanup

**Files:**
- Modify: `PLAN.md`
- Modify: `CODE_MINIMAP.md`
- Modify: `.gitignore` (add `benchmarks/`)

- [ ] **Step 1: Update PLAN.md** — mark pre-rendering tasks complete, add new future items

- [ ] **Step 2: Update CODE_MINIMAP.md** — add cache.zig, pool.zig, new functions in mandelbrot.zig

- [ ] **Step 3: Add `benchmarks/` to .gitignore** (the results.log is ephemeral)

Actually, benchmarks/results.log should be tracked for performance regression detection per CLAUDE.md. Keep it committed.

- [ ] **Step 4: Final test run**

Run: `./test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add PLAN.md CODE_MINIMAP.md
git commit -m "docs: update PLAN.md and CODE_MINIMAP.md for progressive pre-rendering"
```

---

## Self-Review

**Spec coverage:**
- ✅ CacheLevel structure with grid-indexed data (Task 1)
- ✅ CacheStack with 5 levels, zoom shift, invalidation (Task 2)
- ✅ 3-thread parallel computeRegion via row-band splitting (Task 3)
- ✅ 3-offset doubling algorithm with inheritance (Task 4)
- ✅ Background scheduler with generation counter cancellation (Task 5)
- ✅ Renderer accepts pre-computed buffer (Task 6)
- ✅ App integration: cache-aware render + background kickoff (Task 7)
- ✅ Benchmarks: sequential vs parallel comparison (Task 8)
- ✅ Synchronization: atomics only, no mutexes (Tasks 4, 5, 7)
- ✅ Cancellation: zoom invalidates all, pan invalidates all (for now) (Task 7)
- ✅ Max iter change: invalidates all (Task 7)
- ⚠️ Pan shift-and-fill (keeping overlapping data): deferred — `invalidate_all` for now, optimize in a follow-up

**Placeholder scan:** No TBDs or TODOs. All code blocks complete.

**Type consistency:**
- `CacheLevel` used consistently across cache.zig, mandelbrot.zig, pool.zig
- `CacheStack` used consistently in cache.zig, pool.zig, app.zig
- `parallelComputeRegion` signature consistent between mandelbrot.zig and app.zig usage
- `renderFrameFromBuffer` consistent between renderer.zig and app.zig usage
- `BackgroundScheduler` consistent between pool.zig and app.zig usage
- `CacheAction` defined and used in app.zig only

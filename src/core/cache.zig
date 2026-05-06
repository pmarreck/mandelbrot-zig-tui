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

    /// Get the complex-plane coordinate for a grid cell (grid-vertex model).
    /// Uses vertex semantics (no half-step offset) so that doubling inheritance
    /// works: child(col*2, row*2) = parent(col, row) when child.step = parent.step / 2
    /// and both share the same origin. This matches the progressive-prerender spec's
    /// requirement that "Points at even indices in Level N+1 are identical to Level N".
    pub fn pointAt(self: CacheLevel, col: u32, row: u32) ComplexPoint {
        return .{
            .re = self.origin_re + @as(f128, @floatFromInt(col)) * self.step_re,
            .im = self.origin_im + @as(f128, @floatFromInt(row)) * self.step_im,
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
    /// by origin, step sizes, and dimensions.
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

    /// Copy data from parent level into even-indexed positions of this level.
    /// Parent at WxH, self at 2Wx2H. parent[col,row] → self[col*2, row*2].
    /// Used by the 2x doubling step before computing the 3 offset patterns.
    pub fn inheritFromParent(self: *CacheLevel, parent: CacheLevel) void {
        var row: u32 = 0;
        while (row < parent.height) : (row += 1) {
            var col: u32 = 0;
            while (col < parent.width) : (col += 1) {
                self.set(col * 2, row * 2, parent.get(col, row));
            }
        }
    }
};

/// Number of resolution levels in the cache stack. Level 0 is display
/// resolution; each subsequent level doubles the per-axis sample density
/// (Level N has 2^N × the per-axis density of Level 0).
///
/// We cap at 3 levels (0 = 1×, 1 = 2×, 2 = 4×) so the same per-mode budget
/// works for kitty graphics, which renders at native cell-pixel resolution
/// (Level 2 in kitty mode at an 80×24 terminal with 8×16 cells is already
/// ~30 MB; deeper levels would push memory pressure for marginal benefit).
/// Level 1 is what makes a 2× zoom-in into ANY cursor position cache-hit
/// instantly (see findCoveringLevel); Level 2 covers 4× zoom-in but the
/// UI doesn't expose that as a single action.
pub const NUM_LEVELS: u8 = 3;

pub const CacheStack = struct {
    levels: [NUM_LEVELS]?CacheLevel,

    pub fn init() CacheStack {
        return .{ .levels = @splat(null) };
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
    /// Clears any existing levels first.
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
    /// A level "needs computation" if it's null OR exists but !complete.
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

    pub const Coverage = struct {
        level_idx: u8,
        col_offset: u32,
        row_offset: u32,
    };

    /// Find a complete cache level whose grid step matches the requested
    /// viewport AND whose bounding box contains the new viewport, returning
    /// the (col, row) offset within that level where extraction should begin.
    ///
    /// This is the "zoom-in prefetch hit" check: when the user zooms in 2×
    /// at any cursor position, the new viewport's step is bit-exactly half
    /// the current Level 0 step, which equals Level 1's step. If Level 1
    /// is complete and contains the new viewport's bbox, we can extract a
    /// W×H sub-grid in O(W*H) memory bandwidth instead of running the full
    /// escape-time loop.
    ///
    /// Step-match uses bit-exact f128 equality — both quantities derive
    /// from the same arithmetic chain (initial range/W, repeatedly halved
    /// by power-of-2 zoom factors), so they're bit-identical when alignment
    /// holds. A non-power-of-2 zoom (e.g., 1.5×) produces a step that
    /// won't match any cached level, falling through to fresh compute.
    pub fn findCoveringLevel(
        self: CacheStack,
        new_origin_re: f128,
        new_origin_im: f128,
        new_step_re: f128,
        new_step_im: f128,
        new_width: u32,
        new_height: u32,
        new_max_iter: u32,
    ) ?Coverage {
        // Skip Level 0 — caller's exact-match path already covered it.
        var i: u8 = 1;
        while (i < NUM_LEVELS) : (i += 1) {
            const level = self.levels[i] orelse continue;
            if (!level.complete) continue;
            // max_iter is intentionally NOT required to match. Rationale:
            //   - For escaping points (iter < level.max_iter), the smooth
            //     iteration value is independent of max_iter — always
            //     correct to copy.
            //   - level.max_iter > new_max_iter: cached data has MORE
            //     accurate INTERIOR detection; fully correct.
            //   - level.max_iter < new_max_iter: some points marked
            //     INTERIOR in the cache might actually escape between
            //     level.max_iter and new_max_iter. They render as black
            //     instead of palette color — a small "halo" near the set
            //     boundary, bounded by the max_iter delta (typically 50
            //     per 2× zoom step from adaptiveMaxIter).
            // If the strict check were left in, prefetch would NEVER fire
            // on zoom-in: adaptiveMaxIter bumps max_iter on every 2× zoom,
            // so Level 1 (built at the previous viewport's max_iter) is
            // always 50 short of what the new viewport requests.
            _ = new_max_iter;  // accepted; not used for rejection
            if (level.step_re != new_step_re or level.step_im != new_step_im) continue;

            // Compute integer offsets, allowing a tiny epsilon for the
            // f128 → integer conversion. Subtraction of nearby f128 values
            // is exact when one is derived from the other by adding integer
            // multiples of step (which is our usage), so the divisions
            // should land on exact integers.
            const off_re_f = (new_origin_re - level.origin_re) / level.step_re;
            const off_im_f = (new_origin_im - level.origin_im) / level.step_im;
            const off_re_round = @round(off_re_f);
            const off_im_round = @round(off_im_f);
            // Tolerance: 1e-9 of a step — much smaller than any pixel-scale
            // alignment error we'd need to detect.
            if (@abs(off_re_f - off_re_round) > 1e-9) continue;
            if (@abs(off_im_f - off_im_round) > 1e-9) continue;
            if (off_re_round < 0 or off_im_round < 0) continue;

            const col_off: u32 = @intFromFloat(off_re_round);
            const row_off: u32 = @intFromFloat(off_im_round);
            // Bounds: extracted sub-grid must fit entirely within this level.
            if (col_off + new_width > level.width) continue;
            if (row_off + new_height > level.height) continue;

            return Coverage{
                .level_idx = i,
                .col_offset = col_off,
                .row_offset = row_off,
            };
        }
        return null;
    }

    /// Extract a W×H sub-grid from the level at `coverage` into `out`.
    /// Caller is responsible for ensuring `out` has length ≥ width*height
    /// AND that `coverage` came from findCoveringLevel for the same viewport
    /// (so bounds are guaranteed). Row-major destination order, matching
    /// what parallelComputeRegion produces.
    pub fn extractInto(
        self: CacheStack,
        coverage: Coverage,
        out_width: u32,
        out_height: u32,
        out: []f64,
    ) void {
        const level = self.levels[coverage.level_idx].?;
        var r: u32 = 0;
        while (r < out_height) : (r += 1) {
            const src_row = coverage.row_offset + r;
            const src_start = @as(usize, src_row) * @as(usize, level.width) + @as(usize, coverage.col_offset);
            const dst_start = @as(usize, r) * @as(usize, out_width);
            @memcpy(out[dst_start .. dst_start + out_width], level.data[src_start .. src_start + out_width]);
        }
    }
};

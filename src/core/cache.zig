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
};

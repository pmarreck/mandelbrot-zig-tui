// src/core/animation.zig
// Pure computation and config validation for animated zoom.
// Zero I/O, zero threading — easy to unit-test.

const std = @import("std");

/// Raw CLI flag values before validation/defaults are applied.
/// All optional — validate() fills in defaults and resolves direction.
pub const RawAnimationFlags = struct {
	animate: bool = false,
	zoom_from: ?f128 = null,
	zoom_to: ?f128 = null,
	duration_sec: ?f64 = null,
	fps: ?u32 = null,
	focal_re: ?f128 = null,
	focal_im: ?f128 = null,
	start_center_re: ?f128 = null,
	start_center_im: ?f128 = null,
	end_center_re: ?f128 = null,
	end_center_im: ?f128 = null,
	exit_after: bool = false,
	hold_ms: ?u64 = null,
	base_iter: u32 = 256,
};

/// Fully resolved animation configuration after validation.
pub const AnimationConfig = struct {
	fps: u32,
	num_frames: u32,
	start_center_re: f128,
	start_center_im: f128,
	end_center_re: f128,
	end_center_im: f128,
	start_zoom: f128,
	end_zoom: f128,
	base_iter: u32,
	hold_ms: u64,
	exit_after: bool,
};

/// Per-frame viewport parameters derived from AnimationConfig + frame index.
pub const AnimationFrame = struct {
	center_re: f128,
	center_im: f128,
	zoom: f128,
	max_iter: u32,
};

pub const ValidationError = error{
	MissingDuration,
	ZoomFromEqualsTo,
	HoldWithoutExit,
	BadFps,
	BadDuration,
	AnimationFlagsWithoutAnimate,
};

/// Default viewport center (the standard Mandelbrot presentation).
const DEFAULT_CENTER_RE: f128 = -0.5;
const DEFAULT_CENTER_IM: f128 = 0.0;

/// Pure: compute frame params for frame_idx in [0, num_frames).
/// Uses linear interpolation for center, log interpolation for zoom.
pub fn frameAt(cfg: AnimationConfig, frame_idx: u32) AnimationFrame {
	const t: f64 = if (cfg.num_frames > 1)
		@as(f64, @floatFromInt(frame_idx)) / @as(f64, @floatFromInt(cfg.num_frames - 1))
	else
		1.0;

	const t_f128: f128 = @floatCast(t);

	const center_re = cfg.start_center_re + t_f128 * (cfg.end_center_re - cfg.start_center_re);
	const center_im = cfg.start_center_im + t_f128 * (cfg.end_center_im - cfg.start_center_im);

	// zoom = start_zoom * (end_zoom / start_zoom) ^ t
	// Compute in f64 then cast back — log/pow don't have f128 hardware support
	const start_f64: f64 = @floatCast(cfg.start_zoom);
	const end_f64: f64 = @floatCast(cfg.end_zoom);
	const zoom_f64 = start_f64 * std.math.pow(f64, end_f64 / start_f64, t);
	const zoom: f128 = @floatCast(zoom_f64);

	// Adaptive max iterations based on zoom depth
	const max_iter = adaptiveMaxIter(zoom, cfg.base_iter);

	return .{
		.center_re = center_re,
		.center_im = center_im,
		.zoom = zoom,
		.max_iter = max_iter,
	};
}

/// Mirrors viewport.adaptiveMaxIter; duplicated here to keep animation.zig
/// free of a viewport dependency. Pure function, same formula.
fn adaptiveMaxIter(zoom: f128, base: u32) u32 {
	if (zoom <= 1.0) return base;
	const zoom_f64: f64 = @floatCast(zoom);
	const extra: f64 = 50.0 * @log2(zoom_f64);
	const total = @as(u64, base) + @as(u64, @intFromFloat(@max(0.0, extra)));
	return @intCast(@min(total, 100_000));
}

/// Validate raw flags and resolve defaults. Returns a fully-resolved
/// AnimationConfig or a ValidationError. Pure — no I/O.
pub fn validate(raw: RawAnimationFlags) ValidationError!AnimationConfig {
	if (!raw.animate) {
		return ValidationError.AnimationFlagsWithoutAnimate;
	}

	// --hold-ms requires --exit-after
	if (raw.hold_ms != null and !raw.exit_after) {
		return ValidationError.HoldWithoutExit;
	}

	const duration_sec = raw.duration_sec orelse return ValidationError.MissingDuration;
	if (duration_sec <= 0) return ValidationError.BadDuration;

	const fps = raw.fps orelse 30;
	if (fps == 0) return ValidationError.BadFps;

	const zoom_from = raw.zoom_from orelse 1.0;
	const zoom_to = raw.zoom_to orelse 1.0;
	if (zoom_from == zoom_to) return ValidationError.ZoomFromEqualsTo;

	const focal_re = raw.focal_re orelse DEFAULT_CENTER_RE;
	const focal_im = raw.focal_im orelse DEFAULT_CENTER_IM;

	// Resolve start/end centers based on zoom direction + explicit overrides
	const zoom_in = zoom_from < zoom_to;
	const implicit_start_re: f128 = if (zoom_in) DEFAULT_CENTER_RE else focal_re;
	const implicit_start_im: f128 = if (zoom_in) DEFAULT_CENTER_IM else focal_im;
	const implicit_end_re: f128 = if (zoom_in) focal_re else DEFAULT_CENTER_RE;
	const implicit_end_im: f128 = if (zoom_in) focal_im else DEFAULT_CENTER_IM;

	const start_center_re = raw.start_center_re orelse implicit_start_re;
	const start_center_im = raw.start_center_im orelse implicit_start_im;
	const end_center_re = raw.end_center_re orelse implicit_end_re;
	const end_center_im = raw.end_center_im orelse implicit_end_im;

	// Compute num_frames (round-half-up)
	const raw_frames = duration_sec * @as(f64, @floatFromInt(fps));
	const num_frames_raw: u32 = @intFromFloat(@floor(raw_frames + 0.5));
	const num_frames_clamped: u32 = if (num_frames_raw < 1) 1 else num_frames_raw;

	return .{
		.fps = fps,
		.num_frames = num_frames_clamped,
		.start_center_re = start_center_re,
		.start_center_im = start_center_im,
		.end_center_re = end_center_re,
		.end_center_im = end_center_im,
		.start_zoom = zoom_from,
		.end_zoom = zoom_to,
		.base_iter = raw.base_iter,
		.hold_ms = raw.hold_ms orelse 0,
		.exit_after = raw.exit_after,
	};
}

const std = @import("std");
const testing = std.testing;
const animation = @import("animation");

fn mkConfig(start_zoom: f128, end_zoom: f128, num_frames: u32) animation.AnimationConfig {
	return .{
		.fps = 30,
		.num_frames = num_frames,
		.start_center_re = 0.0,
		.start_center_im = 0.0,
		.end_center_re = 1.0,
		.end_center_im = 2.0,
		.start_zoom = start_zoom,
		.end_zoom = end_zoom,
		.base_iter = 256,
		.hold_ms = 0,
		.exit_after = false,
	};
}

// ── frameAt tests ──────────────────────────────────────────────────

test "frameAt at frame 0 returns exact start values" {
	const cfg = mkConfig(1.0, 1000.0, 10);
	const f = animation.frameAt(cfg, 0);
	try testing.expectEqual(@as(f128, 0.0), f.center_re);
	try testing.expectEqual(@as(f128, 0.0), f.center_im);
	try testing.expectEqual(@as(f128, 1.0), f.zoom);
}

test "frameAt at last frame returns exact end values" {
	const cfg = mkConfig(1.0, 1000.0, 10);
	const f = animation.frameAt(cfg, 9);
	try testing.expectEqual(@as(f128, 1.0), f.center_re);
	try testing.expectEqual(@as(f128, 2.0), f.center_im);
	try testing.expectEqual(@as(f128, 1000.0), f.zoom);
}

test "frameAt zoom interpolation is geometric at midpoint" {
	const cfg = mkConfig(1.0, 10000.0, 11);
	const f = animation.frameAt(cfg, 5);
	// At t=0.5, zoom == sqrt(start * end) == sqrt(10000) == 100
	const zoom_f64: f64 = @floatCast(f.zoom);
	try testing.expectApproxEqAbs(@as(f64, 100.0), zoom_f64, 0.001);
}

test "frameAt center interpolation is linear at midpoint" {
	const cfg = mkConfig(1.0, 1000.0, 11);
	const f = animation.frameAt(cfg, 5);
	const re_f64: f64 = @floatCast(f.center_re);
	const im_f64: f64 = @floatCast(f.center_im);
	try testing.expectApproxEqAbs(@as(f64, 0.5), re_f64, 1e-9);
	try testing.expectApproxEqAbs(@as(f64, 1.0), im_f64, 1e-9);
}

test "frameAt with num_frames=1 returns end values" {
	const cfg = mkConfig(1.0, 1000.0, 1);
	const f = animation.frameAt(cfg, 0);
	try testing.expectEqual(@as(f128, 1.0), f.center_re);
	try testing.expectEqual(@as(f128, 1000.0), f.zoom);
}

// ── validate() tests ───────────────────────────────────────────────

test "validate missing duration returns MissingDuration" {
	const raw = animation.RawAnimationFlags{
		.animate = true,
		.zoom_to = 2.0,
	};
	try testing.expectError(animation.ValidationError.MissingDuration, animation.validate(raw));
}

test "validate zoom_from == zoom_to returns ZoomFromEqualsTo" {
	const raw = animation.RawAnimationFlags{
		.animate = true,
		.duration_sec = 1.0,
		.zoom_from = 1.0,
		.zoom_to = 1.0,
	};
	try testing.expectError(animation.ValidationError.ZoomFromEqualsTo, animation.validate(raw));
}

test "validate hold_ms without exit_after returns HoldWithoutExit" {
	const raw = animation.RawAnimationFlags{
		.animate = true,
		.duration_sec = 1.0,
		.zoom_to = 2.0,
		.hold_ms = 100,
		.exit_after = false,
	};
	try testing.expectError(animation.ValidationError.HoldWithoutExit, animation.validate(raw));
}

test "validate bad fps (zero) returns BadFps" {
	const raw = animation.RawAnimationFlags{
		.animate = true,
		.duration_sec = 1.0,
		.zoom_to = 2.0,
		.fps = 0,
	};
	try testing.expectError(animation.ValidationError.BadFps, animation.validate(raw));
}

test "validate bad duration (zero) returns BadDuration" {
	const raw = animation.RawAnimationFlags{
		.animate = true,
		.duration_sec = 0.0,
		.zoom_to = 2.0,
	};
	try testing.expectError(animation.ValidationError.BadDuration, animation.validate(raw));
}

test "validate zoom-in defaults: start_center = (-0.5, 0), end_center = focal" {
	const raw = animation.RawAnimationFlags{
		.animate = true,
		.duration_sec = 1.0,
		.zoom_from = 1.0,
		.zoom_to = 100.0,
		.focal_re = -0.7435,
		.focal_im = 0.1314,
	};
	const cfg = try animation.validate(raw);
	try testing.expectEqual(@as(f128, -0.5), cfg.start_center_re);
	try testing.expectEqual(@as(f128, 0.0), cfg.start_center_im);
	try testing.expectEqual(@as(f128, -0.7435), cfg.end_center_re);
	try testing.expectEqual(@as(f128, 0.1314), cfg.end_center_im);
}

test "validate zoom-out defaults: start_center = focal, end_center = (-0.5, 0)" {
	const raw = animation.RawAnimationFlags{
		.animate = true,
		.duration_sec = 1.0,
		.zoom_from = 100.0,
		.zoom_to = 1.0,
		.focal_re = -0.7435,
		.focal_im = 0.1314,
	};
	const cfg = try animation.validate(raw);
	try testing.expectEqual(@as(f128, -0.7435), cfg.start_center_re);
	try testing.expectEqual(@as(f128, 0.1314), cfg.start_center_im);
	try testing.expectEqual(@as(f128, -0.5), cfg.end_center_re);
	try testing.expectEqual(@as(f128, 0.0), cfg.end_center_im);
}

test "validate explicit start/end center overrides win over defaults" {
	const raw = animation.RawAnimationFlags{
		.animate = true,
		.duration_sec = 1.0,
		.zoom_to = 100.0,
		.focal_re = -0.7435,
		.focal_im = 0.1314,
		.start_center_re = 0.1,
		.start_center_im = 0.2,
		.end_center_re = 0.3,
		.end_center_im = 0.4,
	};
	const cfg = try animation.validate(raw);
	try testing.expectEqual(@as(f128, 0.1), cfg.start_center_re);
	try testing.expectEqual(@as(f128, 0.2), cfg.start_center_im);
	try testing.expectEqual(@as(f128, 0.3), cfg.end_center_re);
	try testing.expectEqual(@as(f128, 0.4), cfg.end_center_im);
}

test "validate: animation flags without --animate returns error" {
	const raw = animation.RawAnimationFlags{
		.animate = false,
		.zoom_to = 2.0,
	};
	try testing.expectError(animation.ValidationError.AnimationFlagsWithoutAnimate, animation.validate(raw));
}

test "validate num_frames = round(fps * duration)" {
	const raw = animation.RawAnimationFlags{
		.animate = true,
		.duration_sec = 2.0,
		.fps = 30,
		.zoom_to = 100.0,
	};
	const cfg = try animation.validate(raw);
	try testing.expectEqual(@as(u32, 60), cfg.num_frames);
}

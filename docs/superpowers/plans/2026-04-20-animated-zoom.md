# Animated Zoom Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a recordable/scriptable animation mode that renders a smooth zoom (in or out) between a default viewport and a focal point, with configurable duration, fps, hold time, and exit behavior.

**Architecture:** New `src/core/animation.zig` module with pure CLI validation + frame interpolation (linear center, logarithmic zoom). Extract existing render step in `app.zig::run()` into a reusable `renderOneFrame` helper shared by interactive mode and new `runAnimation` loop. Animation frames go through the same cache/scheduler/glyph-mode path as interactive frames — single code path.

**Tech Stack:** Zig 0.15.2. Reuses existing threading, cache, renderer, scheduler, coloring infrastructure.

**Spec:** `docs/superpowers/specs/2026-04-20-animated-zoom-design.md`

**IMPORTANT Zig 0.15 notes:**
- `std.Thread.sleep(nanoseconds)` — blocks current thread
- `std.time.nanoTimestamp()` returns `i128`
- `std.math.pow(f64, base, exp)` for `x^y`
- `std.fmt.parseFloat(f64, str)` for CLI arg parsing; `std.fmt.parseInt(T, str, 10)` for ints
- Multiline string literals with `\\` prefix for help text
- `std.fs.File.stderr().writer(&buf)` → `&stderr_writer.interface`

---

## File Structure

```
src/
  core/
    animation.zig       — NEW: pure frame math + config validation
  tui/
    app.zig             — MODIFY: extract renderOneFrame, add runAnimation
  main.zig              — MODIFY: parse animation + general CLI flags; dispatch to animation or interactive
tests/
  unit/
    test_animation.zig  — NEW: pure-function tests (frameAt, validate)
  cli/
    test_cli.bash       — MODIFY: add 3 animation CLI tests
build.zig               — MODIFY: add animation_mod + test target; wire into app/main imports
README.md               — MODIFY: document animation flags with example
```

---

### Task 1: `animation.zig` — Types, Validation, and Frame Math

**Files:**
- Create: `src/core/animation.zig`
- Create: `tests/unit/test_animation.zig`
- Modify: `build.zig` (add module + test target)

- [ ] **Step 1: Write failing tests for `frameAt`**

Create `tests/unit/test_animation.zig`:

```zig
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
	// 11 frames: t ranges 0 .. 1 with step 0.1; midpoint frame_idx=5 gives t=0.5
	const cfg = mkConfig(1.0, 10000.0, 11);
	const f = animation.frameAt(cfg, 5);
	// At t=0.5, zoom == sqrt(start * end) == sqrt(10000) == 100
	const zoom_f64: f64 = @floatCast(f.zoom);
	try testing.expectApproxEqAbs(@as(f64, 100.0), zoom_f64, 0.001);
}

test "frameAt center interpolation is linear at midpoint" {
	const cfg = mkConfig(1.0, 1000.0, 11);
	const f = animation.frameAt(cfg, 5);
	// At t=0.5, center_re == midpoint == 0.5, center_im == 1.0
	const re_f64: f64 = @floatCast(f.center_re);
	const im_f64: f64 = @floatCast(f.center_im);
	try testing.expectApproxEqAbs(@as(f64, 0.5), re_f64, 1e-9);
	try testing.expectApproxEqAbs(@as(f64, 1.0), im_f64, 1e-9);
}

test "frameAt with num_frames=1 returns end values" {
	// Edge case: single-frame animation
	const cfg = mkConfig(1.0, 1000.0, 1);
	const f = animation.frameAt(cfg, 0);
	try testing.expectEqual(@as(f128, 1.0), f.center_re);
	try testing.expectEqual(@as(f128, 1000.0), f.zoom);
}
```

- [ ] **Step 2: Add `animation_mod` to `build.zig`**

Near the top of `build.zig`, after the existing module definitions (after `cache_mod` or similar), add:

```zig
    const animation_mod = b.createModule(.{
        .root_source_file = b.path("src/core/animation.zig"),
    });
```

Add a new test target right before the closing `}` of `pub fn build`. Find the `parallel_tests` block and add after it:

```zig
    const animation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_animation.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "animation", .module = animation_mod },
            },
        }),
    });
    const run_animation_tests = b.addRunArtifact(animation_tests);
    test_step.dependOn(&run_animation_tests.step);
```

- [ ] **Step 3: Run tests — should fail**

```bash
nix develop -c zig build test -Doptimize=Debug
```

Expected: compile errors — `animation.AnimationConfig`, `animation.frameAt` don't exist.

- [ ] **Step 4: Create `src/core/animation.zig` with types + `frameAt`**

```zig
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

	// Adaptive max iterations based on zoom depth (matches viewport.adaptiveMaxIter formula).
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
	// If --animate is off, any animation flag being present is an error.
	if (!raw.animate) {
		if (raw.zoom_from != null or raw.zoom_to != null or
			raw.duration_sec != null or raw.fps != null or
			raw.start_center_re != null or raw.start_center_im != null or
			raw.end_center_re != null or raw.end_center_im != null or
			raw.exit_after or raw.hold_ms != null)
		{
			return ValidationError.AnimationFlagsWithoutAnimate;
		}
		// Caller must check .animate separately — returning an error from the
		// non-animate path doesn't fit the contract. But the checks above only
		// fire if raw.animate == false AND some animation flag is set.
		// If nothing is set, we still need to return *something* — but caller
		// should never call validate() without raw.animate == true.
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
	const num_frames: u32 = @intFromFloat(@floor(raw_frames + 0.5));
	// Clamp to at least 1 frame
	const num_frames_clamped = if (num_frames < 1) 1 else num_frames;

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
```

- [ ] **Step 5: Run tests — should pass**

```bash
nix develop -c zig build test -Doptimize=Debug
```

All 5 frameAt tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/core/animation.zig tests/unit/test_animation.zig build.zig
git commit -m "feat: animation.zig — pure frame math + config types"
```

Do NOT include Co-Authored-By lines.

---

### Task 2: `animation.validate()` Tests

**Files:**
- Modify: `tests/unit/test_animation.zig`

The validate() function is already implemented from Task 1. This task adds its test coverage.

- [ ] **Step 1: Append validation tests to `tests/unit/test_animation.zig`**

```zig
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
```

- [ ] **Step 2: Run tests — should pass**

```bash
nix develop -c zig build test -Doptimize=Debug
```

All 10 validate tests + 5 frameAt tests pass.

- [ ] **Step 3: Commit**

```bash
git add tests/unit/test_animation.zig
git commit -m "test: animation.validate() — all error paths + default resolution"
```

---

### Task 3: Extract `renderOneFrame` from `app.zig`

**Files:**
- Modify: `src/tui/app.zig`

Pure refactor — extract the current render block inside `run()` into a reusable helper. Same behavior.

- [ ] **Step 1: Add `renderOneFrame` function to `src/tui/app.zig`**

In `src/tui/app.zig`, after the existing `run()` function but before `processEvent`, add:

```zig
/// Render a single frame using the current state. Shared between interactive
/// mode and animation mode. Handles cache lookup, parallel compute on miss,
/// dispatch to density/blocks renderer, writeAll, flush, and kick scheduler.
pub fn renderOneFrame(
	state: *AppState,
	cache_stack: *cache_mod.CacheStack,
	scheduler: *pool.BackgroundScheduler,
	allocator: std.mem.Allocator,
	stdout: *std.Io.Writer,
) !void {
	const render_height: u16 = if (state.show_info and state.term_height > 1)
		state.term_height - 1
	else
		state.term_height;

	// Sub-pixel multiplier: 1 for density mode, 2 for blocks mode
	const sub_mul: u16 = switch (state.glyph_mode) {
		.density => 1,
		.blocks => 2,
	};
	const buf_width: u16 = state.term_width * sub_mul;
	const buf_height: u16 = render_height * sub_mul;
	const pixel_count = @as(usize, buf_width) * @as(usize, buf_height);

	const iter_buf = try allocator.alloc(f64, pixel_count);
	defer allocator.free(iter_buf);

	// Check cache Level 0 first
	var cache_hit = false;
	if (cache_stack.levels[0]) |level| {
		if (level.complete and level.width == buf_width and level.height == buf_height) {
			@memcpy(iter_buf, level.data[0..pixel_count]);
			cache_hit = true;
		}
	}

	if (!cache_hit) {
		scheduler.stop();
		cache_stack.invalidateAll(allocator);

		try cache_stack.initForViewport(
			allocator,
			state.center_re,
			state.center_im,
			state.zoom,
			buf_width,
			buf_height,
			state.max_iter,
			ASPECT_RATIO,
		);

		try mandelbrot.parallelComputeRegion(.{
			.center_re = state.center_re,
			.center_im = state.center_im,
			.zoom = state.zoom,
			.width = buf_width,
			.height = buf_height,
			.max_iter = state.max_iter,
			.aspect_ratio = ASPECT_RATIO,
		}, iter_buf, null);

		if (cache_stack.levels[0]) |*level| {
			@memcpy(level.data, iter_buf);
			level.complete = true;
		}
	}

	const render_state = renderer.RenderState{
		.center_re = state.center_re,
		.center_im = state.center_im,
		.zoom = state.zoom,
		.max_iter = state.max_iter,
		.show_info = state.show_info,
		.glyph_mode = state.glyph_mode,
	};

	const frame = switch (state.glyph_mode) {
		.density => try renderer.renderFrameFromBuffer(render_state, state.term_width, state.term_height, iter_buf, allocator),
		.blocks => try renderer.renderFrameFromBlocksBuffer(render_state, state.term_width, state.term_height, iter_buf, allocator),
	};
	defer allocator.free(frame);

	try stdout.writeAll(frame);
	try stdout.flush();
	state.needs_redraw = false;

	scheduler.requestWork();
}
```

- [ ] **Step 2: Replace the existing render block in `run()` with a call to `renderOneFrame`**

In `src/tui/app.zig`, find the `if (state.needs_redraw) { ... }` block inside `run()`. The entire block (from `const render_height: u16 = ...` through `scheduler.requestWork();`) should be replaced with:

```zig
		if (state.needs_redraw) {
			try renderOneFrame(&state, &cache_stack, &scheduler, allocator, stdout);
		}
```

- [ ] **Step 3: Run tests — should pass (no behavior change)**

```bash
nix develop -c zig build test -Doptimize=Debug
```

All existing tests pass.

Also verify interactive mode still works via smoke test:
```bash
./build
./zig-out/bin/mandelbrot --single-frame 2>/dev/null | head -3
```

Should render as before.

- [ ] **Step 4: Commit**

```bash
git add src/tui/app.zig
git commit -m "refactor: extract renderOneFrame from run() for animation reuse"
```

---

### Task 4: `runAnimation` in `app.zig`

**Files:**
- Modify: `src/tui/app.zig`
- Modify: `build.zig` (wire animation_mod into app_mod)

- [ ] **Step 1: Add `animation` to `app_mod` imports in `build.zig`**

Find `app_mod`'s `.imports = &.{ ... }` in `build.zig`. Add `.{ .name = "animation", .module = animation_mod },` to the list.

Also add `animation` to the `app_tests` target's imports (the test that compiles app.zig's inline tests):

```zig
    const app_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui/app.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                // ... existing imports ...
                .{ .name = "animation", .module = animation_mod },
            },
        }),
    });
```

- [ ] **Step 2: Add `animation` import to `src/tui/app.zig`**

At the top of `src/tui/app.zig`, add:

```zig
const animation = @import("animation");
```

- [ ] **Step 3: Implement `runAnimation`**

Add AFTER the existing `run` function (and before `renderOneFrame` if that's where it ended up, or after):

```zig
/// Animation mode: render `config.num_frames` progressive zoom frames,
/// pace to target fps, then either exit or fall through to interactive mode.
/// Reuses renderOneFrame for each frame so density/blocks/cache/scheduler all work.
pub fn runAnimation(
	config: animation.AnimationConfig,
	initial_state: AppState,
	allocator: std.mem.Allocator,
) !void {
	var state = initial_state;

	// Cache + scheduler owned here (same as run())
	var cache_stack = cache_mod.CacheStack.init();
	defer cache_stack.deinit(allocator);

	var scheduler = pool.BackgroundScheduler.init(allocator, &cache_stack);
	defer scheduler.stop();

	const stdout_file = std.fs.File.stdout();

	try terminal.enterRawMode();
	errdefer terminal.exitRawMode();

	var stdout_buf: [16384]u8 = undefined;
	var stdout_writer = stdout_file.writer(&stdout_buf);
	const stdout = &stdout_writer.interface;

	try terminal.hideCursor(stdout);
	try terminal.enableMouseTracking(stdout);
	try terminal.clearScreen(stdout);
	try stdout.flush();

	terminal.setupSigwinch();

	// Animation loop
	const target_frame_ns: u64 = 1_000_000_000 / config.fps;

	var stderr_buf: [4096]u8 = undefined;
	var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
	const stderr = &stderr_writer.interface;

	// Frame timing stats
	var total_elapsed_ns: u64 = 0;
	var min_frame_ns: u64 = std.math.maxInt(u64);
	var max_frame_ns: u64 = 0;
	var overrun_count: u32 = 0;

	const overall_start = std.time.nanoTimestamp();

	var frame_idx: u32 = 0;
	while (frame_idx < config.num_frames) : (frame_idx += 1) {
		const frame_start = std.time.nanoTimestamp();

		const params = animation.frameAt(config, frame_idx);
		state.center_re = params.center_re;
		state.center_im = params.center_im;
		state.zoom = params.zoom;
		state.max_iter = params.max_iter;
		state.needs_redraw = true;

		try renderOneFrame(&state, &cache_stack, &scheduler, allocator, stdout);

		const elapsed_ns: i128 = std.time.nanoTimestamp() - frame_start;
		const elapsed_u64: u64 = if (elapsed_ns > 0) @intCast(elapsed_ns) else 0;
		total_elapsed_ns += elapsed_u64;
		if (elapsed_u64 < min_frame_ns) min_frame_ns = elapsed_u64;
		if (elapsed_u64 > max_frame_ns) max_frame_ns = elapsed_u64;

		const target_ns: i128 = @intCast(target_frame_ns);
		if (elapsed_ns < target_ns) {
			std.Thread.sleep(@intCast(target_ns - elapsed_ns));
		} else {
			overrun_count += 1;
		}
	}

	const overall_elapsed: i128 = std.time.nanoTimestamp() - overall_start;
	const overall_elapsed_sec: f64 = @as(f64, @floatFromInt(@as(u64, @intCast(overall_elapsed)))) / 1_000_000_000.0;
	const target_duration_sec: f64 = @as(f64, @floatFromInt(config.num_frames)) / @as(f64, @floatFromInt(config.fps));
	const mean_frame_ms: f64 = @as(f64, @floatFromInt(total_elapsed_ns)) / @as(f64, @floatFromInt(config.num_frames)) / 1_000_000.0;
	const min_frame_ms: f64 = @as(f64, @floatFromInt(min_frame_ns)) / 1_000_000.0;
	const max_frame_ms: f64 = @as(f64, @floatFromInt(max_frame_ns)) / 1_000_000.0;
	const target_frame_ms: f64 = @as(f64, @floatFromInt(target_frame_ns)) / 1_000_000.0;
	const overrun_pct: f64 = @as(f64, @floatFromInt(overrun_count)) / @as(f64, @floatFromInt(config.num_frames)) * 100.0;

	try stderr.print("Animation complete: {d} frames in {d:.2}s (target {d:.2}s, {d} fps)\n", .{
		config.num_frames, overall_elapsed_sec, target_duration_sec, config.fps,
	});
	try stderr.print("  Min: {d:.1} ms   Max: {d:.1} ms   Mean: {d:.1} ms\n", .{
		min_frame_ms, max_frame_ms, mean_frame_ms,
	});
	try stderr.print("  ≥ target ({d:.1} ms): {d} frames ({d:.0}%)\n", .{
		target_frame_ms, overrun_count, overrun_pct,
	});
	try stderr.flush();

	// Hold on final frame if requested
	if (config.exit_after and config.hold_ms > 0) {
		std.Thread.sleep(config.hold_ms * std.time.ns_per_ms);
	}

	if (config.exit_after) {
		// Cleanup and exit
		try terminal.disableMouseTracking(stdout);
		try terminal.showCursor(stdout);
		try terminal.clearScreen(stdout);
		try stdout.flush();
		terminal.exitRawMode();
		return;
	}

	// Fall through to interactive event loop using the final state.
	// Terminal is already in raw mode; hand off to the main loop.
	// We can't just call run() because it duplicates terminal setup.
	// Instead, inline the interactive event loop here using the same state/cache/scheduler.
	var read_buf: [256]u8 = undefined;
	const stdin_file = std.fs.File.stdin();

	while (state.running) {
		if (terminal.checkAndClearResizeFlag()) {
			if (terminal.getTermSizePosix()) |size| {
				state.term_width = size.cols;
				state.term_height = size.rows;
				state.needs_redraw = true;
				scheduler.stop();
				cache_stack.invalidateAll(allocator);
			} else |_| {}
		}

		if (state.needs_redraw) {
			try renderOneFrame(&state, &cache_stack, &scheduler, allocator, stdout);
		}

		const n = stdin_file.read(&read_buf) catch 0;
		if (n == 0) continue;

		const event = input.parseEvent(read_buf[0..n]);
		const new_state = processEvent(state, event);

		if (viewportChanged(state, new_state)) {
			scheduler.stop();
			cache_stack.invalidateAll(allocator);
		}
		state = new_state;
	}

	try terminal.disableMouseTracking(stdout);
	try terminal.showCursor(stdout);
	try terminal.clearScreen(stdout);
	try stdout.flush();
	terminal.exitRawMode();
}
```

- [ ] **Step 4: Verify compilation**

```bash
nix develop -c zig build test -Doptimize=Debug
```

All existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/tui/app.zig build.zig
git commit -m "feat: runAnimation — animation loop with pacing + stats + interactive fallthrough"
```

---

### Task 5: CLI Flag Parsing in `main.zig`

**Files:**
- Modify: `src/main.zig`
- Modify: `build.zig` (add animation import to exe root_module)

- [ ] **Step 1: Add `animation` to exe's imports in `build.zig`**

Find the `exe` target (`b.addExecutable(...)`). Add to its `.imports`:

```zig
.{ .name = "animation", .module = animation_mod },
```

Same for the `unit_tests` target that compiles main.zig.

- [ ] **Step 2: Add `animation` import at top of `src/main.zig`**

```zig
const animation = @import("animation");
```

- [ ] **Step 3: Add helper `parseFlagF128` at file scope in `src/main.zig`**

Near the other parse helpers (`parseF128Env`, `parseU32Env`, etc.), add:

```zig
/// Parse an f128 value from a CLI flag string. Falls back to parsing f64 since
/// Zig 0.15's parseFloat doesn't support f128 directly, then widens to f128.
fn parseFlagF128(val: []const u8) ?f128 {
	const f = std.fmt.parseFloat(f64, val) catch return null;
	return @as(f128, f);
}

fn parseFlagU32(val: []const u8) ?u32 {
	return std.fmt.parseInt(u32, val, 10) catch null;
}

fn parseFlagU64(val: []const u8) ?u64 {
	return std.fmt.parseInt(u64, val, 10) catch null;
}

fn parseFlagU16(val: []const u8) ?u16 {
	return std.fmt.parseInt(u16, val, 10) catch null;
}

fn parseFlagF64(val: []const u8) ?f64 {
	return std.fmt.parseFloat(f64, val) catch null;
}
```

- [ ] **Step 4: Extend CLI parsing to support `--flag=VALUE` and `--flag VALUE` for all new flags**

In `src/main.zig` `main()`, find the existing `while (i < args.len) : (i += 1)` loop. We're adding a LOT of new flag cases. Add a helper inside main() (a local function) to handle both `--name=value` and `--name value` forms:

```zig
	// Helper: if arg starts with prefix ("--flag="), return the value part.
	// Otherwise if arg == prefix without the =, consume the next arg as the value.
	// Returns null if the flag doesn't match.
	const ArgHelper = struct {
		fn match(arg: []const u8, flag_name: []const u8, args_slice: [][:0]u8, idx: *usize) ?[]const u8 {
			// Try --flag=VALUE
			var eq_prefix_buf: [64]u8 = undefined;
			const eq_prefix = std.fmt.bufPrint(&eq_prefix_buf, "{s}=", .{flag_name}) catch return null;
			if (std.mem.startsWith(u8, arg, eq_prefix)) {
				return arg[eq_prefix.len..];
			}
			// Try --flag VALUE (with next arg)
			if (std.mem.eql(u8, arg, flag_name)) {
				if (idx.* + 1 >= args_slice.len) return null;
				idx.* += 1;
				return args_slice[idx.*];
			}
			return null;
		}
	};
```

Then add a `RawAnimationFlags` accumulator and a CLI-override set for the existing env vars:

```zig
	var raw_anim = animation.RawAnimationFlags{};
	var cli_center_re: ?f128 = null;
	var cli_center_im: ?f128 = null;
	var cli_zoom: ?f128 = null;
	var cli_max_iter: ?u32 = null;
	var cli_cols: ?u16 = null;
	var cli_rows: ?u16 = null;
```

Inside the `while` loop, after the existing flag handlers (before the `--bench-quiet` handler or wherever fits cleanly), add the new flag handlers:

```zig
		if (std.mem.eql(u8, arg, "--animate")) {
			raw_anim.animate = true;
			continue;
		}
		if (std.mem.eql(u8, arg, "--exit-after")) {
			raw_anim.exit_after = true;
			continue;
		}
		// Flags that take values
		if (ArgHelper.match(arg, "--zoom-from", args, &i)) |v| {
			raw_anim.zoom_from = parseFlagF128(v) orelse {
				try stderr.writeAll("--zoom-from must be a number\n");
				try stderr.flush();
				return error.BadCliArg;
			};
			continue;
		}
		if (ArgHelper.match(arg, "--zoom-to", args, &i)) |v| {
			raw_anim.zoom_to = parseFlagF128(v) orelse {
				try stderr.writeAll("--zoom-to must be a number\n");
				try stderr.flush();
				return error.BadCliArg;
			};
			continue;
		}
		if (ArgHelper.match(arg, "--duration", args, &i)) |v| {
			raw_anim.duration_sec = parseFlagF64(v) orelse {
				try stderr.writeAll("--duration must be a number in seconds\n");
				try stderr.flush();
				return error.BadCliArg;
			};
			continue;
		}
		if (ArgHelper.match(arg, "--fps", args, &i)) |v| {
			raw_anim.fps = parseFlagU32(v) orelse {
				try stderr.writeAll("--fps must be a positive integer\n");
				try stderr.flush();
				return error.BadCliArg;
			};
			continue;
		}
		if (ArgHelper.match(arg, "--hold-ms", args, &i)) |v| {
			raw_anim.hold_ms = parseFlagU64(v) orelse {
				try stderr.writeAll("--hold-ms must be a non-negative integer\n");
				try stderr.flush();
				return error.BadCliArg;
			};
			continue;
		}
		if (ArgHelper.match(arg, "--start-center-re", args, &i)) |v| {
			raw_anim.start_center_re = parseFlagF128(v);
			continue;
		}
		if (ArgHelper.match(arg, "--start-center-im", args, &i)) |v| {
			raw_anim.start_center_im = parseFlagF128(v);
			continue;
		}
		if (ArgHelper.match(arg, "--end-center-re", args, &i)) |v| {
			raw_anim.end_center_re = parseFlagF128(v);
			continue;
		}
		if (ArgHelper.match(arg, "--end-center-im", args, &i)) |v| {
			raw_anim.end_center_im = parseFlagF128(v);
			continue;
		}
		// General-purpose viewport overrides (usable outside animation too)
		if (ArgHelper.match(arg, "--center-re", args, &i)) |v| {
			cli_center_re = parseFlagF128(v);
			continue;
		}
		if (ArgHelper.match(arg, "--center-im", args, &i)) |v| {
			cli_center_im = parseFlagF128(v);
			continue;
		}
		if (ArgHelper.match(arg, "--zoom", args, &i)) |v| {
			cli_zoom = parseFlagF128(v);
			continue;
		}
		if (ArgHelper.match(arg, "--max-iter", args, &i)) |v| {
			cli_max_iter = parseFlagU32(v);
			continue;
		}
		if (ArgHelper.match(arg, "--cols", args, &i)) |v| {
			cli_cols = parseFlagU16(v);
			continue;
		}
		if (ArgHelper.match(arg, "--rows", args, &i)) |v| {
			cli_rows = parseFlagU16(v);
			continue;
		}
```

After the arg-parsing loop, apply CLI overrides for state (before the existing env var block runs, so CLI wins over env — OR after, then CLI overrides env. Cleaner to do CLI AFTER env var application, so the final precedence is: default < env < CLI):

Find where state is built from env vars (after `state = app.defaultState();` and the `parseF128Env("MANDELBROT_CENTER_RE")` block). After those env-var overrides, add CLI overrides:

```zig
	// CLI flags override env vars
	if (cli_center_re) |v| state.center_re = v;
	if (cli_center_im) |v| state.center_im = v;
	if (cli_zoom) |v| state.zoom = v;
	if (cli_max_iter) |v| {
		state.max_iter = v;
		state.base_iter = v;
	}
	if (cli_cols) |v| state.term_width = v;
	if (cli_rows) |v| state.term_height = v;
```

Populate `raw_anim.focal_re/focal_im/base_iter` from state (so animation picks up env vars / CLI center too):

```zig
	raw_anim.focal_re = state.center_re;
	raw_anim.focal_im = state.center_im;
	raw_anim.base_iter = state.base_iter;
```

Then add the dispatch:

```zig
	// If --animate specified, validate and run animation mode
	if (raw_anim.animate) {
		const config = animation.validate(raw_anim) catch |err| {
			const msg = switch (err) {
				error.MissingDuration => "animation requires --duration SEC\n",
				error.ZoomFromEqualsTo => "--zoom-from and --zoom-to must differ\n",
				error.HoldWithoutExit => "--hold-ms requires --exit-after\n",
				error.BadFps => "--fps must be a positive integer\n",
				error.BadDuration => "--duration must be positive\n",
				error.AnimationFlagsWithoutAnimate => "internal error: animate=true but validation says otherwise\n",
			};
			try stderr.writeAll(msg);
			try stderr.flush();
			std.process.exit(2);
		};
		try app.runAnimation(config, state, allocator);
		return;
	}
```

Place the `if (raw_anim.animate) { ... }` block AFTER the env var / CLI flag application blocks and BEFORE the existing `if (bench_zoom_n) |n| { ... }` block (so the animation takes precedence over legacy bench mode if both are specified — they're mutually exclusive in practice).

- [ ] **Step 5: Update `--help` text**

In `src/main.zig`, find the `--help` multiline string. Add these lines in the appropriate sections:

In `Options:`:
```
\\  --center-re F              Override MANDELBROT_CENTER_RE
\\  --center-im F              Override MANDELBROT_CENTER_IM
\\  --zoom F                   Override MANDELBROT_ZOOM
\\  --max-iter N               Override MANDELBROT_MAX_ITER
\\  --cols N                   Override MANDELBROT_COLS
\\  --rows N                   Override MANDELBROT_ROWS
\\
\\Animation (all require --animate):
\\  --animate                  Enable animation mode
\\  --zoom-from F              Starting zoom (default 1.0)
\\  --zoom-to F                Ending zoom (required; must differ from from)
\\  --duration SEC             Total animation duration in seconds (required)
\\  --fps N                    Frames per second (default 30)
\\  --exit-after               Exit when animation completes (default: drop to interactive)
\\  --hold-ms N                With --exit-after: pause N ms on final frame
\\  --start-center-re F        Override start center real coord
\\  --start-center-im F        Override start center imag coord
\\  --end-center-re F          Override end center real coord
\\  --end-center-im F          Override end center imag coord
```

- [ ] **Step 6: Verify build**

```bash
./build debug
```

Should compile successfully.

- [ ] **Step 7: Manual smoke test**

```bash
./build debug
./zig-out/bin/mandelbrot --help | grep -E "animate|zoom-from|duration"
```

Should show the new flags.

Run a short animation:
```bash
./zig-out/bin/mandelbrot --animate --duration 0.5 --fps 10 --zoom-to 10 --center-re -0.7435 --center-im 0.1314 --exit-after 2>&1 >/dev/null | head
```

Should print "Animation complete: 5 frames in ..." stats to stderr, exit 0.

- [ ] **Step 8: Run full test suite**

```bash
./test
```

All tests pass.

- [ ] **Step 9: Commit**

```bash
git add src/main.zig build.zig
git commit -m "feat: animation CLI flags — --animate, --duration, --fps, center/zoom overrides"
```

---

### Task 6: CLI Tests for Animation

**Files:**
- Modify: `tests/cli/test_cli.bash`

- [ ] **Step 1: Append animation CLI tests**

In `tests/cli/test_cli.bash`, find the last `pass/fail` test block (the `--glyph=density overrides MANDELBROT_SUBBLOCK=1` test). AFTER it (before the `echo ""; echo "CLI Tests: ..."; exit` block), add:

```bash
# Test: --animate runs to completion with minimal params
output=$("$BINARY" --animate --duration 0.3 --fps 10 --zoom-to 10 --exit-after 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "Animation complete:"; then
    pass "--animate runs to completion with stats"
else
    fail "--animate runs to completion with stats" "rc=$rc"
fi

# Test: --animate without --duration exits with error code 2
"$BINARY" --animate --zoom-to 10 --exit-after >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
    pass "--animate without --duration exits with code 2"
else
    fail "--animate without --duration exits with code 2" "rc=$rc"
fi

# Test: --hold-ms requires --exit-after
"$BINARY" --animate --duration 0.1 --zoom-to 10 --hold-ms 50 >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
    pass "--hold-ms without --exit-after exits with code 2"
else
    fail "--hold-ms without --exit-after exits with code 2" "rc=$rc"
fi

# Test: --animate with --hold-ms adds time to total wall-clock
start_ns=$(date +%s%N 2>/dev/null || echo 0)
"$BINARY" --animate --duration 0.1 --fps 10 --zoom-to 10 --exit-after --hold-ms 300 >/dev/null 2>&1
end_ns=$(date +%s%N 2>/dev/null || echo 0)
if [ "$start_ns" != "0" ] && [ "$end_ns" != "0" ]; then
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    if [ "$elapsed_ms" -ge 300 ]; then
        pass "--hold-ms adds delay to total wall-clock"
    else
        fail "--hold-ms adds delay to total wall-clock" "elapsed=${elapsed_ms}ms (expected ≥ 300ms)"
    fi
else
    # Fallback: skip on systems where `date +%s%N` is unsupported (e.g., macOS without coreutils)
    pass "--hold-ms adds delay (skipped: date +%s%N unavailable)"
fi
```

- [ ] **Step 2: Run CLI tests**

```bash
./test
```

All 4 new CLI tests pass, plus all existing tests.

- [ ] **Step 3: Commit**

```bash
git add tests/cli/test_cli.bash
git commit -m "test: CLI tests for animation (completion, validation, hold timing)"
```

---

### Task 7: Documentation & Final Manual Verification

**Files:**
- Modify: `README.md`
- Modify: `PLAN.md`
- Modify: `CODE_MINIMAP.md`

- [ ] **Step 1: Update `README.md` with animation example**

Find the `## Usage` section. After the existing `Environment variables:` block, add a new subsection:

```markdown
### Animation mode

Render a scriptable zoom animation (in or out) between the default view and a focal point. Ideal for producing demo GIFs with `asciinema` or `vhs`.

```bash
# Zoom INTO the seahorse valley over 5 seconds at 30fps, pause 2s on final frame, then exit
./mandelbrot \
    --animate \
    --center-re -0.7435 \
    --center-im 0.1314 \
    --zoom-to 1e6 \
    --duration 5 \
    --fps 30 \
    --glyph=blocks \
    --exit-after \
    --hold-ms 2000
```

- Linear interpolation of center coordinates + logarithmic interpolation of zoom produces perceptually uniform visual motion
- Zoom-in direction (`--zoom-from < --zoom-to`) starts at the default view and ends at the focal point; zoom-out flips the direction
- Frame timing stats print to stderr at the end; absent `--exit-after`, the animation drops into interactive mode at the final state
```

- [ ] **Step 2: Update `PLAN.md`**

In the "Completed" section, add:
```markdown
- [x] Animated zoom mode (`--animate`, linear center + log zoom, recordable) — ~2026-04-20 EST
```

Remove from "Future Enhancements" if it was listed there.

- [ ] **Step 3: Update `CODE_MINIMAP.md`**

Add a new section under `src/core/`:

```markdown
## `src/core/animation.zig`
- `validate(raw: RawAnimationFlags) ValidationError!AnimationConfig` — resolves defaults, returns error for bad configs
- `frameAt(cfg: AnimationConfig, frame_idx: u32) AnimationFrame` — linear center + log zoom interpolation
- `RawAnimationFlags` — raw CLI flag values (all optional)
- `AnimationConfig` — fully resolved animation configuration
- `AnimationFrame` — per-frame viewport params (center, zoom, max_iter)
- `ValidationError` — enum of validation error types
```

Update the `src/tui/app.zig` section to include `runAnimation` and `renderOneFrame`:

```markdown
## `src/tui/app.zig`
- `run(initial_state, allocator)` — interactive event loop
- `runAnimation(config, initial_state, allocator)` — animation mode: renders N frames then either exits or drops into interactive
- `renderOneFrame(state, cache_stack, scheduler, allocator, stdout)` — shared render step; handles cache lookup, parallel compute, dispatch to density/blocks renderer
- `processEvent(state, event)` — pure state transition
- `viewportChanged(old, new)` — cache invalidation detector
- `defaultState()` — initial AppState with sensible defaults
- `AppState` — struct: center, zoom, iters, info, dimensions, flags, drag state, glyph mode
```

Update `src/main.zig`:
```markdown
## `src/main.zig`
- `main()` — CLI flag parsing (including 11 animation flags + 6 general viewport flags), env var injection, mode dispatch (help, about, single-frame, bench, animate, interactive)
- `runBenchZoomSequence(...)` — existing bench driver
- `parseFlagF128`, `parseFlagF64`, `parseFlagU32`, `parseFlagU64`, `parseFlagU16` — CLI value parsers
- `parseF128Env`, `parseU32Env`, `parseU16Env`, `parseBoolEnv` — env var parsers
```

- [ ] **Step 4: Final test run and smoke test**

```bash
./test
```

All tests pass.

```bash
./build
./zig-out/bin/mandelbrot --animate --duration 2 --fps 15 --zoom-to 100 --center-re -0.7435 --center-im 0.1314 --exit-after 2>&1 >/dev/null | head
```

Prints stats like:
```
Animation complete: 30 frames in 2.XX s (target 2.00s, 15 fps)
  Min: X.X ms   Max: XX.X ms   Mean: X.X ms
```

- [ ] **Step 5: Commit**

```bash
git add README.md PLAN.md CODE_MINIMAP.md
git commit -m "docs: README + PLAN + CODE_MINIMAP for animation mode"
```

---

## Self-Review

**Spec coverage:**
- ✅ `--animate` and all 10 sub-flags (Task 5, Step 4)
- ✅ 6 general viewport flags (Task 5, Step 4)
- ✅ `--flag=VALUE` and `--flag VALUE` both accepted (ArgHelper in Task 5, Step 4)
- ✅ Validation errors → exit code 2 + stderr message (Task 5, Step 4)
- ✅ Linear center + log zoom interpolation (Task 1, Step 4 via frameAt)
- ✅ `adaptiveMaxIter` per frame (Task 1, Step 4 inside frameAt)
- ✅ `renderOneFrame` shared helper (Task 3)
- ✅ `runAnimation` reuses cache/scheduler/renderer path (Task 4)
- ✅ Frame pacing with sleep, no skipping (Task 4, Step 3)
- ✅ Stats to stderr at end (Task 4, Step 3)
- ✅ `--exit-after` + `--hold-ms N` pause + exit (Task 4, Step 3)
- ✅ Default zoom-in: start=(-0.5,0), end=focal (Task 1, Step 4 in validate)
- ✅ Default zoom-out: start=focal, end=(-0.5,0) (Task 1, Step 4 in validate)
- ✅ Explicit `--start/end-center-*` overrides (Task 1, Step 4 in validate)
- ✅ Precedence CLI > env > default (Task 5, Step 4)
- ✅ CLI tests (Task 6)
- ✅ Unit tests for frameAt and validate (Tasks 1 & 2)
- ✅ README example (Task 7, Step 1)

**Placeholder scan:** No TBDs. All code blocks complete.

**Type consistency:**
- `RawAnimationFlags`, `AnimationConfig`, `AnimationFrame`, `ValidationError` consistent between Task 1 (definition) and Task 5 (usage)
- `renderOneFrame` signature consistent between Task 3 (definition) and Task 4 (usage)
- `runAnimation` signature consistent between Task 4 (definition) and Task 5 (dispatch)
- `ArgHelper.match` helper defined once in Task 5, used for all flag parsing
- CLI value parsers (`parseFlagF128`, etc.) defined once in Task 5, used throughout

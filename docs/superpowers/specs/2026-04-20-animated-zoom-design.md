# Animated Zoom — Design Spec

## Overview

Add an animation mode to the Mandelbrot TUI that produces a scriptable, recordable zoom (in or out) between a default viewport and a focal point, at a user-specified duration and FPS. Primary use case: generate demo GIFs/videos with tools like `asciinema` or `vhs`.

Animation uses **linear interpolation of the center coordinate** and **logarithmic interpolation of zoom** — the standard for fractal animations, producing perceptually uniform visual motion. Each frame goes through the same render path as interactive mode (uses cache, scheduler, f64/f128 dispatch, glyph mode) so there's a single code path to test and maintain.

## CLI Surface

**New animation-specific flags** (all require `--animate`):

| Flag | Default | Description |
|------|---------|-------------|
| `--animate` | — | Enable animation mode |
| `--zoom-from F` | `1.0` | Starting zoom |
| `--zoom-to F` | `1.0` | Ending zoom (must differ from from) |
| `--duration SEC` | required | Total animation duration in seconds |
| `--fps N` | `30` | Frames per second |
| `--exit-after` | `false` | Exit when animation completes (default: drop into interactive mode) |
| `--hold-ms N` | `0` | With `--exit-after`: pause N ms on final frame before exit |
| `--start-center-re F` | derived | Override start center real coord |
| `--start-center-im F` | derived | Override start center imag coord |
| `--end-center-re F` | derived | Override end center real coord |
| `--end-center-im F` | derived | Override end center imag coord |

**Generally useful flags** (also useful outside animation — closes the "env vars but no CLI flag" gap):

| Flag | Overrides env var |
|------|-------------------|
| `--center-re F` | `MANDELBROT_CENTER_RE` |
| `--center-im F` | `MANDELBROT_CENTER_IM` |
| `--zoom F` | `MANDELBROT_ZOOM` |
| `--max-iter N` | `MANDELBROT_MAX_ITER` |
| `--cols N` | `MANDELBROT_COLS` |
| `--rows N` | `MANDELBROT_ROWS` |

**Precedence**: CLI flag > env var > default. Matches existing `--glyph=MODE` / `MANDELBROT_SUBBLOCK` pattern.

**Supporting `--flag=VALUE` and `--flag VALUE` syntax**: both accepted, for ergonomic consistency with `--glyph=blocks`.

### Validation errors

Print to stderr, exit with code 2:
- `--animate` without `--duration`
- `--zoom-from == --zoom-to` with `--animate` (no animation to show)
- `--hold-ms` specified without `--exit-after`
- Any animation flag without `--animate`
- `--duration <= 0`
- `--fps <= 0`

### Default center resolution

When `--animate` is specified and center flags are not explicitly provided:
- **Zoom-in** (`zoom_from < zoom_to`): `start_center = (-0.5, 0.0)` (default view), `end_center = focal` (from `--center-re/im` or env vars)
- **Zoom-out** (`zoom_from > zoom_to`): `start_center = focal`, `end_center = (-0.5, 0.0)`

Explicit `--start-center-re/im` / `--end-center-re/im` always win.

## Animation Math

For each frame index `i ∈ [0, num_frames)` where `num_frames = round(fps * duration)`:

```
t = if num_frames > 1 then i / (num_frames - 1) else 1.0   // 0 at first frame, 1 at last frame

// Linear interpolation of center
center_re = start_center_re + t * (end_center_re - start_center_re)
center_im = start_center_im + t * (end_center_im - start_center_im)

// Logarithmic (geometric) interpolation of zoom — each frame multiplies zoom by a constant ratio
zoom = start_zoom * (end_zoom / start_zoom) ^ t

// Adaptive iteration count based on zoom
max_iter = viewport.adaptiveMaxIter(zoom, base_iter)
```

Linear center + log zoom is the standard for fractal zoom animations. At t=0.5, zoom is the geometric mean of start and end (`sqrt(start_zoom * end_zoom)`); at t=1.0, we arrive exactly at the end values.

## Animation Loop

### Shared render path

Extract the current render step from `src/tui/app.zig::run()` into a new public helper:

```zig
pub fn renderOneFrame(
    state: *AppState,
    cache_stack: *CacheStack,
    scheduler: *BackgroundScheduler,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
) !void {
    // Existing render path:
    // compute sub_mul, check cache, parallel compute if miss, store in cache,
    // dispatch to renderFrameFromBuffer or renderFrameFromBlocksBuffer, writeAll, flush, requestWork
}
```

Both the interactive event loop and the animation loop call `renderOneFrame` for each frame. Single code path — any render bug appears consistently in both modes.

### Frame pacing

**Policy: render all frames, never skip** (maintains visual continuity).

```zig
const target_frame_ns: u64 = 1_000_000_000 / fps;
var frame_idx: u32 = 0;
while (frame_idx < num_frames) : (frame_idx += 1) {
    const frame_start = std.time.nanoTimestamp();

    const frame_params = animation.frameAt(config, frame_idx);
    state.center_re = frame_params.center_re;
    state.center_im = frame_params.center_im;
    state.zoom = frame_params.zoom;
    state.max_iter = frame_params.max_iter;
    state.needs_redraw = true;

    try renderOneFrame(&state, &cache_stack, &scheduler, allocator, stdout);

    const elapsed_ns: i128 = std.time.nanoTimestamp() - frame_start;
    const target_ns: i128 = @intCast(target_frame_ns);
    if (elapsed_ns < target_ns) {
        std.Thread.sleep(@intCast(target_ns - elapsed_ns));
    }
}
```

If a frame overruns its budget, we don't sleep — move on to the next frame. Animation may take longer than `duration` in real time; capture tools like `asciinema` record real-time so the output reflects actual timing.

### End-of-animation behavior

- `--exit-after` + `--hold-ms N`: sleep N ms on final frame, cleanup terminal, exit 0
- `--exit-after` alone: cleanup, exit 0
- Neither: drop into interactive event loop starting from the final state. Cache's Level 0 is already populated so the first user-triggered redraw is a cache hit.

### Post-animation stats (stderr, always printed before exit or interactive transition)

```
Animation complete: 90 frames in 3.12s (target 3.00s, 30 fps)
  Min: 8.2 ms   Max: 45.7 ms   Mean: 34.7 ms
  ≥ target (33.3 ms): 12 frames (13%)
```

## File Structure

### New file

**`src/core/animation.zig`** — pure computation and config validation, zero I/O:

```zig
pub const RawAnimationFlags = struct {
    animate: bool,
    zoom_from: ?f128,
    zoom_to: ?f128,
    duration_sec: ?f64,
    fps: ?u32,
    focal_re: ?f128,
    focal_im: ?f128,
    start_center_re: ?f128,
    start_center_im: ?f128,
    end_center_re: ?f128,
    end_center_im: ?f128,
    exit_after: bool,
    hold_ms: ?u64,
    base_iter: u32,
};

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

pub const AnimationFrame = struct {
    center_re: f128,
    center_im: f128,
    zoom: f128,
    max_iter: u32,
};

pub const ValidationError = error {
    MissingDuration,
    ZoomFromEqualsTo,
    HoldWithoutExit,
    BadFps,
    BadDuration,
    AnimationFlagsWithoutAnimate,
};

/// Validate raw flags and resolve defaults (zoom direction, default centers).
/// Returns a fully-resolved AnimationConfig or a ValidationError.
pub fn validate(raw: RawAnimationFlags) ValidationError!AnimationConfig;

/// Pure: compute frame params for frame_idx in [0, num_frames).
/// Uses linear interpolation for center, log interpolation for zoom.
pub fn frameAt(cfg: AnimationConfig, frame_idx: u32) AnimationFrame;
```

### Modified files

- **`src/main.zig`** — parse 11 new animation flags + 6 new general CLI flags. On `--animate`: call `animation.validate()`, then call `app.runAnimation(config, allocator)`. Support both `--flag VALUE` and `--flag=VALUE` syntax.

- **`src/tui/app.zig`** — extract `renderOneFrame` as described. Add new `pub fn runAnimation(config: AnimationConfig, allocator: std.mem.Allocator) !void` that does terminal setup (identical to `run()`), animation loop, then either exits or falls through to `run()`'s event loop using the final state.

- **`build.zig`** — add `animation_mod` + `animation_tests` target; add `animation` as an import to `app_mod` and `main.zig`'s root module.

- **`README.md`** — document animation mode with an example command (e.g., `./mandelbrot --animate --center-re -0.7435 --center-im 0.1314 --zoom-to 1e6 --duration 5 --exit-after --hold-ms 2000`).

## Testing

### Unit tests (`tests/unit/test_animation.zig`)

**Pure-function correctness** — no I/O, no threads:

- `frameAt at t=0 returns exact start values` — `frame_idx = 0` → `center == start_center`, `zoom == start_zoom`
- `frameAt at t=1 returns exact end values` — `frame_idx = num_frames - 1` → matches end values
- `frameAt zoom interpolation is geometric` — at midpoint, `zoom ≈ sqrt(start * end)` (±1e-9 epsilon)
- `frameAt center interpolation is linear` — at midpoint, `center ≈ (start + end) / 2`
- `validate: missing duration → MissingDuration` when `--animate` and no `--duration`
- `validate: zoom_from == zoom_to → ZoomFromEqualsTo`
- `validate: hold_ms without exit_after → HoldWithoutExit`
- `validate: bad fps (0) → BadFps`
- `validate: bad duration (0.0) → BadDuration`
- `validate: animation flags without --animate → AnimationFlagsWithoutAnimate`
- `validate zoom-in defaults: start_center = (-0.5, 0), end_center = focal`
- `validate zoom-out defaults: start_center = focal, end_center = (-0.5, 0)`
- `validate explicit start/end center overrides win over defaults`

### CLI tests (`tests/cli/test_cli.bash`)

- `--animate --duration 0.1 --fps 10 --zoom-to 2 --exit-after` runs to completion (exit 0) and produces non-trivial stdout
- `--animate` without `--duration` exits with code 2 and prints "missing duration" (or similar) to stderr
- `--animate --duration 0.1 --fps 10 --zoom-to 2 --exit-after --hold-ms 50` total wall time ≥ 0.15s (animation + hold)
- Interactive-mode-after-animation path is NOT tested in bash (not easily scriptable); rely on manual verification

### Manual verification

- `./mandelbrot --animate --center-re -0.7435 --center-im 0.1314 --zoom-to 1e6 --duration 5 --exit-after` — watch it render, look smooth
- Same with `--zoom-from 1e6 --zoom-to 1` for zoom-out
- Capture with `asciinema rec demo.cast && asciinema play demo.cast` — verify recording plays correctly
- `--hold-ms 2000` produces a visible 2-second pause before exit (useful for GIF loops)

## Non-Goals

- Skipping/dropping frames for strict real-time pacing — not worth the visual quality cost
- Arbitrary curves beyond linear center + log zoom — the standard is clearly correct for fractals
- Bypassing the cache for animation frames — single code path is simpler; overhead is negligible (~0.3% per frame for scheduler spawn + cancel)
- Continuous looping animations — use a shell loop or asciinema's built-in replay
- Multi-segment animations (e.g., zoom in, pan, zoom out) — combine separate invocations with a playback script if needed

## Expected Example Command

```bash
./mandelbrot \
    --center-re -0.7435 \
    --center-im 0.1314 \
    --zoom-to 1e6 \
    --duration 5 \
    --fps 30 \
    --glyph=blocks \
    --exit-after \
    --hold-ms 2000
```

Produces a 5-second zoom-in from the default view into the seahorse valley, 150 frames at 30fps in block-quadrant mode, 2-second pause on the final frame, then exits. Pipe to `asciinema` or record with `vhs` to capture.

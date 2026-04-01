# Mandelbrot TUI Explorer — Design Spec

## Overview

An interactive terminal-based Mandelbrot set explorer written in pure Zig, using hexagonal architecture (pure computational core, TUI I/O adapter). Renders using 256 ANSI colors with ASCII density characters for luminance texture. Supports mouse-driven zoom, keyboard navigation, and SIGWINCH-responsive resizing.

## Architecture

```
┌─────────────────────────────────────────────┐
│  main.zig (entry point, setup, cleanup)     │
├─────────────────────────────────────────────┤
│  tui/ (I/O adapter layer)                   │
│    app.zig      — event loop, state machine │
│    renderer.zig — pure: state → ANSI buffer │
│    input.zig    — pure: bytes → Event       │
│    terminal.zig — raw mode, mouse, SIGWINCH │
├─────────────────────────────────────────────┤
│  core/ (pure computation, no I/O)           │
│    mandelbrot.zig — escape-time algorithm   │
│    viewport.zig   — coordinate math         │
│    coloring.zig   — iter → (char, color)    │
└─────────────────────────────────────────────┘
```

The core layer is 100% pure — no I/O, no allocations beyond caller-provided buffers, no side effects. This is the natural seam for a future C FFI.

## Core Layer

### `core/mandelbrot.zig`

- `computeIterations(c_re: f128, c_im: f128, max_iter: u32) → u32`
  Returns iteration count at which |z|² > 4, or max_iter if in the set.
  Uses f128 for ~33 digits of precision (~10^-33 zoom depth).

- `computeRegion(params: RegionParams, out: []u32) → void`
  Fills buffer with iteration counts for a rectangular grid of the complex plane.
  Designed so a future thread pool can split into sub-regions.

  ```zig
  const RegionParams = struct {
      center_re: f128,
      center_im: f128,
      zoom: f128,
      width: u16,
      height: u16,
      max_iter: u32,
      aspect_ratio: f64, // ~0.5 for terminal chars (taller than wide)
  };
  ```

### `core/viewport.zig`

- `screenToComplex(col, row, center_re, center_im, zoom, width, height) → (f128, f128)`
  Maps terminal cell to complex coordinate. Applies aspect ratio correction (~0.5 vertical scale) since terminal characters are ~2x taller than wide.

- `zoomAt(state, factor, screen_col, screen_row) → new_state`
  Recenters on the clicked point and applies zoom factor.

- `pan(state, direction) → new_state`
  Shifts center by 10% of the visible range in the given direction (proportional to zoom level).

- `adaptiveMaxIter(zoom_level, base_iter) → u32`
  Formula: `base_iter + k * log2(zoom)`, scaling iterations with zoom depth.

### `core/coloring.zig`

- `iterToCell(iter: u32, max_iter: u32) → Cell`
  Returns `{ .char: u8, .fg_color: u8, .bg_color: u8 }`.
  - **Character**: maps to ` .:-=+*#%@` (10 levels) based on iteration-to-max ratio for luminance texture.
  - **Color**: smooth cyclic gradient through the 216-color cube (ANSI 16–231) for pleasing bands.
  - **Interior** (iter == max_iter): black background, space character.

## TUI Layer

### `tui/terminal.zig`

- `enterRawMode() / exitRawMode()` — saves/restores termios
- `enableMouseTracking() / disableMouseTracking()` — SGR 1006 mouse protocol (supports coords > 223)
- `hideCursor() / showCursor()`
- `getTermSize() → { cols, rows }` — TIOCGWINSZ ioctl
- `setupSigwinch()` — sets atomic flag for event loop

Cleanup (exitRawMode + disableMouseTracking + showCursor) runs on all exit paths: normal, Ctrl-C, panic.

### `tui/input.zig`

Parses raw stdin bytes into typed events:

```zig
const Event = union(enum) {
    key_q,
    key_plus,
    key_minus,
    key_bracket_open,   // decrease max iter
    key_bracket_close,  // increase max iter
    key_i,              // toggle info bar
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    mouse_left: struct { col: u16, row: u16 },
    mouse_right: struct { col: u16, row: u16 },
    ctrl_c,
    resize,
    unknown,
};
```

`parseEvent(bytes: []const u8) → Event` is a pure function — fully testable with synthetic byte sequences.

### `tui/renderer.zig`

`renderFrame(state: AppState, term_width: u16, term_height: u16, allocator) → []u8`

Pure function — takes all state, returns complete ANSI output buffer:
1. Calls `core.computeRegion()` for iteration counts
2. Maps each cell via `core.coloring.iterToCell()`
3. Builds ANSI escape string with color change optimization (skip when consecutive cells share colors)
4. If `show_info`, appends status bar at bottom with center coords, zoom, max_iter, render time, and the reproducible view command

### `tui/app.zig`

Event loop and state:

```zig
const AppState = struct {
    center_re: f128,
    center_im: f128,
    zoom: f128,
    max_iter: u32,
    base_iter: u32,
    show_info: bool,
    term_width: u16,
    term_height: u16,
    needs_redraw: bool,
};
```

Default start: center (-0.5, 0.0), zoom 1.0 (showing roughly -2.5 to 1.0 real, -1.0 to 1.0 imaginary).

Loop: non-blocking stdin read → check SIGWINCH flag → process event → update state → if needs_redraw, render and write to stdout.

### `main.zig`

Entry point. Reads env var overrides, sets up terminal, creates initial AppState, runs app.run(), ensures cleanup.

## Interaction

| Input | Action |
|-------|--------|
| Left-click | Zoom in 2x centered on click point |
| Right-click | Zoom out 2x centered on click point |
| `+` | Zoom in 2x at current center |
| `-` | Zoom out 2x at current center |
| Arrow keys | Pan in direction |
| `[` | Decrease max iterations |
| `]` | Increase max iterations |
| `i` | Toggle info bar |
| `q` / Ctrl-C | Quit |

## Info Bar

When visible (toggled with `i`), a single line at the bottom showing:
- Current center coordinates and zoom level
- Max iterations
- A reproducible command to restore the current view:
  ```
  MANDELBROT_CENTER_RE=-0.7435669 MANDELBROT_CENTER_IM=0.1314023 MANDELBROT_ZOOM=1.2e+08 mandelbrot
  ```

## Environment Variables

All optional, for view injection (testing + bookmarking):

| Variable | Purpose |
|----------|---------|
| `MANDELBROT_CENTER_RE` | Center real coordinate (f128) |
| `MANDELBROT_CENTER_IM` | Center imaginary coordinate (f128) |
| `MANDELBROT_ZOOM` | Zoom level (f128) |
| `MANDELBROT_MAX_ITER` | Override max iterations (u32) |
| `MANDELBROT_COLS` | Override terminal width (for testing) |
| `MANDELBROT_ROWS` | Override terminal height (for testing) |

## CLI Surface

| Flag | Purpose |
|------|---------|
| `-h` / `--help` | Usage information |
| `--about` | One-line: description, version, platform/arch |
| `--single-frame` | Render one frame to stdout and exit |
| `--no-color` / `--no-ansi` | Plain ASCII mode |
| `--simple` | Suppress color, ANSI, emoji |

## Precision

Uses `f128` natively (Zig built-in). Provides ~33 decimal digits of precision, supporting zoom depths to approximately 10^-33. No external dependencies required.

## Color Mapping

Dual-channel encoding per cell:
- **Character channel**: 10-level ASCII density ` .:-=+*#%@` for luminance texture
- **Color channel**: Smooth cyclic gradient through ANSI 256-color palette (216-color cube, indices 16–231)
- **Interior**: Black background + space character

## Testing

### Unit tests (`tests/unit/`)
- **mandelbrot.zig**: Known points — (0,0) in set, (2,0) escapes iter 1, (-1,0) in set, boundary points
- **viewport.zig**: Screen↔complex roundtrips, zoom recentering, aspect ratio, adaptive max_iter formula
- **coloring.zig**: Boundary values, interior mapping, gradient continuity
- **input.zig**: Synthetic byte sequences for all event types (SGR mouse, arrow keys, q, +, -, [, ], Ctrl-C)
- **renderer.zig**: Known AppState + small terminal → assert ANSI output. Build assertions from observed reality (render, dump, verify with Peter, then encode).

### CLI tests (`tests/cli/`)
Bash-driven tests against the actual binary:
- `--help` exits 0 with usage text
- `--about` prints version/platform one-liner
- SIGTERM → graceful exit, terminal restored
- `q` keypress → clean exit
- `--single-frame` with env var injection → deterministic output snapshot comparison

### Runner
`./test` — bash script running Zig unit tests + CLI tests, accumulates errors, returns count as exit code.

## Build & Tooling

- `build.zig` — Zig 0.15, ReleaseFast default, debug announces in yellow
- `flake.nix` — Zig 0.15, hyperfine
- `./build` — wraps `nix build`, copies to `zig-out/bin/mandelbrot`
- `./test` — unit + CLI tests via nix
- `PLAN.md` — work items + future enhancements
- `CODE_MINIMAP.md` — file/function index
- `PROJECT_OVERVIEW.md` — project goals

## Future Enhancements (not in initial scope)

- Multithreaded computation (thread pool splitting viewport into row bands)
- Arbitrary precision (bignum) for unlimited zoom depth
- C FFI surface exposing core functions
- Additional fractal types (Julia sets, Burning Ship)
- `--lang` / i18n support per CLI guidelines
- Cross-platform builds (5 OS/arch targets)

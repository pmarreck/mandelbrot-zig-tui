# Block Quadrant Glyph Mode — Design Spec

## Overview

Add a new rendering mode `blocks` (alongside the existing `density`) that uses Unicode block quadrant characters (`▖▗▘▙▚▛▜▝▞▟▀▄▌▐█`) to render each terminal cell as a 2×2 sub-pixel grid. Each cell can display up to 2 colors (FG + BG) chosen by median-split clustering of the 4 sub-pixel iteration values. This gives 4× spatial resolution and dramatically sharper rendering of the Mandelbrot set's boundary.

Block-mode data comes "for free" from the existing progressive cache — Level 1 is already 2× resolution — we just re-interpret what "Level 0" means when in blocks mode.

## Two-Color Block Quadrant Algorithm

For each terminal cell, look at its 2×2 sub-pixels with iteration values `{tl, tr, bl, br}`:

**Case 1 — all 4 interior**: emit `' '` (space), FG and BG both black.

**Case 2 — all 4 exterior**: two-color clustering by iteration count.
1. Sort the 4 iter values, compute median
2. Form `fg_mask: u4` where bit is set for sub-pixels with `iter ≥ median` (tl=bit 3, tr=bit 2, bl=bit 1, br=bit 0)
3. If all 4 end up in one group (all values equal) → emit `█` with FG = palette(mean), BG = black
4. Otherwise:
   - `FG color = palette(mean of sub-pixels in FG group)`
   - `BG color = palette(mean of sub-pixels in BG group)`
   - Emit quadrant char = lookup table `[fg_mask]`

**Case 3 — mixed interior + exterior**: interior sub-pixels always go to BG.
- `fg_mask = ~interior_mask & 0x0F` (exterior positions → FG)
- `FG color = palette(mean of exterior iters)`
- `BG color = black` (interior)
- Emit quadrant char = lookup table `[fg_mask]`

### Quadrant Char Lookup Table

| Mask | tl,tr,bl,br | Char | Unicode |
|------|-------------|------|---------|
| 0000 | · · · · | `' '` | U+0020 |
| 0001 | · · · █ | `▗` | U+2597 |
| 0010 | · · █ · | `▖` | U+2596 |
| 0011 | · · █ █ | `▄` | U+2584 |
| 0100 | · █ · · | `▝` | U+259D |
| 0101 | · █ · █ | `▐` | U+2590 |
| 0110 | · █ █ · | `▞` | U+259E |
| 0111 | · █ █ █ | `▟` | U+259F |
| 1000 | █ · · · | `▘` | U+2598 |
| 1001 | █ · · █ | `▚` | U+259A |
| 1010 | █ · █ · | `▌` | U+258C |
| 1011 | █ · █ █ | `▙` | U+2599 |
| 1100 | █ █ · · | `▀` | U+2580 |
| 1101 | █ █ · █ | `▜` | U+259C |
| 1110 | █ █ █ · | `▛` | U+259B |
| 1111 | █ █ █ █ | `█` | U+2588 |

## Cache & Compute Architecture

### Re-interpreting Level 0 per glyph mode

The cache pyramid already doubles at each level. We shift what "Level 0" means based on `GlyphMode`:

- **Density mode**: Level 0 = `term_width × render_height`, rendered 1 cell = 1 sub-pixel
- **Blocks mode**: Level 0 = `2 × term_width × 2 × render_height`, rendered 4 sub-pixels = 1 cell

Everything else about the cache stack (5 levels, 2× doubling, `inheritFromParent`, 3-offset `computeDoubling`, `BackgroundScheduler`) works unchanged.

### Performance implications

Compute work is 4× (2× in each dimension). With the f64 hot loop:
- 200×60 terminal density mode: 12,000 points, ~0.58 ms parallel
- 200×60 terminal blocks mode: 48,000 points, ~2.3 ms parallel (projected, still sub-frame)

Memory is 4× per level. Trivial.

### Changes to existing code

- `CacheStack.initForViewport` — takes explicit width/height; callers pass `term_width * mul` and `render_height * mul` where `mul ∈ {1, 2}`. No signature change.
- Foreground `parallelComputeRegion` — same multiplied dimensions.
- `BackgroundScheduler` — unchanged.

### Mode switch invalidation

Changing glyph mode mid-session changes Level 0's dimensions, so the cache must be fully invalidated and rebuilt on mode switch. Expensive (~2.3 ms at 200×60 for blocks mode from scratch) but user-initiated and rare.

## API & UI Integration

### `src/core/coloring.zig`

Add:

```zig
pub const GlyphMode = enum { density, blocks };

/// Convert iteration value to RGB via Bernstein palette. This is a refactor —
/// extract the existing bernsteinPalette + logTransform logic from iterToCell
/// into a shared function that both iterToCell (density mode) and iterToBlock
/// (blocks mode) call. Interior points (iter == INTERIOR) → black.
pub fn iterToColor(iter: f64, max_iter: u32) RGB;

/// Render a 2×2 block of iteration values into a quadrant char + FG/BG RGB.
pub fn iterToBlock(
    tl: f64, tr: f64, bl: f64, br: f64, max_iter: u32,
) BlockCell;

pub const BlockCell = struct {
    char_bytes: []const u8,  // UTF-8 bytes for the glyph (1-3 bytes)
    fg: RGB,
    bg: RGB,
    all_interior: bool,
};
```

Existing `iterToCell` (density mode) stays unchanged.

### `src/tui/renderer.zig`

```zig
pub const RenderState = struct {
    center_re: f128,
    center_im: f128,
    zoom: f128,
    max_iter: u32,
    show_info: bool,
    glyph_mode: coloring.GlyphMode = .density,  // new field
};

/// Render a blocks-mode frame from a 2x-resolution iteration buffer.
/// iter_buf must be (width*2) × (render_height*2) in size.
pub fn renderFrameFromBlocksBuffer(
    state: RenderState,
    width: u16, height: u16,
    iter_buf: []const f64,
    allocator: std.mem.Allocator,
) ![]u8;
```

`renderFrameFromBuffer` (density) stays as is.

### `src/tui/app.zig`

- Add `glyph_mode: coloring.GlyphMode = .density` to `AppState`
- Event handler for `key_g`: cycle modes (`density → blocks → density`)
- `viewportChanged` includes `glyph_mode` in its comparison (cache invalidation on mode change)
- Render path chooses `sub_mul: u16 = if (state.glyph_mode == .blocks) 2 else 1` and allocates the iter_buf at `(term_width * sub_mul) × (render_height * sub_mul)`
- Cache init uses the same multiplied dims
- Dispatches to `renderFrameFromBuffer` or `renderFrameFromBlocksBuffer`

### `src/tui/input.zig`

Add `key_g` variant to the `Event` union. Parse lowercase `g` byte.

### `src/main.zig`

- Parse `--glyph=density` / `--glyph=blocks` CLI flag
- Read `MANDELBROT_SUBBLOCK` env var (`true`/`1`/`yes`/`on` → blocks mode, case-insensitive)
- Precedence: CLI flag > env var > default (`density`)

```zig
var glyph_mode: coloring.GlyphMode = .density;

// Env var
if (std.posix.getenv("MANDELBROT_SUBBLOCK")) |v| {
    if (parseBoolEnv(v)) glyph_mode = .blocks;
}

// CLI flag (overrides env var when present)
if (cli_glyph_mode) |m| glyph_mode = m;
```

`parseBoolEnv(v)` returns true for `"true" | "1" | "yes" | "on"` (case-insensitive), false otherwise.

### Info bar

Add current mode to the status line: `... iter=256 glyph=blocks`.

### Help text

Add to controls:
```
g              Cycle glyph mode (density, blocks)
```

Add CLI option:
```
--glyph=MODE              Initial glyph mode: density (default) or blocks
```

Add env var:
```
MANDELBROT_SUBBLOCK       Set to true/1/yes/on to start in blocks mode
```

## Testing

### Unit tests

**`tests/unit/test_coloring.zig` — add block-mode cases:**

- `iterToBlock all-interior returns space char + black` — pass 4×INTERIOR, verify char is `' '`, FG/BG both black, `all_interior` true
- `iterToBlock all-exterior uniform returns full block` — pass 4 equal iter values, verify char is `'█'` (U+2588), FG is the palette color for that iter
- `iterToBlock all-exterior split returns correct quadrant` — pass `{10, 20, 100, 110}` (tl=10, tr=20, bl=100, br=110), verify `fg_mask = 0b0011` → char is `'▄'` (U+2584), FG ≈ palette(105), BG ≈ palette(15)
- `iterToBlock mixed interior/exterior` — pass `{INTERIOR, 50, INTERIOR, 50}`, verify `fg_mask = 0b0101` → char is `'▐'` (U+2590), FG ≈ palette(50), BG = black
- `iterToBlock all 16 fg_mask values map to expected glyphs` — parameterized test against the full lookup table

**`tests/unit/test_renderer.zig` — add blocks-mode rendering:**

- `renderFrameFromBlocksBuffer produces output` — synthesize a 4×4 iter buffer, call at 2×2 display dims, verify output contains ANSI + a block-quadrant char
- `renderFrameFromBlocksBuffer interior region shows spaces` — all-INTERIOR buffer → output is mostly spaces with black BG
- `renderFrameFromBlocksBuffer deterministic` — same input twice → identical output bytes

**`tests/unit/test_input.zig` — add:**

- `parse 'g' as key_g`

### CLI tests (`tests/cli/test_cli.bash`)

- `--glyph=blocks --single-frame produces output containing block-quadrant chars` — grep for any of `▀▄▌▐█▖▗▘▙▚▛▜▝▞▟`
- `MANDELBROT_SUBBLOCK=1 --single-frame produces block-quadrant chars` — same test with env var instead of flag
- `--glyph=density overrides MANDELBROT_SUBBLOCK=1` — env says blocks, flag says density, output should NOT contain block chars

### Manual visual verification

After implementation, render `--single-frame` at `--glyph=blocks` to stdout and review interactively to verify the `g` toggle switches cleanly at runtime without crashing.

## Non-Goals

- Braille mode (deferred; add as a separate mode in the `GlyphMode` enum later if desired)
- Sextants mode (deferred — requires 2×3 sub-pixel resolution which doesn't align with our 2× cache pyramid)
- Two-color clustering beyond median-split — median is sufficient for Mandelbrot since colors gradient smoothly
- Shape-aware edge-direction glyphs (`/`, `\`, `|`, `-`) — a different algorithm class, deferred

## Expected Visual Result

The Mandelbrot set's intricate boundary curves will render with 4× more spatial resolution. The self-similar "spirals" and filigree that currently appear as pixelated smears should show individual detail. The interior remains solid black; the exterior retains color but with sharper edges.

# Block Quadrant Glyph Mode — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new rendering mode `blocks` using Unicode block quadrant characters (`▖▗▘▙▚▛▜▝▞▟▀▄▌▐█`) where each terminal cell displays 2×2 sub-pixels with up to 2 colors (FG + BG) selected by median-split clustering of iteration values.

**Architecture:** New `GlyphMode` enum and `iterToBlock` function in `coloring.zig`. New `renderFrameFromBlocksBuffer` in `renderer.zig`. App dispatches to the right renderer and allocates iter_buf at doubled dimensions when in blocks mode. The existing cache pyramid is re-interpreted: in blocks mode Level 0 = 2×terminal dims.

**Tech Stack:** Zig 0.15.2, no new dependencies. Uses existing f64 hot loop for 4× pixel compute.

**Spec:** `docs/superpowers/specs/2026-04-19-block-quadrant-glyphs-design.md`

**IMPORTANT Zig 0.15 notes:**
- UTF-8 encoding of 3-byte chars (U+2580..U+259F range): `const bytes: []const u8 = "▀"` gives the correct UTF-8 encoding as a string literal
- `std.ArrayListUnmanaged(u8)` for building output byte buffers
- Enum comparison: `state.glyph_mode == .blocks`
- `std.ascii.toLower` for case-insensitive string comparison

---

## File Structure

```
src/
  core/
    coloring.zig        — MODIFY: extract iterToColor, add GlyphMode/BlockCell/iterToBlock
  tui/
    input.zig           — MODIFY: add key_g event
    renderer.zig        — MODIFY: add glyph_mode to RenderState, add renderFrameFromBlocksBuffer
    app.zig             — MODIFY: own glyph_mode, key_g handler, dispatch render, doubled dims
  main.zig              — MODIFY: parse --glyph flag + MANDELBROT_SUBBLOCK env var
tests/
  unit/
    test_coloring.zig   — ADD: iterToBlock test cases (all-interior/all-exterior/mixed/quadrant table)
    test_renderer.zig   — ADD: renderFrameFromBlocksBuffer tests
    test_input.zig      — ADD: 'g' key parsing
  cli/
    test_cli.bash       — ADD: blocks mode + env var + flag precedence tests
PLAN.md                 — MODIFY: mark completed, add new future items
CODE_MINIMAP.md         — MODIFY: reflect new functions and modes
```

---

### Task 1: Refactor — Extract `iterToColor` Shared Function

Pure refactor: extract palette+transform logic from `iterToCell` into a standalone function. No behavior change. Enables the future `iterToBlock` to share the coloring math.

**Files:**
- Modify: `src/core/coloring.zig`

- [ ] **Step 1: Add `iterToColor` function to coloring.zig**

In `src/core/coloring.zig`, add BEFORE the existing `iterToCell` function (after the `density_chars` constant):

```zig
/// Convert a smooth iteration count to an RGB color via the Bernstein palette
/// with log transform for visual band distribution.
/// Interior points (iter == INTERIOR) return black.
/// This is the shared coloring primitive — iterToCell (density mode) and
/// iterToBlock (blocks mode) both call it.
pub fn iterToColor(smooth_iter: f64, max_iter: u32) RGB {
	if (smooth_iter == mandelbrot.INTERIOR) {
		return .{ .r = 0, .g = 0, .b = 0 };
	}
	const t = logTransform(smooth_iter, max_iter);
	return bernsteinPalette(t);
}
```

- [ ] **Step 2: Refactor `iterToCell` to call `iterToColor`**

Replace the entire `iterToCell` function body with the refactored version:

```zig
/// Map a smooth iteration count to a renderable terminal cell.
/// Interior points (smooth_iter == INTERIOR) produce a black space.
/// Exterior points get a cyclic density char + Bernstein polynomial RGB color.
pub fn iterToCell(smooth_iter: f64, max_iter: u32) Cell {
	if (smooth_iter == mandelbrot.INTERIOR) {
		return .{ .char = ' ', .color = .{ .r = 0, .g = 0, .b = 0 }, .is_interior = true };
	}

	// Cyclic character mapping based on integer part of smooth iteration
	const int_iter: u32 = @intFromFloat(@max(0.0, smooth_iter));
	const char = density_chars[int_iter % density_chars.len];

	const color = iterToColor(smooth_iter, max_iter);

	return .{ .char = char, .color = color, .is_interior = false };
}
```

- [ ] **Step 3: Run tests — should pass (no behavior change)**

```
nix develop -c zig build test -Doptimize=Debug
```

Expected: all 86+ tests pass. The existing `test_coloring.zig` tests verify `iterToCell` produces the same outputs.

- [ ] **Step 4: Commit**

```bash
git add src/core/coloring.zig
git commit -m "refactor: extract iterToColor from iterToCell for blocks-mode reuse"
```

Do NOT include Co-Authored-By lines.

---

### Task 2: `GlyphMode` Enum + `iterToBlock` Function

**Files:**
- Modify: `src/core/coloring.zig`
- Modify: `tests/unit/test_coloring.zig`

- [ ] **Step 1: Write failing tests — APPEND to `tests/unit/test_coloring.zig`**

Add at the end of the file:

```zig
test "iterToBlock all-interior returns space with black" {
	const block = coloring.iterToBlock(mandelbrot.INTERIOR, mandelbrot.INTERIOR, mandelbrot.INTERIOR, mandelbrot.INTERIOR, 256);
	try testing.expect(block.all_interior);
	try testing.expectEqualStrings(" ", block.char_bytes);
	try testing.expectEqual(@as(u8, 0), block.fg.r);
	try testing.expectEqual(@as(u8, 0), block.fg.g);
	try testing.expectEqual(@as(u8, 0), block.fg.b);
	try testing.expectEqual(@as(u8, 0), block.bg.r);
	try testing.expectEqual(@as(u8, 0), block.bg.g);
	try testing.expectEqual(@as(u8, 0), block.bg.b);
}

test "iterToBlock all-exterior uniform returns full block" {
	// All 4 sub-pixels have identical iter values
	const block = coloring.iterToBlock(50.0, 50.0, 50.0, 50.0, 256);
	try testing.expect(!block.all_interior);
	try testing.expectEqualStrings("█", block.char_bytes);
	// BG should be black since all went to one group
	try testing.expectEqual(@as(u8, 0), block.bg.r);
	try testing.expectEqual(@as(u8, 0), block.bg.g);
	try testing.expectEqual(@as(u8, 0), block.bg.b);
	// FG should be palette color for iter=50
	const expected_fg = coloring.iterToColor(50.0, 256);
	try testing.expectEqual(expected_fg.r, block.fg.r);
	try testing.expectEqual(expected_fg.g, block.fg.g);
	try testing.expectEqual(expected_fg.b, block.fg.b);
}

test "iterToBlock all-exterior split returns correct quadrant" {
	// tl=10, tr=20, bl=100, br=110 — median is 60
	// fg_mask: tl(10)<60 → 0, tr(20)<60 → 0, bl(100)≥60 → 1, br(110)≥60 → 1
	// fg_mask = 0b0011 → bottom half "▄"
	const block = coloring.iterToBlock(10.0, 20.0, 100.0, 110.0, 256);
	try testing.expect(!block.all_interior);
	try testing.expectEqualStrings("▄", block.char_bytes);
}

test "iterToBlock mixed interior/exterior returns correct quadrant" {
	// tl=INTERIOR, tr=50, bl=INTERIOR, br=50
	// Mixed case: fg_mask has exterior bits set, interior goes to BG
	// tr=bit 2, br=bit 0 → fg_mask = 0b0101 → "▐" (right half)
	const block = coloring.iterToBlock(mandelbrot.INTERIOR, 50.0, mandelbrot.INTERIOR, 50.0, 256);
	try testing.expect(!block.all_interior);
	try testing.expectEqualStrings("▐", block.char_bytes);
	// BG must be black (interior)
	try testing.expectEqual(@as(u8, 0), block.bg.r);
	try testing.expectEqual(@as(u8, 0), block.bg.g);
	try testing.expectEqual(@as(u8, 0), block.bg.b);
	// FG must be palette(50)
	const expected_fg = coloring.iterToColor(50.0, 256);
	try testing.expectEqual(expected_fg.r, block.fg.r);
}

test "iterToBlock quadrant lookup table — all 16 fg_masks produce expected chars" {
	// We build a 2x2 grid where FG sub-pixels have iter=100 and BG have iter=10.
	// Median is 55, so any sub-pixel at 100 gets fg_mask bit set.
	const fg_val: f64 = 100.0;
	const bg_val: f64 = 10.0;

	const cases = [_]struct { mask: u4, expected: []const u8 }{
		.{ .mask = 0b0000, .expected = " " },
		.{ .mask = 0b0001, .expected = "▗" },
		.{ .mask = 0b0010, .expected = "▖" },
		.{ .mask = 0b0011, .expected = "▄" },
		.{ .mask = 0b0100, .expected = "▝" },
		.{ .mask = 0b0101, .expected = "▐" },
		.{ .mask = 0b0110, .expected = "▞" },
		.{ .mask = 0b0111, .expected = "▟" },
		.{ .mask = 0b1000, .expected = "▘" },
		.{ .mask = 0b1001, .expected = "▚" },
		.{ .mask = 0b1010, .expected = "▌" },
		.{ .mask = 0b1011, .expected = "▙" },
		.{ .mask = 0b1100, .expected = "▀" },
		.{ .mask = 0b1101, .expected = "▜" },
		.{ .mask = 0b1110, .expected = "▛" },
		.{ .mask = 0b1111, .expected = "█" },
	};

	for (cases) |c| {
		const tl = if (c.mask & 0b1000 != 0) fg_val else bg_val;
		const tr = if (c.mask & 0b0100 != 0) fg_val else bg_val;
		const bl = if (c.mask & 0b0010 != 0) fg_val else bg_val;
		const br = if (c.mask & 0b0001 != 0) fg_val else bg_val;
		const block = coloring.iterToBlock(tl, tr, bl, br, 256);
		// For mask 0b0000 (all-BG) we expect " " but algorithm puts "all in BG group"
		// which is handled specially. For mask 0b1111 (all-FG) we get "█".
		// All intermediate masks should match the lookup table.
		try testing.expectEqualStrings(c.expected, block.char_bytes);
	}
}
```

- [ ] **Step 2: Run tests — should fail**

```
nix develop -c zig build test -Doptimize=Debug
```

Expected: compile errors — `iterToBlock`, `GlyphMode`, `BlockCell` not found.

- [ ] **Step 3: Add `GlyphMode`, `BlockCell`, quadrant lookup, and `iterToBlock` to `src/core/coloring.zig`**

Add AFTER the existing `Cell` type definition, before the `density_chars` constant:

```zig
/// Glyph rendering mode. Density uses ASCII intensity characters;
/// blocks uses Unicode quadrant characters for 2×2 sub-pixel shape fidelity.
pub const GlyphMode = enum { density, blocks };

/// Result of iterToBlock — UTF-8 char bytes + FG/BG colors for a terminal cell.
pub const BlockCell = struct {
	/// UTF-8 bytes for the glyph (1 byte for space, 3 bytes for block chars).
	char_bytes: []const u8,
	fg: RGB,
	bg: RGB,
	all_interior: bool,
};

/// 2×2 quadrant glyph lookup table. Index = 4-bit fg_mask where
/// bit 3 = top-left, bit 2 = top-right, bit 1 = bottom-left, bit 0 = bottom-right.
/// Each position is set if that sub-pixel is in the FG group (above median iter
/// or exterior in mixed cells).
const quadrant_glyphs = [16][]const u8{
	" ",  // 0b0000
	"▗",  // 0b0001 — br
	"▖",  // 0b0010 — bl
	"▄",  // 0b0011 — bl+br (bottom half)
	"▝",  // 0b0100 — tr
	"▐",  // 0b0101 — tr+br (right half)
	"▞",  // 0b0110 — tr+bl (anti-diagonal)
	"▟",  // 0b0111 — tr+bl+br
	"▘",  // 0b1000 — tl
	"▚",  // 0b1001 — tl+br (diagonal)
	"▌",  // 0b1010 — tl+bl (left half)
	"▙",  // 0b1011 — tl+bl+br
	"▀",  // 0b1100 — tl+tr (top half)
	"▜",  // 0b1101 — tl+tr+br
	"▛",  // 0b1110 — tl+tr+bl
	"█",  // 0b1111 — all
};
```

Then add AFTER the existing `iterToColor` function (added in Task 1):

```zig
/// Render a 2×2 block of iteration values into a quadrant char + FG/BG colors.
///
/// The 3-case algorithm:
/// - All 4 interior: space + black (trivial).
/// - Mixed interior/exterior: interior sub-pixels go to BG (black),
///   exterior sub-pixels go to FG (mean of exterior iter values → palette).
/// - All 4 exterior: median-split clustering. Sub-pixels with iter ≥ median
///   go to FG group; rest go to BG. If all four are equal, emit "█" with
///   FG = palette(mean), BG = black (degenerate single-color case).
pub fn iterToBlock(tl: f64, tr: f64, bl: f64, br: f64, max_iter: u32) BlockCell {
	const iters = [4]f64{ tl, tr, bl, br };

	// Determine interior mask. Bit positions: tl=3, tr=2, bl=1, br=0.
	var interior_mask: u4 = 0;
	if (tl == mandelbrot.INTERIOR) interior_mask |= 0b1000;
	if (tr == mandelbrot.INTERIOR) interior_mask |= 0b0100;
	if (bl == mandelbrot.INTERIOR) interior_mask |= 0b0010;
	if (br == mandelbrot.INTERIOR) interior_mask |= 0b0001;

	const black = RGB{ .r = 0, .g = 0, .b = 0 };

	// Case 1: all interior
	if (interior_mask == 0b1111) {
		return .{ .char_bytes = " ", .fg = black, .bg = black, .all_interior = true };
	}

	// Case 3: mixed — interior → BG, exterior → FG
	if (interior_mask != 0b0000) {
		const fg_mask: u4 = ~interior_mask;
		// Compute mean of exterior iter values
		var sum: f64 = 0;
		var count: f64 = 0;
		for (iters, 0..) |v, i| {
			const bit: u4 = @as(u4, 1) << @intCast(3 - i);
			if (fg_mask & bit != 0) {
				sum += v;
				count += 1;
			}
		}
		const mean_iter = if (count > 0) sum / count else 0;
		const fg = iterToColor(mean_iter, max_iter);
		return .{
			.char_bytes = quadrant_glyphs[fg_mask],
			.fg = fg,
			.bg = black,
			.all_interior = false,
		};
	}

	// Case 2: all exterior — median-split two-color clustering
	// Sort iters ascending to find median
	var sorted = iters;
	std.mem.sort(f64, &sorted, {}, std.sort.asc(f64));
	const median = (sorted[1] + sorted[2]) / 2.0;

	var fg_mask: u4 = 0;
	if (tl >= median) fg_mask |= 0b1000;
	if (tr >= median) fg_mask |= 0b0100;
	if (bl >= median) fg_mask |= 0b0010;
	if (br >= median) fg_mask |= 0b0001;

	// Degenerate case: all values equal → fg_mask is all 1s (all ≥ median).
	// Emit full block with single color.
	if (fg_mask == 0b1111) {
		const mean = (tl + tr + bl + br) / 4.0;
		return .{
			.char_bytes = quadrant_glyphs[0b1111],
			.fg = iterToColor(mean, max_iter),
			.bg = black,
			.all_interior = false,
		};
	}

	// Compute means for FG and BG groups
	var fg_sum: f64 = 0;
	var fg_count: f64 = 0;
	var bg_sum: f64 = 0;
	var bg_count: f64 = 0;
	for (iters, 0..) |v, i| {
		const bit: u4 = @as(u4, 1) << @intCast(3 - i);
		if (fg_mask & bit != 0) {
			fg_sum += v;
			fg_count += 1;
		} else {
			bg_sum += v;
			bg_count += 1;
		}
	}
	const fg_mean = fg_sum / fg_count;
	const bg_mean = bg_sum / bg_count;

	return .{
		.char_bytes = quadrant_glyphs[fg_mask],
		.fg = iterToColor(fg_mean, max_iter),
		.bg = iterToColor(bg_mean, max_iter),
		.all_interior = false,
	};
}
```

- [ ] **Step 4: Ensure the test file imports `mandelbrot` module**

Check the top of `tests/unit/test_coloring.zig`. If it doesn't already import `mandelbrot`, add:

```zig
const mandelbrot = @import("mandelbrot");
```

The `coloring_tests` target in `build.zig` already has the mandelbrot import (required for the `INTERIOR` sentinel), so no build.zig change should be needed. Verify the test target looks like:

```zig
const coloring_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/test_coloring.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "coloring", .module = coloring_mod },
            .{ .name = "mandelbrot", .module = mandelbrot_mod },
        },
    }),
});
```

If the `mandelbrot` import is missing, add it.

- [ ] **Step 5: Run tests — should pass**

```
nix develop -c zig build test -Doptimize=Debug
```

All tests including 5 new blocks tests should pass.

- [ ] **Step 6: Commit**

```bash
git add src/core/coloring.zig tests/unit/test_coloring.zig build.zig
git commit -m "feat: GlyphMode + iterToBlock (median-split two-color quadrants)"
```

---

### Task 3: `key_g` Event for Glyph Mode Toggle

**Files:**
- Modify: `src/tui/input.zig`
- Modify: `tests/unit/test_input.zig`

- [ ] **Step 1: Write failing test — APPEND to `tests/unit/test_input.zig`**

Add at the end of the existing file:

```zig
test "parse 'g' as key_g" {
	const event = input.parseEvent("g");
	try testing.expectEqual(input.Event.key_g, event);
}
```

- [ ] **Step 2: Run — should fail**

```
nix develop -c zig build test -Doptimize=Debug
```

Expected: "no member named 'key_g' in Event union".

- [ ] **Step 3: Add `key_g` to the Event union in `src/tui/input.zig`**

In `src/tui/input.zig`, find the `Event` union definition. It looks roughly like:

```zig
pub const Event = union(enum) {
    key_q,
    key_plus,
    key_minus,
    key_bracket_open,
    key_bracket_close,
    key_i,
    // ... other variants ...
};
```

Add `key_g,` alongside the other single-character key variants (e.g., right after `key_i`):

```zig
    key_i,
    key_g,
```

- [ ] **Step 4: Parse 'g' byte in `parseEvent`**

In `parseEvent` (same file), find the single-byte switch. It looks like:

```zig
switch (bytes[0]) {
    'q' => return .key_q,
    '+' => return .key_plus,
    '-' => return .key_minus,
    '[' => return .key_bracket_open,
    ']' => return .key_bracket_close,
    'i' => return .key_i,
    // ...
}
```

Add a case for `'g'`:

```zig
    'i' => return .key_i,
    'g' => return .key_g,
```

- [ ] **Step 5: Run tests — should pass**

```
nix develop -c zig build test -Doptimize=Debug
```

- [ ] **Step 6: Commit**

```bash
git add src/tui/input.zig tests/unit/test_input.zig
git commit -m "feat: key_g event for glyph mode toggle"
```

---

### Task 4: `renderFrameFromBlocksBuffer` in Renderer

**Files:**
- Modify: `src/tui/renderer.zig`
- Modify: `tests/unit/test_renderer.zig`

- [ ] **Step 1: Write failing tests — APPEND to `tests/unit/test_renderer.zig`**

Add at the end of the existing file:

```zig
test "renderFrameFromBlocksBuffer produces ANSI + block chars" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	const state = renderer.RenderState{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.max_iter = 50,
		.show_info = false,
		.glyph_mode = .blocks,
	};

	// 2x2 display grid → 4x4 iter_buf
	const width: u16 = 2;
	const height: u16 = 2;
	const sub_width: u16 = width * 2;
	const sub_height: u16 = height * 2;
	const sub_count: usize = @as(usize, sub_width) * @as(usize, sub_height);

	// Fill with varying iter values so we get some block chars (not all space)
	var iter_buf: [16]f64 = undefined;
	for (&iter_buf, 0..) |*v, i| {
		v.* = @as(f64, @floatFromInt(i)) * 10.0 + 5.0;
	}
	_ = sub_count;

	const output = try renderer.renderFrameFromBlocksBuffer(state, width, height, &iter_buf, allocator);
	defer allocator.free(output);

	try testing.expect(output.len > 0);
	// Should contain ANSI escape
	try testing.expect(std.mem.indexOf(u8, output, "\x1b[") != null);
}

test "renderFrameFromBlocksBuffer all-interior produces mostly spaces" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	const mandelbrot_mod = @import("mandelbrot");

	const state = renderer.RenderState{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.max_iter = 50,
		.show_info = false,
		.glyph_mode = .blocks,
	};

	const width: u16 = 4;
	const height: u16 = 2;
	// 4x2 display → 8x4 iter_buf = 32 f64 values, all INTERIOR
	var iter_buf: [32]f64 = undefined;
	@memset(&iter_buf, mandelbrot_mod.INTERIOR);

	const output = try renderer.renderFrameFromBlocksBuffer(state, width, height, &iter_buf, allocator);
	defer allocator.free(output);

	// Count spaces (not counting spaces inside ANSI escape sequences or newlines)
	// Simpler check: output should not contain any of the block quadrant chars
	try testing.expect(std.mem.indexOf(u8, output, "█") == null);
	try testing.expect(std.mem.indexOf(u8, output, "▄") == null);
}

test "renderFrameFromBlocksBuffer is deterministic" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	const state = renderer.RenderState{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.max_iter = 50,
		.show_info = false,
		.glyph_mode = .blocks,
	};

	const width: u16 = 3;
	const height: u16 = 2;
	var iter_buf: [24]f64 = undefined;
	for (&iter_buf, 0..) |*v, i| {
		v.* = @as(f64, @floatFromInt(i)) * 5.0;
	}

	const out1 = try renderer.renderFrameFromBlocksBuffer(state, width, height, &iter_buf, allocator);
	defer allocator.free(out1);
	const out2 = try renderer.renderFrameFromBlocksBuffer(state, width, height, &iter_buf, allocator);
	defer allocator.free(out2);

	try testing.expectEqualSlices(u8, out1, out2);
}
```

- [ ] **Step 2: Run — should fail**

Expected: `renderFrameFromBlocksBuffer` not found, `glyph_mode` not a field of `RenderState`.

- [ ] **Step 3: Add `glyph_mode` to `RenderState`**

In `src/tui/renderer.zig`, find:

```zig
pub const RenderState = struct {
	center_re: f128,
	center_im: f128,
	zoom: f128,
	max_iter: u32,
	show_info: bool,
};
```

Replace with:

```zig
pub const RenderState = struct {
	center_re: f128,
	center_im: f128,
	zoom: f128,
	max_iter: u32,
	show_info: bool,
	glyph_mode: coloring.GlyphMode = .density,
};
```

- [ ] **Step 4: Implement `renderFrameFromBlocksBuffer`**

In `src/tui/renderer.zig`, ADD this new function AFTER the existing `renderFrameFromBuffer` function:

```zig
/// Render a blocks-mode frame from a 2×-resolution iteration buffer.
/// iter_buf must have (width * 2) * (render_height * 2) values, row-major.
/// Each terminal cell reads 4 sub-pixels and produces a Unicode block quadrant
/// with FG/BG colors via median-split clustering.
/// Caller owns the returned memory.
pub fn renderFrameFromBlocksBuffer(
	state: RenderState,
	width: u16,
	height: u16,
	iter_buf: []const f64,
	allocator: std.mem.Allocator,
) ![]u8 {
	const render_height: u16 = if (state.show_info and height > 1) height - 1 else height;
	const sub_width: u32 = @as(u32, width) * 2;

	var output: std.ArrayListUnmanaged(u8) = .{};

	// Each block cell emits ~30-40 bytes (color escape + 3-byte UTF-8 char).
	try output.ensureTotalCapacity(allocator, 6 + @as(usize, width) * @as(usize, render_height) * 40 + 300);

	// Cursor home
	try output.appendSlice(allocator, "\x1b[H");

	var last_fg_r: u8 = 255;
	var last_fg_g: u8 = 255;
	var last_fg_b: u8 = 255;
	var last_bg_r: u8 = 255;
	var last_bg_g: u8 = 255;
	var last_bg_b: u8 = 255;

	var row: u16 = 0;
	while (row < render_height) : (row += 1) {
		var col: u16 = 0;
		while (col < width) : (col += 1) {
			const sub_row: u32 = @as(u32, row) * 2;
			const sub_col: u32 = @as(u32, col) * 2;
			const tl_idx: usize = @as(usize, sub_row) * @as(usize, sub_width) + @as(usize, sub_col);
			const tr_idx: usize = tl_idx + 1;
			const bl_idx: usize = tl_idx + @as(usize, sub_width);
			const br_idx: usize = bl_idx + 1;

			const block = coloring.iterToBlock(
				iter_buf[tl_idx],
				iter_buf[tr_idx],
				iter_buf[bl_idx],
				iter_buf[br_idx],
				state.max_iter,
			);

			// Emit color escape only when FG or BG changes from previous cell
			if (block.fg.r != last_fg_r or block.fg.g != last_fg_g or block.fg.b != last_fg_b or
				block.bg.r != last_bg_r or block.bg.g != last_bg_g or block.bg.b != last_bg_b)
			{
				var color_buf: [64]u8 = undefined;
				const color_str = std.fmt.bufPrint(&color_buf, "\x1b[38;2;{d};{d};{d};48;2;{d};{d};{d}m", .{
					block.fg.r, block.fg.g, block.fg.b,
					block.bg.r, block.bg.g, block.bg.b,
				}) catch unreachable;
				try output.appendSlice(allocator, color_str);
				last_fg_r = block.fg.r;
				last_fg_g = block.fg.g;
				last_fg_b = block.fg.b;
				last_bg_r = block.bg.r;
				last_bg_g = block.bg.g;
				last_bg_b = block.bg.b;
			}

			try output.appendSlice(allocator, block.char_bytes);
		}
		if (row < render_height - 1) {
			try output.appendSlice(allocator, "\r\n");
		}
	}

	// Info bar (identical to density-mode renderer)
	if (state.show_info and height > 1) {
		try output.appendSlice(allocator, "\r\n");
		try output.appendSlice(allocator, "\x1b[0m\x1b[7m");

		var info_buf: [256]u8 = undefined;
		const cre_f64: f64 = @floatCast(state.center_re);
		const cim_f64: f64 = @floatCast(state.center_im);
		const zoom_f64: f64 = @floatCast(state.zoom);

		const info_str = std.fmt.bufPrint(&info_buf, " MANDELBROT_CENTER_RE={d:.15} MANDELBROT_CENTER_IM={d:.15} MANDELBROT_ZOOM={e} mandelbrot | iter={d} glyph=blocks", .{
			cre_f64, cim_f64, zoom_f64, state.max_iter,
		}) catch " [info too long]";

		const info_len = @min(info_str.len, @as(usize, width));
		try output.appendSlice(allocator, info_str[0..info_len]);

		var pad: usize = info_len;
		while (pad < width) : (pad += 1) {
			try output.append(allocator, ' ');
		}

		try output.appendSlice(allocator, "\x1b[0m");
	}

	return try output.toOwnedSlice(allocator);
}
```

- [ ] **Step 5: Update density-mode info bar to show glyph mode too**

In the existing `renderFrameFromBuffer` function, find the `info_str` bufPrint call. Change it from:

```zig
const info_str = std.fmt.bufPrint(&info_buf, " MANDELBROT_CENTER_RE={d:.15} MANDELBROT_CENTER_IM={d:.15} MANDELBROT_ZOOM={e} mandelbrot | iter={d}", .{
	cre_f64, cim_f64, zoom_f64, state.max_iter,
}) catch " [info too long]";
```

To:

```zig
const info_str = std.fmt.bufPrint(&info_buf, " MANDELBROT_CENTER_RE={d:.15} MANDELBROT_CENTER_IM={d:.15} MANDELBROT_ZOOM={e} mandelbrot | iter={d} glyph=density", .{
	cre_f64, cim_f64, zoom_f64, state.max_iter,
}) catch " [info too long]";
```

- [ ] **Step 6: Run tests — should pass**

```
nix develop -c zig build test -Doptimize=Debug
```

- [ ] **Step 7: Commit**

```bash
git add src/tui/renderer.zig tests/unit/test_renderer.zig
git commit -m "feat: renderFrameFromBlocksBuffer — 2×2 sub-pixel rendering with two-color quadrants"
```

---

### Task 5: App Integration (Cache, Dispatch, Key Handler)

**Files:**
- Modify: `src/tui/app.zig`

- [ ] **Step 1: Add import for coloring module**

At the top of `src/tui/app.zig`, add:

```zig
const coloring = @import("coloring");
```

After the existing imports. This requires `coloring` to be in the app module's imports in build.zig. Check `build.zig` — find the `app_mod` definition and confirm it includes:

```zig
.{ .name = "coloring", .module = coloring_mod },
```

If missing, add it. Also add it to the `app_tests` target's imports.

- [ ] **Step 2: Add `glyph_mode` field to AppState**

In `src/tui/app.zig`, find:

```zig
pub const AppState = struct {
	center_re: f128,
	center_im: f128,
	zoom: f128,
	max_iter: u32,
	base_iter: u32,
	show_info: bool,
	term_width: u16,
	term_height: u16,
	needs_redraw: bool,
	running: bool,
	drag_start: ?input.MousePos = null,
	did_drag: bool = false,
};
```

Add `glyph_mode`:

```zig
pub const AppState = struct {
	center_re: f128,
	center_im: f128,
	zoom: f128,
	max_iter: u32,
	base_iter: u32,
	show_info: bool,
	term_width: u16,
	term_height: u16,
	needs_redraw: bool,
	running: bool,
	drag_start: ?input.MousePos = null,
	did_drag: bool = false,
	glyph_mode: coloring.GlyphMode = .density,
};
```

- [ ] **Step 3: Add `key_g` case to `processEvent`**

In `src/tui/app.zig`, find the `switch (event)` in `processEvent`. Find the `.key_i` case. After it, add:

```zig
		.key_g => {
			// Cycle glyph mode: density → blocks → density
			s.glyph_mode = switch (s.glyph_mode) {
				.density => .blocks,
				.blocks => .density,
			};
			s.needs_redraw = true;
		},
```

- [ ] **Step 4: Add `glyph_mode` comparison to `viewportChanged`**

In `src/tui/app.zig`, find:

```zig
fn viewportChanged(old: AppState, new: AppState) bool {
	return old.center_re != new.center_re or
		old.center_im != new.center_im or
		old.zoom != new.zoom or
		old.max_iter != new.max_iter or
		old.term_width != new.term_width or
		old.term_height != new.term_height;
}
```

Replace with:

```zig
fn viewportChanged(old: AppState, new: AppState) bool {
	return old.center_re != new.center_re or
		old.center_im != new.center_im or
		old.zoom != new.zoom or
		old.max_iter != new.max_iter or
		old.term_width != new.term_width or
		old.term_height != new.term_height or
		old.glyph_mode != new.glyph_mode;
}
```

Glyph mode change requires cache invalidation because Level 0's dimensions change.

- [ ] **Step 5: Update render path to use sub-pixel multiplier**

In `src/tui/app.zig`, find the render block inside `run()` that starts with:

```zig
		if (state.needs_redraw) {
			const render_height: u16 = if (state.show_info and state.term_height > 1)
				state.term_height - 1
			else
				state.term_height;
			const pixel_count = @as(usize, state.term_width) * @as(usize, render_height);

			const iter_buf = try allocator.alloc(f64, pixel_count);
			defer allocator.free(iter_buf);
            // ... cache check + compute + render ...
```

Replace the entire `if (state.needs_redraw) { ... }` block with:

```zig
		if (state.needs_redraw) {
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

			// Dispatch to the correct renderer based on glyph mode
			const frame = switch (state.glyph_mode) {
				.density => try renderer.renderFrameFromBuffer(.{
					.center_re = state.center_re,
					.center_im = state.center_im,
					.zoom = state.zoom,
					.max_iter = state.max_iter,
					.show_info = state.show_info,
					.glyph_mode = state.glyph_mode,
				}, state.term_width, state.term_height, iter_buf, allocator),
				.blocks => try renderer.renderFrameFromBlocksBuffer(.{
					.center_re = state.center_re,
					.center_im = state.center_im,
					.zoom = state.zoom,
					.max_iter = state.max_iter,
					.show_info = state.show_info,
					.glyph_mode = state.glyph_mode,
				}, state.term_width, state.term_height, iter_buf, allocator),
			};
			defer allocator.free(frame);

			try stdout.writeAll(frame);
			try stdout.flush();
			state.needs_redraw = false;

			scheduler.requestWork();
		}
```

- [ ] **Step 6: Run tests — should pass**

```
nix develop -c zig build test -Doptimize=Debug
```

All existing tests should pass. The inline app tests for `processEvent` still work (they don't exercise the render path).

- [ ] **Step 7: Manual smoke test**

```
./build
./zig-out/bin/mandelbrot --single-frame 2>/dev/null | head -2
```

Should render density mode (default) — verify no crash.

- [ ] **Step 8: Commit**

```bash
git add src/tui/app.zig build.zig
git commit -m "feat: app dispatches blocks-mode render with 2x cache + key_g toggle"
```

---

### Task 6: CLI Flag + Env Var + Help Text

**Files:**
- Modify: `src/main.zig`

- [ ] **Step 1: Parse `MANDELBROT_SUBBLOCK` env var**

At the top of `main()` in `src/main.zig`, AFTER the existing env-var-parsing block (where center_re, center_im, zoom, etc. are parsed), but BEFORE the CLI flag parsing loop or arg processing finishes, we need a helper and the precedence logic.

First, add a helper function at file scope (after the existing `parseU16Env`):

```zig
fn parseBoolEnv(name: []const u8) bool {
	const val = std.posix.getenv(name) orelse return false;
	// Case-insensitive compare against true/1/yes/on
	var buf: [16]u8 = undefined;
	if (val.len >= buf.len) return false;
	for (val, 0..) |c, i| buf[i] = std.ascii.toLower(c);
	const lower = buf[0..val.len];
	return std.mem.eql(u8, lower, "true") or
		std.mem.eql(u8, lower, "1") or
		std.mem.eql(u8, lower, "yes") or
		std.mem.eql(u8, lower, "on");
}
```

- [ ] **Step 2: Add `coloring` import to main.zig**

At the top of `src/main.zig`, after the existing imports, add:

```zig
const coloring = @import("coloring");
```

This requires the exe's module in `build.zig` to have `coloring` as an import. Find the `exe` definition in `build.zig` and add to its `imports`:

```zig
.{ .name = "coloring", .module = coloring_mod },
```

Also add to `unit_tests` target imports if it shares the exe's module config.

- [ ] **Step 3: Add CLI flag + env var precedence logic**

In `src/main.zig` `main()`, find the arg-parsing `while (i < args.len)` loop. Add a `cli_glyph_mode` variable at the same level as `single_frame` etc.:

```zig
	var single_frame = false;
	var bench_zoom_n: ?u32 = null;
	var bench_quiet = false;
	var cli_glyph_mode: ?coloring.GlyphMode = null;
```

Then inside the loop, add a new flag handler. Find where `--bench-quiet` is handled; after that block, add:

```zig
		if (std.mem.startsWith(u8, arg, "--glyph=")) {
			const mode_str = arg["--glyph=".len..];
			if (std.mem.eql(u8, mode_str, "density")) {
				cli_glyph_mode = .density;
			} else if (std.mem.eql(u8, mode_str, "blocks")) {
				cli_glyph_mode = .blocks;
			} else {
				try stderr.writeAll("--glyph= must be 'density' or 'blocks'\n");
				try stderr.flush();
				return error.BadCliArg;
			}
			continue;
		}
```

After the arg-parsing loop (where state is being built from env vars), add the glyph mode precedence logic. Find where state.center_re etc. are set, and add after:

```zig
	// Glyph mode: default → env var → CLI flag (later wins)
	if (parseBoolEnv("MANDELBROT_SUBBLOCK")) {
		state.glyph_mode = .blocks;
	}
	if (cli_glyph_mode) |m| {
		state.glyph_mode = m;
	}
```

- [ ] **Step 4: Update help text**

In `src/main.zig`, find the help string (the `\\` multiline block that starts with "mandelbrot -- interactive..."). Add lines for the new flag and env var.

In the `Options:` section, after the existing `--bench-quiet` line:

```
\\  --glyph=MODE               Initial glyph mode: density (default) or blocks
```

In the `Environment variables:` section, after the existing `MANDELBROT_ROWS` line:

```
\\  MANDELBROT_SUBBLOCK    Set to true/1/yes/on to start in blocks mode
```

In the `Controls:` section, after the existing `i              Toggle info bar` line:

```
\\  g              Cycle glyph mode (density, blocks)
```

- [ ] **Step 5: Run tests — should pass**

```
./test
```

- [ ] **Step 6: Manual smoke test — density mode still works**

```
./build
./zig-out/bin/mandelbrot --single-frame 2>/dev/null | head -2
```

Should render density mode.

- [ ] **Step 7: Manual smoke test — blocks mode via flag**

```
./zig-out/bin/mandelbrot --glyph=blocks --single-frame 2>/dev/null | head -5
```

Should render with block-quadrant characters visible (▀▄▌▐█▖▗▘ etc.).

- [ ] **Step 8: Manual smoke test — blocks mode via env var**

```
MANDELBROT_SUBBLOCK=1 ./zig-out/bin/mandelbrot --single-frame 2>/dev/null | head -5
```

Same as previous — should show block chars.

- [ ] **Step 9: Manual smoke test — CLI flag overrides env var**

```
MANDELBROT_SUBBLOCK=1 ./zig-out/bin/mandelbrot --glyph=density --single-frame 2>/dev/null | head -5
```

Should render density (not blocks) because CLI wins over env var.

- [ ] **Step 10: Commit**

```bash
git add src/main.zig build.zig
git commit -m "feat: --glyph=MODE CLI flag + MANDELBROT_SUBBLOCK env var"
```

---

### Task 7: CLI Tests + Documentation

**Files:**
- Modify: `tests/cli/test_cli.bash`
- Modify: `PLAN.md`
- Modify: `CODE_MINIMAP.md`

- [ ] **Step 1: Add CLI tests for blocks mode**

In `tests/cli/test_cli.bash`, find the last `pass/fail` test block. AFTER it, add:

```bash
# Test: --glyph=blocks produces output with block-quadrant chars
output=$("$BINARY" --glyph=blocks --single-frame 2>/dev/null)
rc=$?
# Grep for any of the block chars. Using grep -E with alternation for UTF-8 chars.
if [ "$rc" -eq 0 ] && echo "$output" | grep -qE $'\xe2\x96\x80|\xe2\x96\x84|\xe2\x96\x8c|\xe2\x96\x90|\xe2\x96\x88'; then
    pass "--glyph=blocks produces block-quadrant chars"
else
    fail "--glyph=blocks produces block-quadrant chars" "rc=$rc"
fi

# Test: MANDELBROT_SUBBLOCK=1 produces block-quadrant chars
output=$(MANDELBROT_SUBBLOCK=1 "$BINARY" --single-frame 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -qE $'\xe2\x96\x80|\xe2\x96\x84|\xe2\x96\x8c|\xe2\x96\x90|\xe2\x96\x88'; then
    pass "MANDELBROT_SUBBLOCK=1 produces block-quadrant chars"
else
    fail "MANDELBROT_SUBBLOCK=1 produces block-quadrant chars" "rc=$rc"
fi

# Test: --glyph=density overrides MANDELBROT_SUBBLOCK=1
output=$(MANDELBROT_SUBBLOCK=1 "$BINARY" --glyph=density --single-frame 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && ! echo "$output" | grep -qE $'\xe2\x96\x80|\xe2\x96\x84|\xe2\x96\x8c|\xe2\x96\x90|\xe2\x96\x88'; then
    pass "--glyph=density overrides MANDELBROT_SUBBLOCK=1"
else
    fail "--glyph=density overrides MANDELBROT_SUBBLOCK=1" "rc=$rc"
fi
```

Note: The bash `$'...'` syntax produces ANSI-C escape sequences. `\xe2\x96\x80` is UTF-8 for `▀` (U+2580), `\xe2\x96\x84` is `▄`, `\xe2\x96\x8c` is `▌`, `\xe2\x96\x90` is `▐`, `\xe2\x96\x88` is `█`. We test a subset of the block chars — any of them appearing is enough evidence that blocks mode is active.

- [ ] **Step 2: Run CLI tests — should pass**

```bash
./test
```

- [ ] **Step 3: Update PLAN.md**

Edit `PLAN.md`. In the "Completed" section, add at the end (replacing the date with today's):

```markdown
- [x] Block quadrant glyph mode (2×2 sub-pixel rendering) — ~2026-04-19 EST
```

In the "Future Enhancements" section, optionally add:

```markdown
- [ ] Braille glyph mode (2×4 sub-pixels) — deferred; contrast is lower than blocks but gives 8× resolution
- [ ] Sextants glyph mode (2×3 sub-pixels) — deferred; doesn't align with 2× cache pyramid
```

- [ ] **Step 4: Update CODE_MINIMAP.md**

Edit `CODE_MINIMAP.md`. Find the `src/core/coloring.zig` section. Update it:

```markdown
## `src/core/coloring.zig`
- `iterToCell(iter, max_iter)` — density mode: cyclic density char + palette color
- `iterToBlock(tl, tr, bl, br, max_iter)` — blocks mode: 2×2 sub-pixels → Unicode quadrant + FG/BG colors (median-split clustering)
- `iterToColor(iter, max_iter)` — shared palette primitive used by both iterToCell and iterToBlock
- `Cell` — density mode result: char + color + is_interior
- `BlockCell` — blocks mode result: char_bytes (UTF-8) + fg + bg + all_interior
- `GlyphMode` — enum { density, blocks }
- `RGB` — struct: r, g, b
- `quadrant_glyphs` — 16-entry UTF-8 lookup table (0b0000=space, 0b1111=█)
```

Find `src/tui/renderer.zig` section. Update it:

```markdown
## `src/tui/renderer.zig`
- `renderFrame(state, width, height, allocator)` — convenience: compute + render in one call (density only)
- `renderFrameFromBuffer(state, width, height, iter_buf, allocator)` — density-mode render from pre-computed buffer
- `renderFrameFromBlocksBuffer(state, width, height, iter_buf, allocator)` — blocks-mode render from 2×-resolution pre-computed buffer
- `RenderState` — struct: center, zoom, max_iter, show_info, glyph_mode
```

Find `src/tui/input.zig` section. Update the Event list to include `key_g`:

```markdown
- `Event` — tagged union: key_q, key_plus, key_minus, key_g, arrows, mouse_left_press/release, mouse_right_press/release, mouse_drag, scroll_up/down, ctrl_c, resize, unknown
```

Find `src/main.zig` section. Update `main()` line:

```markdown
- `main()` — entry point: arg parsing (--help, --about, --single-frame, --bench-zoom-sequence, --bench-quiet, --glyph=MODE), env var injection (incl. MANDELBROT_SUBBLOCK), app launch
- `parseBoolEnv(name)` — case-insensitive parse of true/1/yes/on boolean env vars
```

Find `src/tui/app.zig` section. Update AppState line:

```markdown
- `AppState` — struct: center, zoom, iters, info, dimensions, flags, drag state, glyph mode
```

- [ ] **Step 5: Final test run**

```bash
./test
```

All tests pass.

- [ ] **Step 6: Commit**

```bash
git add tests/cli/test_cli.bash PLAN.md CODE_MINIMAP.md
git commit -m "docs+test: CLI tests for blocks mode + update PLAN.md, CODE_MINIMAP.md"
```

---

## Self-Review

**Spec coverage:**
- ✅ GlyphMode enum (Task 2)
- ✅ iterToBlock with 3-case algorithm (all-interior / all-exterior / mixed) (Task 2)
- ✅ Quadrant lookup table (16 chars) (Task 2)
- ✅ BlockCell struct with char_bytes + fg + bg + all_interior (Task 2)
- ✅ iterToColor shared primitive refactored out of iterToCell (Task 1)
- ✅ renderFrameFromBlocksBuffer in renderer (Task 4)
- ✅ glyph_mode field on RenderState (Task 4)
- ✅ key_g event parsing (Task 3)
- ✅ AppState.glyph_mode + cycle via key_g (Task 5)
- ✅ viewportChanged includes glyph_mode (cache invalidation on mode change) (Task 5)
- ✅ App render path uses sub_mul for buffer dims, dispatches based on mode (Task 5)
- ✅ Cache init uses multiplied dims (Task 5)
- ✅ --glyph=MODE CLI flag (Task 6)
- ✅ MANDELBROT_SUBBLOCK env var with case-insensitive true/1/yes/on (Task 6)
- ✅ CLI flag overrides env var (Task 6)
- ✅ Info bar includes "glyph=density" or "glyph=blocks" (Task 4)
- ✅ Help text updated for flag, env var, and `g` key (Task 6)
- ✅ Unit tests for iterToBlock all 3 cases + full lookup table (Task 2)
- ✅ Unit tests for renderFrameFromBlocksBuffer (Task 4)
- ✅ Unit test for key_g parsing (Task 3)
- ✅ CLI tests: blocks via flag, blocks via env var, flag overrides env var (Task 7)

**Placeholder scan:** No TBDs, TODOs, or incomplete sections. All code blocks complete.

**Type consistency:**
- `GlyphMode` enum values (`.density`, `.blocks`) used consistently across coloring, renderer, app, main
- `BlockCell` fields (char_bytes, fg, bg, all_interior) consistent between coloring definition and renderer usage
- `RenderState.glyph_mode` field added in Task 4, used in Task 5 dispatch
- `key_g` consistent between input.zig (Task 3) and app.zig (Task 5)
- `parseBoolEnv` helper used only in main.zig (Task 6)
- `cache_stack.initForViewport` signature unchanged — caller passes already-multiplied dims (Task 5)
- Sub-pixel multiplier `sub_mul` introduced in Task 5 as `u16`, used for buf_width/buf_height calculation

#!/usr/bin/env bash
set -u

errors=0
tests=0
passed=0

pass() {
	tests=$((tests + 1))
	passed=$((passed + 1))
	echo "  PASS: $1"
}

fail() {
	tests=$((tests + 1))
	errors=$((errors + 1))
	echo "  FAIL: $1"
	[ -n "${2:-}" ] && echo "        $2"
}

BINARY="${MANDELBROT_BIN:-./zig-out/bin/mandelbrot}"

if [ ! -x "$BINARY" ]; then
	echo "Binary not found at $BINARY — building..."
	nix develop -c zig build -Doptimize=Debug
fi

echo "=== CLI Tests ==="

# Test: --help exits 0
output=$("$BINARY" --help 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "Usage:"; then
	pass "--help exits 0 with usage text"
else
	fail "--help exits 0 with usage text" "rc=$rc"
fi

# Test: -h exits 0
output=$("$BINARY" -h 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "Usage:"; then
	pass "-h exits 0 with usage text"
else
	fail "-h exits 0 with usage text" "rc=$rc"
fi

# Test: --about prints version
output=$("$BINARY" --about 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "mandelbrot v"; then
	pass "--about prints version"
else
	fail "--about prints version" "rc=$rc output=$output"
fi

# Test: --single-frame produces output with env var injection
output=$(MANDELBROT_CENTER_RE="-0.5" MANDELBROT_CENTER_IM="0.0" MANDELBROT_ZOOM="1.0" \
	MANDELBROT_MAX_ITER="50" MANDELBROT_COLS="20" MANDELBROT_ROWS="10" \
	"$BINARY" --single-frame 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && [ -n "$output" ]; then
	pass "--single-frame produces output"
else
	fail "--single-frame produces output" "rc=$rc len=${#output}"
fi

# Test: --single-frame with info bar shows restore command
output=$(MANDELBROT_CENTER_RE="-0.7435669" MANDELBROT_CENTER_IM="0.1314023" \
	MANDELBROT_ZOOM="100" MANDELBROT_MAX_ITER="200" \
	MANDELBROT_COLS="80" MANDELBROT_ROWS="24" \
	"$BINARY" --single-frame 2>/dev/null)
if echo "$output" | grep -q "MANDELBROT"; then
	pass "--single-frame info bar shows restore command"
else
	fail "--single-frame info bar shows restore command"
fi

# Test: --single-frame is deterministic
output1=$(MANDELBROT_CENTER_RE="-0.5" MANDELBROT_CENTER_IM="0.0" MANDELBROT_ZOOM="1.0" \
	MANDELBROT_MAX_ITER="50" MANDELBROT_COLS="10" MANDELBROT_ROWS="5" \
	"$BINARY" --single-frame 2>/dev/null)
output2=$(MANDELBROT_CENTER_RE="-0.5" MANDELBROT_CENTER_IM="0.0" MANDELBROT_ZOOM="1.0" \
	MANDELBROT_MAX_ITER="50" MANDELBROT_COLS="10" MANDELBROT_ROWS="5" \
	"$BINARY" --single-frame 2>/dev/null)
if [ "$output1" = "$output2" ]; then
	pass "--single-frame is deterministic"
else
	fail "--single-frame is deterministic" "outputs differ"
fi

# Test: --bench-zoom-sequence produces summary output
output=$("$BINARY" --bench-zoom-sequence 3 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "Total:" && echo "$output" | grep -q "Avg/frame:"; then
	pass "--bench-zoom-sequence 3 produces Total and Avg/frame"
else
	fail "--bench-zoom-sequence 3 produces Total and Avg/frame" "rc=$rc"
fi

# Test: --bench-zoom-sequence + --bench-quiet suppresses per-frame output
output=$("$BINARY" --bench-zoom-sequence 3 --bench-quiet 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "Total:" && ! echo "$output" | grep -q "Frame 1"; then
	pass "--bench-quiet suppresses per-frame output"
else
	fail "--bench-quiet suppresses per-frame output" "rc=$rc"
fi
# Test: debug build runs without crash
output=$("$BINARY" --about 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
	pass "debug build runs without crash"
else
	fail "debug build runs without crash" "rc=$rc"
fi

# Test: --glyph=blocks produces output with block-quadrant chars
output=$("$BINARY" --glyph=blocks --single-frame 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -qE $'\xe2\x96\x80|\xe2\x96\x84|\xe2\x96\x8c|\xe2\x96\x90|\xe2\x96\x88'; then
	pass "--glyph=blocks produces block-quadrant chars"
else
	fail "--glyph=blocks produces block-quadrant chars" "rc=$rc"
fi

# Test: MANDELBROT_SUBBLOCK=1 env var activates blocks mode
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

# Test: --kitty without env support and without --force-kitty exits non-zero
env -i "$BINARY" --kitty --single-frame >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
	pass "--kitty without env support exits non-zero"
else
	fail "--kitty without env support exits non-zero" "rc=$rc"
fi

# Test: --kitty --force-kitty produces kitty graphics escape sequences
output=$(env -i "$BINARY" --kitty --force-kitty --single-frame 2>/dev/null)
rc=$?
# Kitty graphics protocol opens with ESC _ G
if [ "$rc" -eq 0 ] && printf '%s' "$output" | grep -qE $'\x1b_G'; then
	pass "--kitty --force-kitty produces kitty graphics escapes"
else
	fail "--kitty --force-kitty produces kitty graphics escapes" "rc=$rc"
fi

# Test: --kitty in a recognized terminal env (TERM_PROGRAM=ghostty) succeeds
output=$(env -i TERM_PROGRAM=ghostty "$BINARY" --kitty --single-frame 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$output" | grep -qE $'\x1b_G'; then
	pass "--kitty with TERM_PROGRAM=ghostty produces kitty escapes"
else
	fail "--kitty with TERM_PROGRAM=ghostty produces kitty escapes" "rc=$rc"
fi

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

# Test: --animate with --hold-ms adds time to total wall-clock (only on systems where `date +%s%N` works)
if date +%s%N 2>/dev/null | grep -q '[0-9]\{19,\}'; then
	start_ns=$(date +%s%N)
	"$BINARY" --animate --duration 0.1 --fps 10 --zoom-to 10 --exit-after --hold-ms 300 >/dev/null 2>&1
	end_ns=$(date +%s%N)
	elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
	if [ "$elapsed_ms" -ge 300 ]; then
		pass "--hold-ms adds delay to total wall-clock"
	else
		fail "--hold-ms adds delay to total wall-clock" "elapsed=${elapsed_ms}ms (expected >= 300ms)"
	fi
else
	# macOS's BSD date doesn't support %N. Skip this test.
	pass "--hold-ms adds delay (skipped: date +%s%N unsupported)"
fi

echo ""
echo "CLI Tests: $passed/$tests passed, $errors failed"
exit "$errors"

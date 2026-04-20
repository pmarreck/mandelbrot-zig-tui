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

echo ""
echo "CLI Tests: $passed/$tests passed, $errors failed"
exit "$errors"

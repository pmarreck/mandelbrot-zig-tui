#!/usr/bin/env bash
# tmux-based integration tests for mandelbrot.
#
# Drives the binary inside a real PTY via tmux, sends keystrokes, captures
# the rendered cell content, and asserts on what the user would actually
# see. This is the closest we can get to end-to-end UI testing without a
# graphical harness.
#
# Synchronization is event-driven, NOT poll-and-sleep:
#   - The app, when run with MANDELBROT_FRAME_MARKER=1, emits the APC
#     sequence ESC _ = F R A M E = ESC \ after every frame flush. APC is
#     silently consumed by terminals (invisible), but tmux's pipe-pane
#     captures it raw.
#   - Each test attaches a pipe-pane sink to a FIFO, runs `tr` to convert
#     ESC bytes to newlines so a line-oriented `grep --line-buffered`
#     can see the marker, and uses `read -t TIMEOUT -u FD` to block until
#     the next marker arrives.
#   - That gives us "wait for next render" with zero polling and a hard
#     timeout to fail loudly instead of hanging.
#
# Limitation: tmux capture-pane returns rendered cell text, NOT raw escape
# sequences — so we can't assert on kitty graphics protocol bytes from
# here (those become "image cells" capture-pane shows as blank). Kitty
# wire-format assertions live in tests/cli/test_cli.bash via --single-frame.

set -u

if ! command -v tmux >/dev/null 2>&1; then
	echo "SKIP: tmux not on PATH"
	exit 77  # automake-style "skip" exit code
fi

BINARY="${1:-./zig-out/bin/mandelbrot}"
if [ ! -x "$BINARY" ]; then
	echo "ERROR: $BINARY not found or not executable"
	echo "Build first: zig build"
	exit 1
fi

# Absolute path so tmux can find it regardless of working directory.
BINARY=$(realpath "$BINARY")

# Per-test timeout for the frame-marker wait. 5 s is generous for a debug
# build doing the first heavy compute; trims tight on a release build.
WAIT_TIMEOUT=5

PASSED=0
FAILED=0

pass() {
	printf '  \033[32mPASS\033[0m: %s\n' "$1"
	PASSED=$((PASSED + 1))
}

fail() {
	printf '  \033[31mFAIL\033[0m: %s%s\n' "$1" "${2:+ ($2)}"
	FAILED=$((FAILED + 1))
}

# Set up a tmux session running the binary with frame-marker instrumentation,
# and start a `tr | grep` consumer that emits one line per frame to fd 4.
# Globals populated: SESSION, PIPE_PATH, MARKER_FD (a number, conventionally 4),
# MARKER_PROC_PID. Caller MUST call `teardown` to release them.
setup() {
	SESSION="mandel_test_$1_$$"
	PIPE_PATH=$(mktemp -u "${TMPDIR:-/tmp}/mandel_pipe.XXXXXX")
	mkfifo "$PIPE_PATH"
	local cols="${2:-140}" rows="${3:-24}"
	shift 3
	# Run inside `env` so the marker var is scoped to the test child.
	tmux new-session -d -s "$SESSION" -x "$cols" -y "$rows" \
		"env MANDELBROT_FRAME_MARKER=1 $BINARY $*"
	tmux pipe-pane -t "$SESSION" -o "cat > $PIPE_PATH"
	# tr ESC → newline so grep can match line-by-line; stdbuf disables tr's
	# default 4KB block buffering (without it, early markers sit in tr's
	# stdout buffer and never reach grep before the per-test timeout).
	# Read end is fd 4 in the parent shell.
	exec 4< <(stdbuf -o0 tr '\033' '\n' < "$PIPE_PATH" | grep --line-buffered '=FRAME=')
}

teardown() {
	tmux kill-session -t "$SESSION" 2>/dev/null || true
	exec 4<&- 2>/dev/null || true
	rm -f "$PIPE_PATH"
}

# Block until the next frame marker arrives on fd 4 (or timeout).
# Returns 0 on marker, non-zero on timeout. Each call consumes exactly one
# marker line, so subsequent waits will block for fresh frames.
wait_frame() {
	local _line
	IFS= read -r -t "$WAIT_TIMEOUT" -u 4 _line
}

# Drain any frame markers already queued on fd 4. Used after assertions to
# discard markers from background renders we don't care about.
drain_frames() {
	local _line
	while IFS= read -r -t 0 -u 4 _line; do :; done
}

capture() {
	tmux capture-pane -t "$SESSION" -p 2>/dev/null
}

echo "=== tmux Integration Tests ==="

# ── Test 1: initial render shows info bar ───────────────────────────────
setup "initial" 80 24
if wait_frame; then
	if capture | grep -q "MANDELBROT_CENTER_RE"; then
		pass "initial render shows info bar"
	else
		fail "initial render shows info bar" "info bar text not in pane"
	fi
else
	fail "initial render shows info bar" "no frame marker received"
fi
teardown

# ── Test 2: 'g' cycles glyph mode (density → blocks) ────────────────────
# 140 cols so the full info bar (incl. "glyph=density") fits — the default
# info bar formatting wraps past column ~136.
setup "gcycle" 140 24
wait_frame || true  # initial render
tmux send-keys -t "$SESSION" "g"
if wait_frame; then
	if capture | grep -q "glyph=blocks"; then
		pass "'g' cycles density → blocks"
	else
		fail "'g' cycles density → blocks" "info bar still says density"
	fi
else
	fail "'g' cycles density → blocks" "no frame marker after 'g'"
fi
teardown

# ── Test 3: '?' opens the help modal ────────────────────────────────────
setup "help_open" 80 24
wait_frame || true
tmux send-keys -t "$SESSION" "?"
if wait_frame && capture | grep -q "keys & mouse"; then
	pass "'?' opens help modal"
else
	fail "'?' opens help modal"
fi
teardown

# ── Test 4: 'h' also opens the help modal ───────────────────────────────
setup "help_h" 80 24
wait_frame || true
tmux send-keys -t "$SESSION" "h"
if wait_frame && capture | grep -q "keys & mouse"; then
	pass "'h' opens help modal"
else
	fail "'h' opens help modal"
fi
teardown

# ── Test 5: Esc closes the help modal and frame redraws ─────────────────
setup "help_close_esc" 80 24
wait_frame || true
tmux send-keys -t "$SESSION" "?"
wait_frame || true  # modal opened
tmux send-keys -t "$SESSION" Escape
if wait_frame; then
	out=$(capture)
	if echo "$out" | grep -q "MANDELBROT_CENTER_RE" && ! echo "$out" | grep -q "keys & mouse"; then
		pass "Esc closes help modal and frame redraws"
	else
		fail "Esc closes help modal and frame redraws" "modal still visible or info bar missing"
	fi
else
	fail "Esc closes help modal and frame redraws" "no frame marker after Esc"
fi
teardown

# ── Test 6: any key (i) closes the help modal ───────────────────────────
setup "help_close_any" 80 24
wait_frame || true
tmux send-keys -t "$SESSION" "?"
wait_frame || true
tmux send-keys -t "$SESSION" "i"
if wait_frame && ! capture | grep -q "keys & mouse"; then
	pass "any key (i) closes help modal"
else
	fail "any key (i) closes help modal"
fi
teardown

# ── Test 7: 'q' quits the app (session ends) ────────────────────────────
setup "quit" 80 24
wait_frame || true
tmux send-keys -t "$SESSION" "q"
# Block until tmux session ends (the program exited). A short bounded loop
# on `has-session` is unavoidable here — the only alternative is reading
# the FIFO which is no longer being fed once the process exits.
i=0
while [ $i -lt 50 ]; do
	if ! tmux has-session -t "$SESSION" 2>/dev/null; then break; fi
	# `read` with a tiny timeout on fd 4 acts as a "yield" — non-deterministic
	# but bounded by both the iteration cap (50) and the read timeout.
	IFS= read -r -t 0.05 -u 4 _ 2>/dev/null || true
	i=$((i + 1))
done
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
	pass "'q' quits the app"
else
	fail "'q' quits the app" "session still alive"
fi
teardown

# ── Test 8: SIGWINCH (tmux resize) triggers a redraw at the new size ────
setup "resize" 80 24
wait_frame || true
tmux resize-window -t "$SESSION" -x 100 -y 30 2>/dev/null
if wait_frame; then
	# At least one rendered line should be ≥ 90 chars (new wider width).
	max_w=$(capture | awk '{print length}' | sort -rn | head -1)
	if [ -n "$max_w" ] && [ "$max_w" -ge 90 ]; then
		pass "SIGWINCH (tmux resize) redraws at new width"
	else
		fail "SIGWINCH (tmux resize) redraws at new width" "max_line_width=$max_w"
	fi
else
	fail "SIGWINCH (tmux resize) redraws at new width" "no frame marker after resize"
fi
teardown

# ── Test 9: --force-kitty starts cleanly under tmux ─────────────────────
setup "force_kitty" 140 24 --force-kitty
if wait_frame && capture | grep -q "glyph=density"; then
	pass "--force-kitty starts cleanly under tmux"
else
	fail "--force-kitty starts cleanly under tmux"
fi
teardown

echo
echo "tmux Integration Tests: $PASSED/$((PASSED + FAILED)) passed, $FAILED failed"
exit $FAILED

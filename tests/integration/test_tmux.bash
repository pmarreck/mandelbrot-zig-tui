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
# AND mirror every byte the pane emits into a regular log file. Two consumers
# of that log:
#   - fd 4: a `tr ESC \n | grep =FRAME=` pipeline that surfaces frame markers
#     for event-driven wait_frame (no polling sleeps).
#   - LOG_PATH: the raw byte stream, available for post-hoc assertions on
#     specific escape sequences (e.g. kitty graphics commands like a=p,i=1
#     which capture-pane can't see because they don't materialize as cell
#     text).
# Globals populated: SESSION, LOG_PATH. Caller MUST call `teardown`.
setup() {
	SESSION="mandel_test_$1_$$"
	LOG_PATH=$(mktemp "${TMPDIR:-/tmp}/mandel_log.XXXXXX")
	local cols="${2:-140}" rows="${3:-24}"
	shift 3
	tmux new-session -d -s "$SESSION" -x "$cols" -y "$rows" \
		"env MANDELBROT_FRAME_MARKER=1 $BINARY $*"
	tmux pipe-pane -t "$SESSION" -o "cat > $LOG_PATH"
	# tail -F follows the file as it grows (works for any number of
	# concurrent readers, unlike a fifo which is consumed). tr ESC → \n
	# turns escape sequences into lines so grep can scan them. stdbuf
	# disables tr's default 4 KB block buffering — without it, early
	# markers sit in tr's stdout buffer and miss the per-test timeout.
	exec 4< <(stdbuf -o0 tail -n+1 -F "$LOG_PATH" 2>/dev/null | stdbuf -o0 tr '\033' '\n' | grep --line-buffered '=FRAME=')
}

teardown() {
	tmux kill-session -t "$SESSION" 2>/dev/null || true
	exec 4<&- 2>/dev/null || true
	rm -f "$LOG_PATH"
}

# Search the raw byte log for a fixed string. Returns 0 on hit, non-zero on
# miss. Used by tests that need to assert specific escape sequences emitted
# by the binary that capture-pane can't see (kitty graphics commands etc.).
log_contains() {
	grep -F -- "$1" "$LOG_PATH" >/dev/null 2>&1
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

# ── Test 10: kitty-mode '+' zoom updates the rendered frame ─────────────
# Catches the regression where the modal-close fast path was firing on
# every kitty redraw and short-circuiting around the iter compute even
# when the viewport had changed. Asserts that pressing '+' produces an
# info bar reflecting the new zoom level (we can't directly assert on
# the kitty image bytes because tmux capture-pane shows cell text only,
# but the info bar is plain text and zoom is part of it).
setup "kitty_zoom" 140 24 --kitty --force-kitty
wait_frame || true  # initial render
zoom_before=$(capture | grep -oE 'MANDELBROT_ZOOM=[^ ]+' | head -1)
tmux send-keys -t "$SESSION" "+"
if wait_frame; then
	zoom_after=$(capture | grep -oE 'MANDELBROT_ZOOM=[^ ]+' | head -1)
	if [ -n "$zoom_before" ] && [ -n "$zoom_after" ] && [ "$zoom_before" != "$zoom_after" ]; then
		pass "kitty + zoom updates info bar (zoom changed)"
	else
		fail "kitty + zoom updates info bar (zoom changed)" "before='$zoom_before' after='$zoom_after'"
	fi
else
	fail "kitty + zoom updates info bar (zoom changed)" "no frame marker after +"
fi
teardown

# ── Test 11: kitty-mode mouse click updates the rendered frame ──────────
# Same regression coverage but driven via mouse SGR escapes — sends a
# left-click at column 30, row 10 (1-based in SGR mouse protocol). The
# button-press code 0 ('M' suffix), then release ('m' suffix). On
# release with no drag, processEvent zooms in 2× at the click point.
setup "kitty_click" 140 24 --kitty --force-kitty
wait_frame || true
center_re_before=$(capture | grep -oE 'MANDELBROT_CENTER_RE=[^ ]+' | head -1)
zoom_before=$(capture | grep -oE 'MANDELBROT_ZOOM=[^ ]+' | head -1)
# SGR mouse: ESC [ < button ; col ; row M (press) / m (release).
# button 0 = left button, no modifiers.
tmux send-keys -t "$SESSION" -H 1B 5B 3C 30 3B 33 30 3B 31 30 4D
tmux send-keys -t "$SESSION" -H 1B 5B 3C 30 3B 33 30 3B 31 30 6D
if wait_frame; then
	center_re_after=$(capture | grep -oE 'MANDELBROT_CENTER_RE=[^ ]+' | head -1)
	zoom_after=$(capture | grep -oE 'MANDELBROT_ZOOM=[^ ]+' | head -1)
	if [ "$center_re_before" != "$center_re_after" ] || [ "$zoom_before" != "$zoom_after" ]; then
		pass "kitty mouse click updates info bar (center or zoom changed)"
	else
		fail "kitty mouse click updates info bar (center or zoom changed)" "center_before='$center_re_before' center_after='$center_re_after' zoom_before='$zoom_before' zoom_after='$zoom_after'"
	fi
else
	fail "kitty mouse click updates info bar (center or zoom changed)" "no frame marker after click"
fi
teardown

# ── Test 12: kitty-mode help modal close redraws the underlying view ───
# Catches the regression where closing the help modal in kitty mode left
# the screen blank — the modal-close clearScreen erased the kitty image
# placement (terminal-dependent: some implementations keep image
# placements through ED, some don't), and the fast path only re-emits
# the info bar, not the image.
#
# This test asserts that after open(?) → close(Esc), the info bar text
# (MANDELBROT_CENTER_RE) is visible AND the modal text is gone. If the
# info bar is missing, the fast path itself failed to emit it. tmux
# capture-pane can't see the kitty image bytes (those are graphics
# escapes, not cell text), but a blank-screen regression manifests as
# "info bar missing" too because clearScreen wipes everything.
setup "kitty_modal_close" 140 24 --kitty --force-kitty
wait_frame || true  # initial render
tmux send-keys -t "$SESSION" "?"
wait_frame || true  # modal render
# Sanity: modal text is currently visible
if ! capture | grep -q "keys & mouse"; then
	fail "kitty modal close redraws info bar (precondition)" "modal didn't open"
	teardown
	# Don't continue
else
	# Snapshot the log size so we can scope post-Esc emission checks to
	# bytes emitted AFTER this point (avoids false positives from the
	# initial kitty image transmission).
	pre_esc_size=$(wc -c < "$LOG_PATH")
	tmux send-keys -t "$SESSION" Escape
	if wait_frame; then
		out=$(capture)
		if echo "$out" | grep -q "MANDELBROT_CENTER_RE" && ! echo "$out" | grep -q "keys & mouse"; then
			pass "kitty modal close redraws info bar"
		else
			fail "kitty modal close redraws info bar" "info bar missing or modal still visible"
		fi

		# Image-restoration check: after closing the modal, the fast path
		# wipes the modal text via clearScreen. Some terminals (kitty)
		# preserve image placements through ED; some (ghostty) erase
		# them. To survive both, the fast path must re-place the image
		# via the kitty graphics 'a=p' (put existing image) command.
		# Assert that command appears in the byte stream emitted AFTER
		# we sent Esc.
		post_esc_bytes=$(tail -c +$((pre_esc_size + 1)) "$LOG_PATH")
		if printf '%s' "$post_esc_bytes" | grep -qE 'a=p,i=1'; then
			pass "kitty modal close re-places image (a=p,i=1 emitted)"
		else
			fail "kitty modal close re-places image (a=p,i=1 emitted)" \
				"no 'a=p,i=1' escape after Esc — image will vanish on terminals that erase placements through clearScreen"
		fi
	else
		fail "kitty modal close redraws info bar" "no frame marker after Esc"
	fi
	teardown
fi

# ── Test 13: memory leak stress — drive every allocating code path with
#             a barrage of zoom-in / pan / zoom-out / mode-cycle / modal
#             actions, then quit cleanly via 'q'. main.zig sets GPA's
#             safety=true unconditionally, so the `defer gpa.deinit()`
#             at exit prints any leaks to stderr regardless of build mode.
#             Test asserts that no "leaked" lines appear.
SESSION="mandel_test_leak_$$"
PIPE_PATH=$(mktemp -u "${TMPDIR:-/tmp}/mandel_pipe.XXXXXX")
mkfifo "$PIPE_PATH"
STDERR_LOG=$(mktemp "${TMPDIR:-/tmp}/mandel_stderr.XXXXXX")
tmux new-session -d -s "$SESSION" -x 80 -y 24 \
	"env MANDELBROT_FRAME_MARKER=1 $BINARY 2>$STDERR_LOG"
tmux pipe-pane -t "$SESSION" -o "cat > $PIPE_PATH"
exec 4< <(stdbuf -o0 tr '\033' '\n' < "$PIPE_PATH" | grep --line-buffered '=FRAME=')
wait_frame || true  # initial render

# Each key triggers exactly one render → one frame marker → wait_frame
# returns event-driven. Sequence covers: zoom-in (cache extract path),
# pan (origin shift), zoom-out (cache miss → fresh compute), mode cycle
# (different buf dimensions → cache realloc + image delete), info-bar
# toggle, help modal open/close.
keys=("+" "+" "Up" "Right" "-" "Down" "Left" "+" "g" "+" "g" "-" "i" "i" "?" "Escape" "+" "-")
for k in "${keys[@]}"; do
	tmux send-keys -t "$SESSION" "$k"
	wait_frame || true
done

# Clean shutdown — triggers `defer gpa.deinit()` which prints any leaks.
tmux send-keys -t "$SESSION" "q"
i=0
while [ $i -lt 50 ]; do
	if ! tmux has-session -t "$SESSION" 2>/dev/null; then break; fi
	IFS= read -r -t 0.05 -u 4 _ 2>/dev/null || true
	i=$((i + 1))
done

# Process has exited → all stderr writes are kernel-flushed → file final.
if grep -q "leaked" "$STDERR_LOG" 2>/dev/null; then
	leak_count=$(grep -c "leaked" "$STDERR_LOG")
	fail "no GPA leaks after stress sequence" "$leak_count leak warnings"
	head -10 "$STDERR_LOG" >&2
else
	pass "no GPA leaks after stress sequence"
fi

exec 4<&- 2>/dev/null || true
rm -f "$PIPE_PATH" "$STDERR_LOG"

echo
echo "tmux Integration Tests: $PASSED/$((PASSED + FAILED)) passed, $FAILED failed"
exit $FAILED

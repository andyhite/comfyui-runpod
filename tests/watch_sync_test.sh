#!/usr/bin/env bash
# Unit test for entrypoint.sh R2-mirror functions. Sources the entrypoint in
# lib-only mode with stubbed `rclone`, `inotifywait`, `python3.12` on PATH.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# --- stubs on PATH -----------------------------------------------------------
mkdir -p "$WORK/bin"

# Fake `rclone`: records argv to $RCLONE_LOG. `lsf` behavior is driven by
# $RCLONE_LSF_MODE: fail (exit 1), empty (exit 0, no output), data (exit 0, one line).
# `copy`/`sync` exit with $RCLONE_XFER_RC (default 0).
cat > "$WORK/bin/rclone" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$RCLONE_LOG"
case "${1:-}" in
  lsf)
    case "${RCLONE_LSF_MODE:-data}" in
      fail)  exit 1 ;;
      empty) exit 0 ;;
      data)  echo "some-file"; exit 0 ;;
    esac ;;
  copy|sync) exit "${RCLONE_XFER_RC:-0}" ;;
esac
exit 0
STUB

# Fake `inotifywait`: records argv to $INOTIFY_LOG, then emits $INOTIFY_LINES
# lines rapidly and exits (closing the pipe so watch_sync's loop terminates).
cat > "$WORK/bin/inotifywait" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$INOTIFY_LOG"
n="${INOTIFY_LINES:-3}"
for ((i=0; i<n; i++)); do echo "watched CREATE file$i"; done
exit 0
STUB

# Fake `python3.12`: record calls, always succeed.
cat > "$WORK/bin/python3.12" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$PY_LOG"
exit 0
STUB

chmod +x "$WORK/bin/rclone" "$WORK/bin/inotifywait" "$WORK/bin/python3.12"
export PATH="$WORK/bin:$PATH"

export RCLONE_LOG="$WORK/rclone.log";   : > "$RCLONE_LOG"
export INOTIFY_LOG="$WORK/inotify.log"; : > "$INOTIFY_LOG"
export PY_LOG="$WORK/py.log";           : > "$PY_LOG"

# --- source entrypoint in lib-only mode --------------------------------------
export ENTRYPOINT_LIB_ONLY=1
# shellcheck disable=SC1090
. "$ROOT/entrypoint.sh"
R2_BUCKET="testbucket"
DEBOUNCE=1
export RESTORE_POLL_EVERY=1 RESTORE_RETRY_BACKOFF=0
mkdir -p "$WORK/dir"

# --- restore_dir: fail mode --------------------------------------------------
: > "$RCLONE_LOG"; export RCLONE_LSF_MODE=fail
if restore_dir "$WORK/dir" custom_nodes "${GLOBAL_RCLONE_EXCLUDES[@]}"; then
  fail "restore_dir should fail when lsf (R2 unreachable) fails"
fi
grep -q "^copy " "$RCLONE_LOG" && fail "restore_dir must NOT copy when lsf fails"
pass "restore_dir returns non-zero and skips copy when R2 unreachable"

# --- restore_dir: empty mode -------------------------------------------------
: > "$RCLONE_LOG"; export RCLONE_LSF_MODE=empty
if ! restore_dir "$WORK/dir" custom_nodes "${GLOBAL_RCLONE_EXCLUDES[@]}"; then
  fail "restore_dir should succeed (fresh) when R2 path is empty"
fi
grep -q "^copy " "$RCLONE_LOG" && fail "restore_dir must NOT copy when R2 path empty"
pass "restore_dir treats empty R2 path as fresh success without copying"

# --- restore_dir: data mode --------------------------------------------------
: > "$RCLONE_LOG"; export RCLONE_LSF_MODE=data
restore_dir "$WORK/dir" custom_nodes "${GLOBAL_RCLONE_EXCLUDES[@]}" \
  || fail "restore_dir should succeed when copy succeeds"
grep -q "^copy r2:testbucket/custom_nodes $WORK/dir" "$RCLONE_LOG" \
  || fail "restore_dir wrong copy source/dest"
grep -q -- "--exclude .venv/\*\*" "$RCLONE_LOG" || fail "restore_dir missing .venv exclude"
[ "$(grep -c "^lsf " "$RCLONE_LOG")" = "1" ] || fail "restore_dir should call rclone lsf exactly once"
pass "restore_dir copies R2->local with excludes when data present"

# --- restore_dir: copy failure ----------------------------------------------
: > "$RCLONE_LOG"; export RCLONE_LSF_MODE=data RCLONE_XFER_RC=7
if restore_dir "$WORK/dir" custom_nodes "${GLOBAL_RCLONE_EXCLUDES[@]}"; then
  fail "restore_dir should propagate copy failure (partial restore)"
fi
unset RCLONE_XFER_RC
pass "restore_dir returns non-zero on copy failure"

# --- sync_up -----------------------------------------------------------------
: > "$RCLONE_LOG"
sync_up "$WORK/dir" output "${GLOBAL_RCLONE_EXCLUDES[@]}" || fail "sync_up should succeed"
grep -q "^sync $WORK/dir r2:testbucket/output" "$RCLONE_LOG" \
  || fail "sync_up wrong direction/dest"
grep -q -- "--exclude comfyui.db\*" "$RCLONE_LOG" || fail "sync_up missing comfyui.db exclude"
pass "sync_up mirrors local->R2 with excludes"

# --- watch_sync: coalesces a burst into exactly one sync ---------------------
: > "$RCLONE_LOG"; export RCLONE_LSF_MODE=data INOTIFY_LINES=5
watch_sync "$WORK/dir" custom_nodes "$GLOBAL_INOTIFY_EXCLUDE" "${GLOBAL_RCLONE_EXCLUDES[@]}"
syncs="$(grep -c "^sync " "$RCLONE_LOG" || true)"
[ "$syncs" = "1" ] || fail "expected exactly one sync from a burst, got $syncs"
grep -qF -- "$GLOBAL_INOTIFY_EXCLUDE" "$INOTIFY_LOG" \
  || fail "inotifywait not given the exclude regex"
pass "watch_sync debounces a burst into one sync and passes the exclude regex"

# --- restore_and_watch: gating on restore failure ----------------------------
WATCH_LOG="$WORK/watch.log"; : > "$WATCH_LOG"
start_watcher() { echo "watch $2" >> "$WATCH_LOG"; }   # override: record, don't background
export RCLONE_LSF_MODE=fail
if restore_and_watch "$WORK/dir" models "$GLOBAL_INOTIFY_EXCLUDE" "${GLOBAL_RCLONE_EXCLUDES[@]}"; then
  fail "restore_and_watch should return non-zero on restore failure"
fi
[ -s "$WATCH_LOG" ] && fail "restore_and_watch must NOT start a watcher on restore failure"
pass "restore_and_watch skips watcher when restore fails (protects R2)"

# --- restore_and_watch: starts watcher on restore success --------------------
: > "$WATCH_LOG"; export RCLONE_LSF_MODE=data
restore_and_watch "$WORK/dir" models "$GLOBAL_INOTIFY_EXCLUDE" "${GLOBAL_RCLONE_EXCLUDES[@]}" \
  || fail "restore_and_watch should succeed when restore succeeds"
grep -q "^watch models$" "$WATCH_LOG" || fail "restore_and_watch did not start watcher on success"
pass "restore_and_watch starts watcher when restore succeeds"

# --- start_r2_persistence: orchestration + gating ----------------------------
ORCH_LOG="$WORK/orch.log"; : > "$ORCH_LOG"
COMFY_DIR="$WORK/comfy"; mkdir -p "$COMFY_DIR/custom_nodes"
# Override the primitives to record calls instead of touching R2.
restore_dir()       { echo "restore $2" >> "$ORCH_LOG"; [ "$2" = "${FAIL_SUBPATH:-}" ] && return 1; return 0; }
start_watcher()     { echo "watch $2"   >> "$ORCH_LOG"; }
install_node_deps() { echo "install_node_deps" >> "$ORCH_LOG"; }

# All restores succeed: every dir restored + watched, deps installed once.
: > "$ORCH_LOG"; unset FAIL_SUBPATH
start_r2_persistence; wait
for want in "restore custom_nodes" "install_node_deps" "watch custom_nodes" \
            "restore user" "watch user" "restore models" "watch models" \
            "restore output" "watch output"; do
  grep -qx "$want" "$ORCH_LOG" || fail "start_r2_persistence missing: $want"
done
pass "start_r2_persistence restores + watches all four dirs and installs deps"

# user restore fails: user watcher must NOT start; others unaffected.
: > "$ORCH_LOG"; export FAIL_SUBPATH=user
start_r2_persistence; wait
grep -qx "watch user" "$ORCH_LOG" && fail "user watcher started despite restore failure"
grep -qx "watch custom_nodes" "$ORCH_LOG" || fail "custom_nodes watcher missing"
grep -qx "watch models" "$ORCH_LOG" || fail "models watcher missing"
unset FAIL_SUBPATH
pass "start_r2_persistence gates the user watcher on its restore"

# custom_nodes restore fails: no dep install, no custom_nodes watcher.
: > "$ORCH_LOG"; export FAIL_SUBPATH=custom_nodes
start_r2_persistence; wait
grep -qx "install_node_deps" "$ORCH_LOG" && fail "deps installed despite custom_nodes restore failure"
grep -qx "watch custom_nodes" "$ORCH_LOG" && fail "custom_nodes watcher started despite restore failure"
unset FAIL_SUBPATH
pass "start_r2_persistence skips dep install + watcher when custom_nodes restore fails"

echo "ALL PASS"

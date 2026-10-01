#!/usr/bin/env bash
# Unit test for entrypoint.sh R2-mirror functions. Sources the entrypoint in
# lib-only mode with stubbed `rclone`, `inotifywait`, `python3.12`, `curl` on PATH.
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
# `copy`/`sync` run for $RCLONE_XFER_SLEEP seconds if set, else exit $RCLONE_XFER_RC (default 0).
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
  copy|sync)
    [ -n "${RCLONE_XFER_SLEEP:-}" ] && exec sleep "$RCLONE_XFER_SLEEP"
    exit "${RCLONE_XFER_RC:-0}" ;;
esac
exit 0
STUB

# Fake `inotifywait`: records argv to $INOTIFY_LOG, then emits $INOTIFY_LINES
# lines rapidly and exits (closing the pipe so the watch loop terminates).
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

# Fake `curl` answering rclone's rc core/stats in real rclone's tab-indented
# layout (`"bytes": N`); the total grows by $CURL_BYTES_STEP per call. The nested
# `transferring` entry checks that only the top-level total is read.
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$CURL_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CURL_COUNT"
printf '{\n\t"bytes": %d,\n\t"checks": 0,\n\t"transferring": [\n\t\t{\n\t\t\t"bytes": 7\n\t\t}\n\t]\n}\n' \
  $(( n * ${CURL_BYTES_STEP:-0} ))
STUB

chmod +x "$WORK/bin/rclone" "$WORK/bin/inotifywait" "$WORK/bin/python3.12" "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"

export RCLONE_LOG="$WORK/rclone.log";   : > "$RCLONE_LOG"
export INOTIFY_LOG="$WORK/inotify.log"; : > "$INOTIFY_LOG"
export PY_LOG="$WORK/py.log";           : > "$PY_LOG"
export CURL_COUNT="$WORK/curl.count"

# --- source entrypoint in lib-only mode --------------------------------------
export ENTRYPOINT_LIB_ONLY=1
# shellcheck disable=SC1090
. "$ROOT/entrypoint.sh"
R2_BUCKET="testbucket"
DEPLOYMENT="test"
POD_ID="pod1"
DEBOUNCE=1
MIRROR_STATE="$WORK/state"; mkdir -p "$MIRROR_STATE"
export RESTORE_POLL_EVERY=1 RESTORE_RETRY_BACKOFF=0
mkdir -p "$WORK/dir"

# --- restore_dir: fail mode --------------------------------------------------
: > "$RCLONE_LOG"; export RCLONE_LSF_MODE=fail
if restore_dir "$WORK/dir" custom_nodes sync "${GLOBAL_RCLONE_EXCLUDES[@]}"; then
  fail "restore_dir should fail when lsf (R2 unreachable) fails"
fi
grep -qE "^(copy|sync) " "$RCLONE_LOG" && fail "restore_dir must NOT transfer when lsf fails"
pass "restore_dir returns non-zero and skips the transfer when R2 unreachable"

# --- restore_dir: empty mode -------------------------------------------------
: > "$RCLONE_LOG"; export RCLONE_LSF_MODE=empty
if ! restore_dir "$WORK/dir" custom_nodes sync "${GLOBAL_RCLONE_EXCLUDES[@]}"; then
  fail "restore_dir should succeed (fresh) when R2 path is empty"
fi
grep -qE "^(copy|sync) " "$RCLONE_LOG" && fail "restore_dir must NOT transfer when R2 path empty"
pass "restore_dir treats empty R2 path as fresh success without transferring"

# --- restore_dir: data mode --------------------------------------------------
: > "$RCLONE_LOG"; export RCLONE_LSF_MODE=data
restore_dir "$WORK/dir" custom_nodes sync "${GLOBAL_RCLONE_EXCLUDES[@]}" \
  || fail "restore_dir should succeed when the transfer succeeds"
grep -q "^sync r2:testbucket/custom_nodes $WORK/dir" "$RCLONE_LOG" \
  || fail "restore_dir wrong verb/source/dest"
grep -q -- "--exclude .venv/\*\*" "$RCLONE_LOG" || fail "restore_dir missing .venv exclude"
[ "$(grep -c "^lsf " "$RCLONE_LOG")" = "1" ] || fail "restore_dir should call rclone lsf exactly once"
pass "restore_dir transfers R2->local with excludes when data present"

# --- restore_dir: transfer failure -------------------------------------------
: > "$RCLONE_LOG"; export RCLONE_LSF_MODE=data RCLONE_XFER_RC=7
if restore_dir "$WORK/dir" custom_nodes sync "${GLOBAL_RCLONE_EXCLUDES[@]}"; then
  fail "restore_dir should propagate a transfer failure (partial restore)"
fi
unset RCLONE_XFER_RC
pass "restore_dir returns non-zero on transfer failure"

# --- rclone_stall_guarded: kills a transfer that only trickles ----------------
: > "$CURL_COUNT"; export RCLONE_XFER_SLEEP=30 CURL_BYTES_STEP=10
start=$SECONDS
if RESTORE_STALL_AFTER=2 RESTORE_MAX_ATTEMPTS=1 rclone_stall_guarded copy r2:testbucket/models "$WORK/dir"; then
  fail "a trickling transfer should be killed and reported as failed"
fi
[ $((SECONDS - start)) -lt 15 ] || fail "stall guard took $((SECONDS - start))s to fire"
pass "rclone_stall_guarded kills a transfer that only trickles"

# --- rclone_stall_guarded: leaves a progressing transfer alone ----------------
: > "$CURL_COUNT"; export RCLONE_XFER_SLEEP=4 CURL_BYTES_STEP=10485760
RESTORE_STALL_AFTER=2 RESTORE_MAX_ATTEMPTS=1 rclone_stall_guarded copy r2:testbucket/models "$WORK/dir" \
  || fail "a transfer making real progress must not be killed"
unset RCLONE_XFER_SLEEP CURL_BYTES_STEP
pass "rclone_stall_guarded leaves a progressing transfer alone"

# --- push --------------------------------------------------------------------
: > "$RCLONE_LOG"
push "$WORK/dir" output sync "${GLOBAL_RCLONE_EXCLUDES[@]}" || fail "push should succeed"
grep -q "^sync $WORK/dir r2:testbucket/output" "$RCLONE_LOG" \
  || fail "push wrong verb/direction/dest"
grep -q -- "--exclude comfyui.db\*" "$RCLONE_LOG" || fail "push missing comfyui.db exclude"
pass "push sends local->R2 with the given verb and excludes"

# --- watch_once: coalesces a burst into exactly one sync ---------------------
: > "$RCLONE_LOG"; export RCLONE_LSF_MODE=data INOTIFY_LINES=5
watch_once "$WORK/dir" custom_nodes sync "$GLOBAL_INOTIFY_EXCLUDE" "${GLOBAL_RCLONE_EXCLUDES[@]}"
syncs="$(grep -c "^sync " "$RCLONE_LOG" || true)"
[ "$syncs" = "1" ] || fail "expected exactly one sync from a burst, got $syncs"
grep -qF -- "$GLOBAL_INOTIFY_EXCLUDE" "$INOTIFY_LOG" \
  || fail "inotifywait not given the exclude regex"
pass "watch_once debounces a burst into one sync and passes the exclude regex"

# --- watch_once: syncs once even with no events ------------------------------
# Covers writes that land before the watch exists (e.g. a model downloaded
# while models was still restoring): no event will ever fire for them.
: > "$RCLONE_LOG"; export INOTIFY_LINES=0
watch_once "$WORK/dir" models sync "$GLOBAL_INOTIFY_EXCLUDE" "${GLOBAL_RCLONE_EXCLUDES[@]}"
[ "$(grep -c "^sync $WORK/dir r2:testbucket/models" "$RCLONE_LOG")" = "1" ] \
  || fail "watch_once must sync once up front, before any event"
pass "watch_once syncs once up front, before any event"

# --- flush_mirrors: final push of armed dirs only, each with its own verb ------
watch_sync() { :; }   # override: arm dirs without live watchers
mkdir -p "$WORK/output" "$WORK/user" "$WORK/models"
start_watcher "$WORK/output" data/pod1/output copy "$GLOBAL_INOTIFY_EXCLUDE" "${GLOBAL_RCLONE_EXCLUDES[@]}"
export RCLONE_LSF_MODE=data
restore_and_watch "$WORK/user" deployments/test/user sync "$USER_INOTIFY_EXCLUDE" "${USER_RCLONE_EXCLUDES[@]}" \
  || fail "user restore should succeed"
export RCLONE_LSF_MODE=fail
restore_and_watch "$WORK/models" deployments/test/models copy "$GLOBAL_INOTIFY_EXCLUDE" "${GLOBAL_RCLONE_EXCLUDES[@]}" \
  && fail "models restore should fail"
wait
: > "$RCLONE_LOG"
flush_mirrors
grep -q "^copy $WORK/output r2:testbucket/data/pod1/output" "$RCLONE_LOG" \
  || fail "flush_mirrors must push a data dir with copy (sync would delete from R2)"
grep -q "^sync $WORK/user r2:testbucket/deployments/test/user" "$RCLONE_LOG" \
  || fail "flush_mirrors did not mirror the restored user dir"
grep -q -- "--exclude __manager/cache/\*\*" "$RCLONE_LOG" || fail "flush_mirrors dropped the dir's excludes"
grep -q "deployments/test/models" "$RCLONE_LOG" && fail "flush_mirrors pushed models although its restore failed"
pass "flush_mirrors pushes armed dirs with their verb and excludes, skips unarmed ones"

# --- supervise: stopping the pod flushes the mirrors -------------------------
cat > "$WORK/fake-start.sh" <<STUB
#!/usr/bin/env bash
touch "$WORK/started"
exec sleep 30
STUB
chmod +x "$WORK/fake-start.sh"
: > "$RCLONE_LOG"
( supervise "$WORK/fake-start.sh" ) &
sup=$!
for _ in $(seq 1 50); do [ -e "$WORK/started" ] && break; sleep 0.1; done
kill -TERM "$sup"
wait "$sup" || fail "supervise should exit 0 after a stop"
grep -q "^copy $WORK/output r2:testbucket/data/pod1/output" "$RCLONE_LOG" \
  || fail "stopping did not flush the armed output dir"
pass "supervise flushes the mirrors when the pod is stopped"

# --- restore_and_watch: gating on restore failure ----------------------------
WATCH_LOG="$WORK/watch.log"; : > "$WATCH_LOG"
start_watcher() { echo "watch $2 $3" >> "$WATCH_LOG"; }   # override: record, don't background
export RCLONE_LSF_MODE=fail
if restore_and_watch "$WORK/dir" models copy "$GLOBAL_INOTIFY_EXCLUDE" "${GLOBAL_RCLONE_EXCLUDES[@]}"; then
  fail "restore_and_watch should return non-zero on restore failure"
fi
[ -s "$WATCH_LOG" ] && fail "restore_and_watch must NOT start a watcher on restore failure"
pass "restore_and_watch skips watcher when restore fails (protects R2)"

# --- restore_and_watch: starts watcher on restore success --------------------
: > "$WATCH_LOG"; export RCLONE_LSF_MODE=data
restore_and_watch "$WORK/dir" models copy "$GLOBAL_INOTIFY_EXCLUDE" "${GLOBAL_RCLONE_EXCLUDES[@]}" \
  || fail "restore_and_watch should succeed when restore succeeds"
grep -q "^watch models sync$" "$WATCH_LOG" \
  || fail "a restored dir must start its watcher, mirroring back with sync"
pass "restore_and_watch starts a sync watcher when restore succeeds"

# --- start_r2_persistence: orchestration + gating ----------------------------
ORCH_LOG="$WORK/orch.log"; : > "$ORCH_LOG"
COMFY_DIR="$WORK/comfy"; mkdir -p "$COMFY_DIR/custom_nodes"
# Override the primitives to record calls instead of touching R2. The models
# restore can be held at $MODELS_GATE to observe what finished before it.
restore_dir() {
  if [ "${2##*/}" = models ] && [ -n "${MODELS_GATE:-}" ]; then
    while [ ! -e "$MODELS_GATE" ]; do sleep 0.1; done
  fi
  echo "restore $2 $3" >> "$ORCH_LOG"
  [ "${2##*/}" = "${FAIL_SUBPATH:-}" ] && return 1
  return 0
}
start_watcher()     { echo "watch $2 $3" >> "$ORCH_LOG"; }
install_node_deps() { echo "install_node_deps" >> "$ORCH_LOG"; }

# All restores succeed. The deployment's custom_nodes + user restore before
# start_r2_persistence returns (i.e. before ComfyUI starts); models streams in
# the background. input + output are never restored, only uploaded with copy to
# this pod's own data folder.
: > "$ORCH_LOG"; unset FAIL_SUBPATH; export MODELS_GATE="$WORK/models.gate"
start_r2_persistence
for want in "restore deployments/test/custom_nodes sync" "install_node_deps" \
            "watch deployments/test/custom_nodes sync" "restore deployments/test/user sync" \
            "watch deployments/test/user sync" "watch data/pod1/input copy" \
            "watch data/pod1/output copy"; do
  grep -qx "$want" "$ORCH_LOG" || fail "missing before ComfyUI starts: $want"
done
grep -q "^restore data/" "$ORCH_LOG" && fail "input/output must never be restored"
grep -q "models" "$ORCH_LOG" && fail "models restore must not block startup"
touch "$MODELS_GATE"; wait; unset MODELS_GATE
grep -qx "restore deployments/test/models copy" "$ORCH_LOG" \
  || fail "models must restore with copy (sync would delete models downloaded mid-restore)"
grep -qx "watch deployments/test/models sync" "$ORCH_LOG" || fail "models watcher missing"
pass "start_r2_persistence restores the deployment and only uploads input/output"

# user restore fails: user watcher must NOT start; others unaffected.
: > "$ORCH_LOG"; export FAIL_SUBPATH=user
start_r2_persistence; wait
grep -q "^watch deployments/test/user" "$ORCH_LOG" && fail "user watcher started despite restore failure"
grep -qx "watch deployments/test/custom_nodes sync" "$ORCH_LOG" || fail "custom_nodes watcher missing"
grep -qx "watch deployments/test/models sync" "$ORCH_LOG" || fail "models watcher missing"
unset FAIL_SUBPATH
pass "start_r2_persistence gates the user watcher on its restore"

# custom_nodes restore fails: no dep install, no custom_nodes watcher.
: > "$ORCH_LOG"; export FAIL_SUBPATH=custom_nodes
start_r2_persistence; wait
grep -qx "install_node_deps" "$ORCH_LOG" && fail "deps installed despite custom_nodes restore failure"
grep -q "^watch deployments/test/custom_nodes" "$ORCH_LOG" && fail "custom_nodes watcher started despite restore failure"
unset FAIL_SUBPATH
pass "start_r2_persistence skips dep install + watcher when custom_nodes restore fails"

echo "ALL PASS"

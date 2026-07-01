#!/usr/bin/env bash
# Unit test for entrypoint.sh snapshot functions. Sources the entrypoint in
# lib-only mode and drives snapshot_seed / snapshot_reconcile with stubbed
# `python3.12` (fake save-snapshot) and `rclone`.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# --- stubs on PATH -----------------------------------------------------------
mkdir -p "$WORK/bin"
# Fake `python3.12`: on `save-snapshot --output X`, copy $SNAP_FIXTURE to X.
cat > "$WORK/bin/python3.12" <<'STUB'
#!/usr/bin/env bash
args=("$@"); out=""
for ((i=0; i<${#args[@]}; i++)); do
  [ "${args[$i]}" = "--output" ] && out="${args[$((i+1))]}"
done
case " $* " in
  *" save-snapshot "*) [ -n "$out" ] && cp "$SNAP_FIXTURE" "$out"; exit 0 ;;
esac
exit 0
STUB
# Fake `rclone`: record each copyto destination to $RCLONE_LOG, succeed.
cat > "$WORK/bin/rclone" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "copyto" ]; then echo "$3" >> "$RCLONE_LOG"; fi
exit 0
STUB
chmod +x "$WORK/bin/python3.12" "$WORK/bin/rclone"
export PATH="$WORK/bin:$PATH"

# --- fixtures ----------------------------------------------------------------
printf '{"nodes":"A"}\n' > "$WORK/snapA.json"
printf '{"nodes":"B"}\n' > "$WORK/snapB.json"
export RCLONE_LOG="$WORK/rclone.log"; : > "$RCLONE_LOG"
export MARKER_FILE="$WORK/marker.sha"

# --- source entrypoint in lib-only mode --------------------------------------
export ENTRYPOINT_LIB_ONLY=1
# shellcheck disable=SC1090
. "$ROOT/entrypoint.sh"
CM_CLI="/does/not/matter"   # save-snapshot is stubbed
R2_BUCKET="testbucket"
MARKER="$MARKER_FILE"

# --- assertions --------------------------------------------------------------
# seed with fixture A: baseline set, NO upload.
export SNAP_FIXTURE="$WORK/snapA.json"
snapshot_seed
[ -n "$BASELINE_SHA" ] || fail "seed did not set BASELINE_SHA"
[ ! -s "$RCLONE_LOG" ] || fail "seed uploaded (should not)"
pass "seed sets baseline without uploading"

# reconcile with identical fixture A: NO upload.
snapshot_reconcile "no-change"
[ ! -s "$RCLONE_LOG" ] || fail "reconcile uploaded on no-op change"
pass "reconcile is a no-op when snapshot is unchanged"

# reconcile with fixture B: exactly one upload, marker + baseline advanced.
prev_sha="$BASELINE_SHA"
export SNAP_FIXTURE="$WORK/snapB.json"
snapshot_reconcile "changed"
[ "$(wc -l < "$RCLONE_LOG" | tr -d ' ')" = "1" ] || fail "expected exactly one upload"
grep -q "testbucket/snapshot.json" "$RCLONE_LOG" || fail "wrong upload destination"
[ "$BASELINE_SHA" != "$prev_sha" ] || fail "baseline not advanced"
[ "$(cat "$MARKER_FILE")" = "$BASELINE_SHA" ] || fail "marker not written with new sha"
pass "reconcile uploads once and advances baseline+marker on change"

echo "ALL PASS"

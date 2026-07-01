#!/usr/bin/env bash
# dstack / RunPod entrypoint wrapper.
#
# Runs BEFORE the base image's /start.sh so we can set the pod up on a fresh
# (volume-less) disk before ComfyUI launches:
#   1. CUDA-13 preflight (exit non-zero on an old-driver host so dstack retries)
#   2. populate ComfyUI from the baked copy if the disk is fresh
#   3. restore custom_nodes + user from R2 (blocking), then install node deps
#   4. restore models + output from R2 in the background (ComfyUI comes up first)
#   5. start a filesystem-watcher per dir that rclone-syncs it back to R2, so R2
#      stays an EXACT mirror. Each watcher starts only after its restore succeeds.
# then hand off to /start.sh, which creates the venv and launches ComfyUI, SSH,
# JupyterLab, and FileBrowser.
#
# R2 persistence activates only when RCLONE_CONFIG_R2_* + R2_BUCKET + R2_ACCOUNT_ID
# are set (dstack secrets/env); otherwise the pod runs with no persistence.
set -uo pipefail

COMFY_DIR=/workspace/runpod-slim/ComfyUI
BAKED=/opt/comfyui-baked
export COMFYUI_PATH="$COMFY_DIR"

log() { echo "[dstack-entry] $*"; }

# ---------------------------------------------------------------------------
# R2 mirror library. R2 is an exact copy of four dirs: custom_nodes, user,
# models, output. Restore (R2->pod) uses `copy` (non-destructive); the running
# mirror (pod->R2) uses `sync` (destructive — deletions/renames propagate).
# A dir's up-sync watcher starts ONLY after its restore succeeds, so a degraded
# pod can never wipe good data in R2.
# ---------------------------------------------------------------------------

# Exclude sets. Kept in sync across two syntaxes: rclone globs and one POSIX
# extended-regex for inotifywait. NOTE: `.git` is intentionally NOT excluded.
GLOBAL_RCLONE_EXCLUDES=(
  --exclude '.venv/**' --exclude 'venv/**'
  --exclude '__pycache__/**' --exclude '*.pyc'
  --exclude '*.part*' --exclude '*.tmp'
  --exclude '*.log' --exclude 'comfyui.db*'
)
USER_RCLONE_EXCLUDES=("${GLOBAL_RCLONE_EXCLUDES[@]}" --exclude '__manager/cache/**')
GLOBAL_INOTIFY_EXCLUDE='(/\.venv/|/venv/|/__pycache__/|\.pyc$|\.part|\.tmp$|\.log$|comfyui\.db)'
USER_INOTIFY_EXCLUDE='(/\.venv/|/venv/|/__pycache__/|\.pyc$|\.part|\.tmp$|\.log$|comfyui\.db|/__manager/cache/)'

# Restore a directory from R2. An empty/absent R2 path is a valid FRESH state
# (return 0 so the watcher starts and seeds it). An lsf failure means R2 is
# unreachable/misconfigured (return 1 — do NOT let a watcher start). A partial
# copy failure also returns non-zero. Distinguishing these is the safety hinge.
restore_dir() {
  local local_dir="$1" subpath="$2"; shift 2
  mkdir -p "$local_dir"
  # One lsf call: its exit code gates "unreachable" (fail closed -> return 1, no
  # copy) and its captured output gates "empty prefix" (fresh -> return 0, no
  # copy). Do NOT split into two calls — a transient failure on a second call
  # with empty output would be misread as "fresh" and wrongly start the watcher
  # against a degraded R2. `local listing` is declared separately so the
  # assignment's exit code (not `local`'s) drives the `if`.
  local listing
  if ! listing="$(rclone lsf "r2:$R2_BUCKET/$subpath" 2>/dev/null)"; then
    log "cannot list r2:$R2_BUCKET/$subpath (R2 unreachable?) — NOT starting its watcher"
    return 1
  fi
  if [ -z "$listing" ]; then
    log "r2:$R2_BUCKET/$subpath is empty — fresh; watcher will seed it"
    return 0
  fi
  log "restoring $subpath from R2..."
  rclone copy "r2:$R2_BUCKET/$subpath" "$local_dir" "$@"
}

# Mirror a directory up to R2 (destructive exact copy).
sync_up() {
  local local_dir="$1" subpath="$2"; shift 2
  rclone sync "$local_dir" "r2:$R2_BUCKET/$subpath" "$@"
}

# Watch a directory and sync_up on each debounced burst. Runs until the pod stops.
watch_sync() {
  local local_dir="$1" subpath="$2" regex="$3"; shift 3
  inotifywait -m -r -q \
    -e create -e delete -e modify -e moved_to -e moved_from \
    --exclude "$regex" \
    "$local_dir" |
  while read -r _; do
    # Debounce: drain further events until DEBOUNCE seconds of quiet.
    while read -r -t "${DEBOUNCE:-15}" _; do :; done
    sync_up "$local_dir" "$subpath" "$@"
  done
}

# Background a watcher. Split out so tests can override it.
start_watcher() {
  watch_sync "$@" &
}

# Restore a dir, and ONLY on success start its watcher. The gate that upholds
# the safety invariant.
restore_and_watch() {
  local local_dir="$1" subpath="$2" regex="$3"; shift 3
  if restore_dir "$local_dir" "$subpath" "$@"; then
    start_watcher "$local_dir" "$subpath" "$regex" "$@"
    return 0
  fi
  return 1
}

# Install restored custom nodes' Python deps into the fresh venv. restore-
# dependencies handles each node's requirements.txt; the sweep runs any
# install.py the node ships (first-install side effects pip won't do).
install_node_deps() {
  local cm_cli="$COMFY_DIR/custom_nodes/ComfyUI-Manager/cm-cli.py" np
  if [ -f "$cm_cli" ]; then
    log "installing node dependencies (cm-cli restore-dependencies)..."
    python3.12 "$cm_cli" restore-dependencies \
      || log "WARNING: some node deps failed to install — check the logs."
  fi
  for np in "$COMFY_DIR"/custom_nodes/*/; do
    if [ -f "${np}install.py" ]; then
      log "running install.py for $(basename "$np")..."
      ( cd "$np" && python3.12 install.py ) \
        || log "WARNING: install.py failed for $(basename "$np")"
    fi
  done
}

# Restore + mirror all four dirs. Blocking for custom_nodes + user (small,
# required for a correct launch); backgrounded for models + output (large —
# ComfyUI comes up while they stream). Each watcher is gated on its restore.
start_r2_persistence() {
  # custom_nodes: restore -> install deps -> gated watcher.
  if restore_dir "$COMFY_DIR/custom_nodes" custom_nodes "${GLOBAL_RCLONE_EXCLUDES[@]}"; then
    install_node_deps
    start_watcher "$COMFY_DIR/custom_nodes" custom_nodes "$GLOBAL_INOTIFY_EXCLUDE" "${GLOBAL_RCLONE_EXCLUDES[@]}"
  else
    log "custom_nodes restore failed — skipping node dep install + watcher (protecting R2)"
  fi

  # user: restore -> gated watcher.
  restore_and_watch "$COMFY_DIR/user" user "$USER_INOTIFY_EXCLUDE" "${USER_RCLONE_EXCLUDES[@]}" \
    || log "user restore failed — skipping its watcher (protecting R2)"

  # models + output: background restore -> gated watcher (stream in).
  restore_and_watch "$COMFY_DIR/models" models "$GLOBAL_INOTIFY_EXCLUDE" "${GLOBAL_RCLONE_EXCLUDES[@]}" \
    || log "models restore failed — skipping its watcher (protecting R2)" &
  restore_and_watch "$COMFY_DIR/output" output "$GLOBAL_INOTIFY_EXCLUDE" "${GLOBAL_RCLONE_EXCLUDES[@]}" \
    || log "output restore failed — skipping its watcher (protecting R2)" &
}

# When sourced by the test harness, stop here: define lib, skip the boot flow.
if [ -n "${ENTRYPOINT_LIB_ONLY:-}" ]; then
  return 0
fi

# Preflight: this is a CUDA 13 image. If we landed on a host whose driver is too
# old to run it, bail immediately (exit non-zero) so dstack retries on another
# host — it can't filter hosts by driver version, only GPU type. Doing this first
# avoids wasting time populating ComfyUI and downloading ~100GB on a dead pod.
#
# This forces a real CUDA allocation with the image's CUDA-13 torch — the same
# op that would otherwise crash ComfyUI. On an old-driver host it raises
# "driver is too old" and python exits non-zero; on a good host it's a no-op.
if ! python3.12 -c "import torch; torch.zeros(1, device='cuda')" 2>/dev/null; then
  log "CUDA 13 unusable on this host (driver too old?) — exiting 1 so dstack retries another host."
  exit 1
fi
log "CUDA 13 preflight OK."

R2=0
if [ -n "${RCLONE_CONFIG_R2_ACCESS_KEY_ID:-}" ] && [ -n "${R2_BUCKET:-}" ] && [ -n "${R2_ACCOUNT_ID:-}" ]; then
  export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  R2=1; log "R2 persistence enabled (bucket: $R2_BUCKET)"
else
  log "R2 not configured — models from origin only, outputs not persisted"
fi

# 1) Fresh disk: populate ComfyUI ourselves so we can modify it before launch.
if [ ! -d "$COMFY_DIR" ]; then
  log "populating ComfyUI from baked image..."
  mkdir -p "$(dirname "$COMFY_DIR")"
  cp -r "$BAKED" "$COMFY_DIR"
fi

# Restore state from R2 and start the directory mirrors. Blocking restores
# (custom_nodes + user) finish before ComfyUI launches; models + output stream
# in the background. Skipped entirely when R2 isn't configured.
if [ "$R2" = 1 ]; then
  start_r2_persistence
fi

log "handing off to /start.sh"
exec /start.sh

#!/usr/bin/env bash
# dstack / RunPod entrypoint wrapper.
#
# Runs BEFORE the base image's /start.sh so we can set the pod up on a fresh
# (volume-less) disk before ComfyUI launches:
#   1. populate ComfyUI from the baked copy
#   2. restore the ComfyUI-Manager snapshot uploaded via `files:` (idempotent)
#   3. restore the user dir (workflows + __manager config) from R2
#   4. download models (background): R2 cache -> origin (HF) -> cache up to R2
#   5. sync outputs + user dir -> R2 in the background (so they survive termination)
# then hand off to /start.sh, which creates the venv and launches ComfyUI, SSH,
# JupyterLab, and FileBrowser.
#
# R2 persistence activates only when RCLONE_CONFIG_R2_* + R2_BUCKET are set
# (dstack secrets/env); otherwise models come from origin only and outputs are
# not persisted — the pod still works.
set -uo pipefail

COMFY_DIR=/workspace/runpod-slim/ComfyUI
BAKED=/opt/comfyui-baked
UPLOADS=/opt/uploads
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

# 2) Restore the Manager snapshot from R2 (idempotent — skip if unchanged on
#    this disk). R2 is the source of truth; the watcher (step 6) keeps it fresh.
#    First-ever run (or no R2) has no snapshot: come up on the base image nodes.
SNAP=/tmp/snapshot.json
if [ "$R2" = 1 ] && rclone copyto "r2:$R2_BUCKET/snapshot.json" "$SNAP" 2>/dev/null && [ -s "$SNAP" ]; then
  sum="$(sha256sum "$SNAP" | cut -d' ' -f1)"
  if [ "$(cat "$MARKER" 2>/dev/null || true)" != "$sum" ]; then
    log "restoring ComfyUI-Manager snapshot from R2..."
    if python3.12 "$CM_CLI" restore-snapshot "$SNAP"; then
      # restore-snapshot re-clones the nodes but does NOT install their pip deps
      # (e.g. Impact Pack -> scikit-image, WAS -> numba). restore-dependencies
      # runs each installed node's requirements.txt (resolved via cu130 index).
      log "installing node dependencies (restore-dependencies)..."
      python3.12 "$CM_CLI" restore-dependencies \
        || log "WARNING: some node deps failed to install — check the logs."
      echo "$sum" > "$MARKER"; log "snapshot restored."
    else
      log "WARNING: snapshot restore had errors — continuing so SSH/Jupyter come up."
    fi
  else
    log "snapshot unchanged — skipping restore."
  fi
else
  log "no snapshot in R2 (or R2 disabled) — starting with base image nodes."
fi

# 3) User dir (workflows, __manager/config.ini, comfy settings, etc.) is your
#    LIVE state, persisted entirely in R2 — restored here at boot and pushed back
#    every 30s (see step 5). No repo baseline: the baked ComfyUI ships an empty
#    user dir, so a fresh pod with no R2 just starts clean. __manager/cache is
#    large and regenerable, so it's excluded.
if [ "$R2" = 1 ]; then
  log "restoring live user dir from R2..."
  rclone copy "r2:$R2_BUCKET/user" "$COMFY_DIR/user" \
    --exclude "__manager/cache/**" --exclude "*.log" --exclude "comfyui.db*" \
    2>/dev/null || true
fi

# 4) Models in the BACKGROUND: R2 cache -> origin (HF) -> cache up to R2.
#    Idempotent: skips files already on disk. Gated repos (Flux.2 Klein 9B) need
#    HF_TOKEN on the FIRST download; afterwards they're served from R2.
MANIFEST="$UPLOADS/models.txt"
if [ -f "$MANIFEST" ]; then
  log "starting model downloads in background (watch the [models] log lines)..."
  DONE_MARK=/tmp/.models-done; rm -f "$DONE_MARK"
  (
    while read -r dir url; do
      [ -z "${dir:-}" ] && continue
      case "$dir" in \#*) continue ;; esac
      [ -z "${url:-}" ] && continue
      fn="${url##*/}"
      dest="$COMFY_DIR/models/$dir/$fn"
      if [ -s "$dest" ]; then echo "[models] have $fn"; continue; fi
      mkdir -p "$COMFY_DIR/models/$dir"
      # (a) R2 cache
      if [ "$R2" = 1 ] && rclone copyto "r2:$R2_BUCKET/models/$dir/$fn" "$dest.part" 2>/dev/null && [ -s "$dest.part" ]; then
        mv "$dest.part" "$dest"; echo "[models] R2 hit -> $fn"; continue
      fi
      rm -f "$dest.part"
      # (b) origin (HF)
      echo "[models] origin download -> $fn"
      hdr=()
      [ -n "${HF_TOKEN:-}" ] && hdr=(--header="Authorization: Bearer $HF_TOKEN")
      if wget -q "${hdr[@]}" -c -O "$dest.part" "$url"; then
        mv "$dest.part" "$dest"; echo "[models] origin done -> $fn"
        # Caching to R2 is handled by the background sync below — NOT inline,
        # so a slow 28GB upload never blocks the next download.
      else
        echo "[models] FAILED $fn — gated? check HF_TOKEN and license acceptance"
        rm -f "$dest.part"
      fi
    done < "$MANIFEST"
    echo "[models] all downloads complete"
    touch "$DONE_MARK"
  ) &

  # Heartbeat: every 30s, report files-done + bytes-on-disk so a long silent
  # transfer (R2 pull or origin download) clearly still looks alive.
  ( while [ ! -f "$DONE_MARK" ]; do
      sleep 30
      n="$(find "$COMFY_DIR/models" -type f ! -name '*.part*' 2>/dev/null | wc -l | tr -d ' ')"
      cur="$(ls -S "$COMFY_DIR"/models/*/*.part* 2>/dev/null | head -1)"
      msg="$n files, $(du -sh "$COMFY_DIR/models" 2>/dev/null | cut -f1) on disk"
      [ -n "$cur" ] && msg="$msg; fetching $(basename "$cur") @ $(du -h "$cur" 2>/dev/null | cut -f1)"
      echo "[models] ...still working — $msg"
    done ) &

  # Cache completed models up to R2 in the BACKGROUND (incremental; skips
  # in-progress *.part* files). Stops after downloads finish, with a final pass.
  if [ "$R2" = 1 ]; then
    ( while [ ! -f "$DONE_MARK" ]; do
        rclone copy "$COMFY_DIR/models" "r2:$R2_BUCKET/models" \
          --exclude "*.part*" --no-traverse 2>/dev/null
        sleep 120
      done
      rclone copy "$COMFY_DIR/models" "r2:$R2_BUCKET/models" \
        --exclude "*.part*" --no-traverse 2>/dev/null
      echo "[models] R2 cache seeding complete"
    ) &
  fi
fi

# 5) Persist outputs + live user-dir edits to R2 in the background (every 30s).
#    Up to the last 30s may not sync on an abrupt stop. Both are additive copies
#    (rclone copy, not sync) — deletions/renames don't propagate to R2, so prune
#    R2 manually if you remove a workflow.
if [ "$R2" = 1 ]; then
  OUT="$COMFY_DIR/output"; mkdir -p "$OUT"
  log "syncing outputs -> r2:$R2_BUCKET/outputs and user dir -> r2:$R2_BUCKET/user every 30s..."
  ( while true; do
      rclone copy "$OUT" "r2:$R2_BUCKET/outputs" --no-traverse 2>/dev/null
      rclone copy "$COMFY_DIR/user" "r2:$R2_BUCKET/user" \
        --exclude "__manager/cache/**" --exclude "*.log" --exclude "comfyui.db*" \
        --no-traverse 2>/dev/null
      sleep 30
    done ) &
fi

# 6) Auto-snapshot: watch custom_nodes and push a fresh Manager snapshot to R2
#    whenever nodes are installed / updated / removed (debounced). Keeps
#    r2:$R2_BUCKET/snapshot.json current so the next cold start restores exactly
#    this node set. Starts AFTER the boot restore above so it never reacts to the
#    restore's own re-cloning or captures a half-installed state.
if [ "$R2" = 1 ]; then
  log "starting custom_nodes snapshot watcher -> r2:$R2_BUCKET/snapshot.json (on change)..."
  snapshot_watch &
fi

log "handing off to /start.sh"
exec /start.sh

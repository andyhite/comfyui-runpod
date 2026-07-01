#!/usr/bin/env bash
# dstack / RunPod entrypoint wrapper.
#
# Runs BEFORE the base image's /start.sh so we can set the pod up on a fresh
# (volume-less) disk before ComfyUI launches:
#   1. populate ComfyUI from the baked copy
#   2. restore the ComfyUI-Manager snapshot uploaded via `files:` (idempotent)
#   3. lay in the user dir (workflows + __manager config) uploaded via `files:`
#   4. download models (background): R2 cache -> origin (HF) -> cache up to R2
#   5. sync outputs -> R2 in the background (so they survive termination)
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

# 2) Restore the Manager snapshot (idempotent — skip if unchanged on this disk).
SNAP="$UPLOADS/snapshot.json"
MARKER="$COMFY_DIR/.dstack-applied-snapshot.sha"
if [ -f "$SNAP" ]; then
  sum="$(sha256sum "$SNAP" | cut -d' ' -f1)"
  if [ "$(cat "$MARKER" 2>/dev/null || true)" != "$sum" ]; then
    CM_CLI="$COMFY_DIR/custom_nodes/ComfyUI-Manager/cm-cli.py"
    log "restoring ComfyUI-Manager snapshot..."
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
fi

# 3) User dir (workflows, __manager/config.ini, comfy settings, etc.):
#    - the repo's `files:` copy is the BASELINE/seed (version-controlled)
#    - the R2 copy is your LIVE state (edits made on previous pods), overlaid
#      ON TOP so changes persist instead of being reset to the committed version.
#    The __manager/cache is large and regenerable, so it's excluded from R2.
if [ -d "$UPLOADS/user" ]; then
  log "seeding user dir from repo (baseline)..."
  cp -r "$UPLOADS/user/." "$COMFY_DIR/user/" 2>/dev/null || true
fi
if [ "$R2" = 1 ]; then
  log "overlaying live user dir from R2 (your saved edits win)..."
  rclone copy "r2:$R2_BUCKET/user" "$COMFY_DIR/user" \
    --exclude "__manager/cache/**" 2>/dev/null || true
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
        --exclude "__manager/cache/**" --no-traverse 2>/dev/null
      sleep 30
    done ) &
fi

log "handing off to /start.sh"
exec /start.sh

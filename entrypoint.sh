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
    log "restoring ComfyUI-Manager snapshot..."
    if python3.12 "$COMFY_DIR/custom_nodes/ComfyUI-Manager/cm-cli.py" \
         restore-snapshot "$SNAP"; then
      echo "$sum" > "$MARKER"; log "snapshot restored."
    else
      log "WARNING: snapshot restore had errors — continuing so SSH/Jupyter come up."
    fi
  else
    log "snapshot unchanged — skipping restore."
  fi
fi

# 3) Lay in the user dir uploaded via `files:`.
if [ -d "$UPLOADS/user" ]; then
  log "syncing user dir (workflows + __manager config)..."
  cp -r "$UPLOADS/user/." "$COMFY_DIR/user/" 2>/dev/null || true
fi

# 4) Models in the BACKGROUND: R2 cache -> origin (HF) -> cache up to R2.
#    Idempotent: skips files already on disk. Gated repos (Flux.2 Klein 9B) need
#    HF_TOKEN on the FIRST download; afterwards they're served from R2.
MANIFEST="$UPLOADS/models.txt"
if [ -f "$MANIFEST" ]; then
  log "starting model downloads in background (watch the [models] log lines)..."
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
        # (c) cache up to R2 for next boot
        if [ "$R2" = 1 ]; then
          rclone copyto "$dest" "r2:$R2_BUCKET/models/$dir/$fn" 2>/dev/null \
            && echo "[models] cached to R2 -> $fn" \
            || echo "[models] R2 cache upload failed (non-fatal) -> $fn"
        fi
      else
        echo "[models] FAILED $fn — gated? check HF_TOKEN and license acceptance"
        rm -f "$dest.part"
      fi
    done < "$MANIFEST"
    echo "[models] all downloads complete"
  ) &
fi

# 5) Persist outputs to R2 in the background (incremental, every 30s). Up to the
#    last 30s of outputs may not sync on an abrupt stop.
if [ "$R2" = 1 ]; then
  OUT="$COMFY_DIR/output"; mkdir -p "$OUT"
  log "syncing outputs -> r2:$R2_BUCKET/outputs every 30s..."
  ( while true; do
      rclone copy "$OUT" "r2:$R2_BUCKET/outputs" --no-traverse 2>/dev/null
      sleep 30
    done ) &
fi

log "handing off to /start.sh"
exec /start.sh

#!/usr/bin/env bash
# dstack / RunPod entrypoint wrapper.
#
# Runs BEFORE the base image's /start.sh so we can inject things on a fresh
# (volume-less) disk before ComfyUI launches:
#   1. populate ComfyUI from the baked copy (so we can modify it pre-launch)
#   2. restore the ComfyUI-Manager snapshot uploaded via `files:` (idempotent)
#   3. lay in workflows + user config uploaded via `files:`
# then hand off to /start.sh, which creates the venv and launches ComfyUI,
# SSH, JupyterLab, and FileBrowser as normal.
#
# cm-cli is run with the system python3.12: it git-clones nodes into custom_nodes
# and pip-installs their deps into the system site-packages, which the runtime
# venv inherits (the base image creates it with --system-site-packages).
set -uo pipefail

COMFY_DIR=/workspace/runpod-slim/ComfyUI
BAKED=/opt/comfyui-baked
UPLOADS=/opt/uploads
export COMFYUI_PATH="$COMFY_DIR"

log() { echo "[dstack-entry] $*"; }

# 1) Fresh disk: populate ComfyUI ourselves so we can modify it before launch.
#    (On a persistent disk this is skipped after the first boot.)
if [ ! -d "$COMFY_DIR" ]; then
  log "populating ComfyUI from baked image..."
  mkdir -p "$(dirname "$COMFY_DIR")"
  cp -r "$BAKED" "$COMFY_DIR"
fi

# 2) Restore the Manager snapshot (nodes + pinned versions + pip deps).
#    Idempotent: skip if this exact snapshot was already applied on this disk.
SNAP="$UPLOADS/snapshot.json"
MARKER="$COMFY_DIR/.dstack-applied-snapshot.sha"
if [ -f "$SNAP" ]; then
  sum="$(sha256sum "$SNAP" | cut -d' ' -f1)"
  if [ "$(cat "$MARKER" 2>/dev/null || true)" != "$sum" ]; then
    log "restoring ComfyUI-Manager snapshot..."
    if python3.12 "$COMFY_DIR/custom_nodes/ComfyUI-Manager/cm-cli.py" \
         restore-snapshot "$SNAP"; then
      echo "$sum" > "$MARKER"
      log "snapshot restored."
    else
      log "WARNING: snapshot restore had errors — continuing so SSH/Jupyter still come up."
    fi
  else
    log "snapshot unchanged — skipping restore."
  fi
fi

# 3) Lay in workflows + user config uploaded via `files:`.
if [ -d "$UPLOADS/workflows" ]; then
  log "syncing workflows..."
  mkdir -p "$COMFY_DIR/user/default/workflows"
  cp -r "$UPLOADS/workflows/." "$COMFY_DIR/user/default/workflows/" 2>/dev/null || true
fi
if [ -d "$UPLOADS/user" ]; then
  log "syncing user config..."
  cp -r "$UPLOADS/user/." "$COMFY_DIR/user/" 2>/dev/null || true
fi

log "handing off to /start.sh"
exec /start.sh

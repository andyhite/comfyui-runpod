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

# 3) Lay in the user dir uploaded via `files:` — workflows under
#    user/default/workflows, ComfyUI-Manager config under user/__manager, etc.
if [ -d "$UPLOADS/user" ]; then
  log "syncing user dir (workflows + __manager config)..."
  cp -r "$UPLOADS/user/." "$COMFY_DIR/user/" 2>/dev/null || true
fi

# 4) Download models from the synced manifest, in the BACKGROUND, so ComfyUI
#    comes up immediately and models stream in (refresh the model dropdowns as
#    they finish). Idempotent: skips files already on disk. Gated repos (Flux.2
#    Klein 9B) need HF_TOKEN — passed as an Authorization header when set.
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
      echo "[models] downloading $fn -> models/$dir"
      hdr=()
      [ -n "${HF_TOKEN:-}" ] && hdr=(--header="Authorization: Bearer $HF_TOKEN")
      if wget -q "${hdr[@]}" -c -O "$dest.part" "$url"; then
        mv "$dest.part" "$dest"; echo "[models] done $fn"
      else
        echo "[models] FAILED $fn — gated? check HF_TOKEN and license acceptance"
        rm -f "$dest.part"
      fi
    done < "$MANIFEST"
    echo "[models] all downloads complete"
  ) &
fi

log "handing off to /start.sh"
exec /start.sh

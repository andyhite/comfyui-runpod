# Custom ComfyUI image for RunPod + dstack.
#
# A thin wrapper over RunPod's official image. It only adds a smart entrypoint
# that, at boot, restores a ComfyUI-Manager snapshot and lays in the workflows /
# config that dstack uploads via `files:`, then hands off to the base image's
# /start.sh.
#
# HYBRID model:
#   - Bake the snapshot below so cold starts skip clone/install for the stable set.
#   - `files:` still ships the CURRENT pod/snapshot.json every `make up`; the
#     entrypoint's restore-snapshot then applies only the DELTA since the bake.
#   - When the delta grows enough to slow boots, `make image-build` to re-bake.
#
# The bake also writes the snapshot's checksum as the entrypoint's idempotency
# marker, so an unchanged snapshot skips restore-snapshot entirely at boot.
#
# Base is the CUDA 12.8 variant, NOT 13.0: most cheap RunPod hosts ship 12.8
# drivers (CUDA 13 needs driver >= 580), so a cuda13.0 image crashes with
# "NVIDIA driver too old (found 12080)". 12.8 matches the fleet; CUDA 13 buys
# nothing for WAN/Flux. RunPod runs x86_64 — always build for linux/amd64.
FROM runpod/comfyui:cuda12.8

COPY entrypoint.sh /usr/local/bin/dstack-entry.sh
RUN chmod +x /usr/local/bin/dstack-entry.sh

# rclone — the entrypoint uses it for the R2 model cache + output persistence
RUN apt-get update && apt-get install -y --no-install-recommends rclone \
 && rm -rf /var/lib/apt/lists/*

# --- Bake the snapshot (comment this block out to install purely at boot) -----
# Harmless while pod/snapshot.json is empty (no-op); fill the snapshot, then
# `make image-build` to actually bake your nodes in.
COPY pod/snapshot.json /opt/baked-snapshot.json
RUN if python3.12 -c "import json,sys; d=json.load(open('/opt/baked-snapshot.json')); sys.exit(0 if (d.get('git_custom_nodes') or d.get('cnr_custom_nodes') or d.get('file_custom_nodes')) else 1)"; then \
      echo "Baking snapshot..."; \
      COMFYUI_PATH=/opt/comfyui-baked python3.12 \
        /opt/comfyui-baked/custom_nodes/ComfyUI-Manager/cm-cli.py \
        restore-snapshot /opt/baked-snapshot.json; \
    else echo "Snapshot empty — skipping bake (installs at boot instead)."; fi \
 && sha256sum /opt/baked-snapshot.json | cut -d' ' -f1 \
      > /opt/comfyui-baked/.dstack-applied-snapshot.sha
# -----------------------------------------------------------------------------

ENTRYPOINT ["/usr/local/bin/dstack-entry.sh"]

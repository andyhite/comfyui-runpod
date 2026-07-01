# Custom ComfyUI image for RunPod + dstack.
#
# A thin wrapper over RunPod's official image. It only adds a smart entrypoint
# that, at boot, restores a ComfyUI-Manager snapshot and the R2-persisted user
# dir (workflows / config), then hands off to the base image's /start.sh.
#
# Snapshot ownership lives in R2, not the image:
#   - The entrypoint restores the ComfyUI-Manager snapshot from
#     r2://$R2_BUCKET/snapshot.json at boot (delta over the base image nodes).
#   - A background inotify watcher re-uploads a fresh snapshot to R2 whenever
#     custom_nodes changes, so R2 stays current with no repo edit or rebuild.
#   - This image only needs a rebuild when entrypoint.sh (or deps below) change.
#
# CUDA 13.0 base. Some nodes (e.g. comfyui-rmbg BodySegment) ship deps built
# against the CUDA 13 runtime (libcudart.so.13), which only exists here. The
# catch is the host DRIVER must be >= R580; dstack can't filter by driver, so we
# (a) whitelist CUDA-13 GPU architectures and (b) the entrypoint runs a CUDA
# preflight that exits non-zero on an old-driver host so dstack retries another.
# RunPod runs x86_64 — always build for linux/amd64.
FROM runpod/comfyui:cuda13.0

COPY entrypoint.sh /usr/local/bin/dstack-entry.sh
RUN chmod +x /usr/local/bin/dstack-entry.sh

# rclone — R2 model cache + output/snapshot persistence.
# inotify-tools — the entrypoint's custom_nodes snapshot watcher (inotifywait).
RUN apt-get update && apt-get install -y --no-install-recommends rclone inotify-tools \
 && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/usr/local/bin/dstack-entry.sh"]

# Custom ComfyUI image for RunPod + dstack.
#
# A thin wrapper over RunPod's official image. It only adds a smart entrypoint
# that, at boot, restores four R2-mirrored directories (custom_nodes, user,
# models, output), installs custom-node deps, starts a filesystem-watcher per
# dir that mirrors it back to R2, then hands off to the base image's /start.sh.
# R2 is the single source of truth; this image only needs a rebuild when
# entrypoint.sh (or the deps below) change.
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

# rclone — R2 restore + the per-directory mirror.
# inotify-tools — the entrypoint's directory watchers (inotifywait).
RUN apt-get update && apt-get install -y --no-install-recommends rclone inotify-tools \
 && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/usr/local/bin/dstack-entry.sh"]

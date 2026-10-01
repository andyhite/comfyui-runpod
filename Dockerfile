# Custom ComfyUI image for RunPod + dstack.
#
# A thin wrapper over RunPod's official image. It only adds a smart entrypoint
# that, at boot, restores five R2-mirrored directories (custom_nodes, user,
# models, input, output), installs custom-node deps, starts a filesystem-watcher
# per dir that mirrors it back to R2, then hands off to the base image's
# /start.sh.
# R2 is the single source of truth; this image only needs a rebuild when
# entrypoint.sh, the deps below, or the ComfyUI pin change.
#
# CUDA 13.0 base. Some nodes (e.g. comfyui-rmbg BodySegment) ship deps built
# against the CUDA 13 runtime (libcudart.so.13), which only exists here. The
# catch is the host DRIVER must be >= R580; dstack can't filter by driver, so we
# (a) whitelist CUDA-13 GPU architectures and (b) the entrypoint runs a CUDA
# preflight that exits non-zero on an old-driver host so dstack retries another.
# RunPod runs x86_64 — always build for linux/amd64.
# Pinned by digest (multi-arch index; tag kept for readability). Bump:
#   docker buildx imagetools inspect runpod/comfyui:cuda13.0   # copy "Digest:"
FROM runpod/comfyui:cuda13.0@sha256:094dc6d79448b6f118c4d2b054073f92d765c568598e7a96aaeda678a6bcbf3b

# The ComfyUI release this image ships. RunPod's ComfyUI bumps lag upstream by
# weeks (runpod/comfyui:cuda13.0 bakes v0.30.0 as of bundle 1.4.7), so the
# version is pinned here and installed below instead. Bump + rebuild to move it:
#   make image-build COMFYUI_VERSION=v0.37.0
# Releases: https://github.com/comfyanonymous/ComfyUI/releases
ARG COMFYUI_VERSION=v0.36.0

# rclone — R2 restore + the per-directory mirror. Pinned release, NOT apt: the
# distro package predates the `Cloudflare` S3 provider (rclone v1.59). Bump:
# new version from https://downloads.rclone.org/version.txt, sha256 from
# https://downloads.rclone.org/<ver>/SHA256SUMS (linux-amd64.zip).
# inotify-tools — the entrypoint's directory watchers (inotifywait).
ARG RCLONE_VERSION=v1.75.1
ARG RCLONE_SHA256=982b5aa772841168f8e380f139e9e787b2a105403e32b94da8676a0e1c0a13ab
RUN apt-get update && apt-get install -y --no-install-recommends inotify-tools curl unzip ca-certificates \
 && curl -fsSL -o /tmp/rclone.zip "https://downloads.rclone.org/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-linux-amd64.zip" \
 && echo "${RCLONE_SHA256}  /tmp/rclone.zip" | sha256sum -c - \
 && unzip -j /tmp/rclone.zip '*/rclone' -d /usr/local/bin \
 && chmod 0755 /usr/local/bin/rclone \
 && rm -f /tmp/rclone.zip \
 && rm -rf /var/lib/apt/lists/*

# Move the baked ComfyUI to $COMFYUI_VERSION.
#
# /opt/comfyui-baked is the tree both /start.sh and our entrypoint copy onto a
# fresh pod disk, and RunPod ships it as a git repo — one synthetic commit,
# tagged with the version, `origin` on upstream — so ComfyUI-Manager can read a
# version off it. A depth-1 tag fetch plus a hard reset swaps the tree to the
# real upstream release commit; untracked files (the baked custom nodes) are
# left alone. Old tags go so `git gc` can drop the superseded objects instead of
# carrying a second copy of ComfyUI in this layer.
#
# The requirements install is NOT optional: /start.sh builds the pod's venv with
# `python3.12 -m venv --system-site-packages` (then `ensurepip`) and never
# installs requirements.txt, so every ComfyUI dep (comfyui-frontend-package,
# workflow templates, comfy-kitchen …) has to be in the image's system
# site-packages at the versions this release pins. PIP_CONSTRAINT is the base
# image's torch pin (torch==2.10.0+cu130), and it travels with the matching
# index: without both, a resolver nudge on torch swaps the CUDA-13 build for a
# stock one and the CUDA preflight then fails.
RUN set -eux; \
    cd /opt/comfyui-baked; \
    git fetch --depth 1 --no-tags origin "refs/tags/${COMFYUI_VERSION}:refs/tags/${COMFYUI_VERSION}"; \
    git reset --hard "refs/tags/${COMFYUI_VERSION}"; \
    for tag in $(git tag); do [ "$tag" = "${COMFYUI_VERSION}" ] || git tag -d "$tag"; done; \
    git reflog expire --expire=now --all; \
    git gc --prune=now -q; \
    test "v$(sed -n 's/^__version__ = "\(.*\)"/\1/p' comfyui_version.py)" = "${COMFYUI_VERSION}"; \
    sed -i "s|^COMFYUI_VERSION=.*|COMFYUI_VERSION=${COMFYUI_VERSION}|" .runpod-bundle-version; \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    PIP_CONSTRAINT=/opt/comfyui-runtime-constraints.txt \
    PIP_EXTRA_INDEX_URL=https://download.pytorch.org/whl/cu130 \
    python3.12 -m pip install --no-cache-dir -r requirements.txt

# SageAttention — prebuilt wheel, no on-image compile. There's no official
# PyPI package; upstream (thu-ml/SageAttention) ships source only and needs a
# CUDA devel toolchain + a GPU present at build time to compile, neither of
# which this build environment has. snw35/sageattention-wheel cross-builds
# wheels on their own GPU hardware and publishes them as GitHub release
# assets instead. Pinned to the cu13/cp312 "basic" wheel (no bundled CUDA
# libs) since the base image already carries a matching CUDA 13 runtime;
# bump the URL when moving to a new SageAttention release.
RUN PIP_BREAK_SYSTEM_PACKAGES=1 \
    PIP_CONSTRAINT=/opt/comfyui-runtime-constraints.txt \
    PIP_EXTRA_INDEX_URL=https://download.pytorch.org/whl/cu130 \
    python3.12 -m pip install --no-cache-dir \
      "https://github.com/snw35/sageattention-wheel/releases/download/cu12-2.2.0-cu13-2.2.0/sageattention-2.2.0%2Bcu13-cp312-cp312-linux_x86_64.whl#sha256=60531840b2e8f1a8c8d369cfb774a50b8f82c714685efcc7bbfd92ee4b209605"

# Last, so editing it — the usual reason to rebuild — invalidates nothing else.
COPY --chmod=0755 entrypoint.sh /usr/local/bin/dstack-entry.sh

ENTRYPOINT ["/usr/local/bin/dstack-entry.sh"]

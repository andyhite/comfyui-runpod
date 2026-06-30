# ComfyUI on RunPod via dstack

Spin up a ComfyUI pod on the cheapest 24–48 GB CUDA-13 GPU under $1.20/hr
(RunPod, any region), with your custom nodes, workflows, and config provisioned
declaratively.

## How it works

- **Custom image** (`Dockerfile`) — a thin wrapper over `runpod/comfyui:cuda13.0`
  that adds `entrypoint.sh`. Rebuilt only when `entrypoint.sh` changes.
- **`pod/` payload**, synced to the pod on every `make up` via dstack `files:`:
  - `pod/snapshot.json` — a **ComfyUI-Manager snapshot**: your custom nodes, pinned
    to commits, with their pip deps. Restored at boot (`cm-cli restore-snapshot`).
  - `pod/workflows/` — your workflow `.json` files.
  - `pod/user/` — optional baseline ComfyUI config (e.g. `comfy.settings.json`).
- **`entrypoint.sh`** at boot: populate ComfyUI → restore the snapshot (idempotent,
  skipped if unchanged) → drop in workflows/config → hand off to the image's
  `/start.sh` (venv, ComfyUI, SSH, JupyterLab, FileBrowser).

**Hybrid bake + overlay (default):** the image **bakes** the snapshot at build
time (fast cold starts — nodes pre-installed), while `files:` still ships the
*current* snapshot every `make up`. At boot, `restore-snapshot` applies only the
**delta** since the last bake — so you add/update nodes by editing
`pod/snapshot.json` and re-running `make up` (no rebuild), and `make image-build`
periodically to re-bake when the delta grows. An unchanged snapshot skips restore
entirely (the bake writes its checksum as the boot idempotency marker).

## Usage

```bash
make image-build   # once (and when entrypoint.sh changes); needs `docker login ghcr.io`
make server        # terminal 1, leave running
make fleet         # once — registers the instance pool dstack provisions into
make up            # provision pod + upload payload + attach
# → http://localhost:8188 (ComfyUI), :8888 (Jupyter), :8080 (FileBrowser)
make down          # tear down
```

Generate `pod/snapshot.json` from a working setup: `make snapshot-help`.

## Trade-offs & not-yet-wired

- **Boot cost:** mostly handled by the hybrid bake — cold starts only install the
  *delta* between the baked snapshot and the current one. Keep it small by
  re-baking (`make image-build`) when you've accumulated node changes. (Building on
  an Apple-silicon Mac uses amd64 emulation, so the bake step is slower there.)
- **Models** — *not handled yet.* Download on the pod as needed (ComfyUI-Manager
  "Install Missing Models" covers models in its DB; others need a manifest).
- **Outputs / persistence** — *not handled yet.* No network volume, so outputs are
  on ephemeral disk. Download via the UI before `make down`, or wire object-storage
  sync (R2/S3).

## Files

| File | Purpose |
|---|---|
| `Dockerfile`, `entrypoint.sh` | custom image |
| `comfyui.dstack.yml` | the run (task): image, GPU, ports, `files:` |
| `comfyui-fleet.dstack.yml` | the instance pool |
| `pod/` | snapshot + workflows + config synced to the pod |
| `Makefile` | commands |

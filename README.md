# ComfyUI on RunPod via dstack

Spin up a ComfyUI pod on the cheapest 24–48 GB CUDA-13 GPU under $1.20/hr
(RunPod, any region), with your custom nodes, workflows, and config provisioned
declaratively.

## How it works

- **Custom image** (`Dockerfile`) — a thin wrapper over `runpod/comfyui:cuda13.0`
  that adds `entrypoint.sh`. CUDA 13 is required by some node deps (e.g.
  comfyui-rmbg BodySegment → `libcudart.so.13`). Because it needs an R580+ host
  driver and dstack can't filter by driver, the config whitelists CUDA-13 GPU
  architectures, and the entrypoint runs a CUDA preflight that exits so dstack's
  `retry` lands a working host.
- **`pod/` payload**, synced to the pod on every `make up` via dstack `files:`:
  - `pod/snapshot.json` — a **ComfyUI-Manager snapshot**: your custom nodes, pinned
    to commits, with their pip deps. Restored at boot (`cm-cli restore-snapshot`).
  - `pod/user/` — synced wholesale into ComfyUI's `user/` dir:
    `default/workflows/` (your workflow `.json` files) and
    `__manager/config.ini` (ComfyUI-Manager config).
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
- **Models** — declared in `pod/models.txt` (`<models/ subdir>  <URL>`), synced via
  `files:`, downloaded at boot in the background (idempotent). Gated repos (Flux.2
  Klein 9B) need an HF token + license acceptance at
  huggingface.co/black-forest-labs/FLUX.2-klein-9B.
- **Persistence (R2)** — an R2 bucket (`comfyui`) is the persistence layer:
  - **Models cache** (`r2://comfyui/models`): each boot pulls from R2; on a miss it
    downloads from origin and caches back up. First boot seeds R2 (slow); later
    boots are fast (free egress, gated model no longer needs the token).
  - **Outputs** (`r2://comfyui/outputs`): synced every 30s so they survive teardown.
  - **User dir** (`r2://comfyui/user`): workflows, `__manager/config.ini`, comfy
    settings — the repo's `pod/user` is the baseline seed, the R2 copy (your live
    edits) is overlaid on top at boot and pushed every 30s, so workflow/config
    changes persist instead of resetting to the committed version. Additive copy,
    so deletions don't propagate (prune R2 manually). `__manager/cache` excluded.
  - rclone (in the image) is configured via `RCLONE_CONFIG_R2_*` env from dstack
    secrets. No R2 secrets → models from origin only, outputs not persisted.

  Setup: `make r2-bucket` (done), then `make secrets-help` for the secrets to set
  (`HF_TOKEN`, `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`) — account-
  specific values stay out of this public repo. Create the R2 API token in the
  Cloudflare dashboard (R2 → Manage R2 API Tokens → Object Read & Write).
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

# ComfyUI on RunPod via dstack

Spin up a ComfyUI pod on RunPod (any region) with your custom nodes,
workflows, and config provisioned declaratively. Two launch modes, same
image/fleet: `make up` pins the RTX5090 (fast, ~$0.99/hr); `make up-cheap`
floats across the whole Blackwell menu and takes whichever card is cheapest
right now (usually an RTXPRO4000, ~$0.57/hr, slower). Both stay under the
$1.50/hr cap.

## How it works

- **Custom image** (`Dockerfile`) — a thin wrapper over `runpod/comfyui:cuda13.0`
  that adds `entrypoint.sh` and pins ComfyUI itself to an upstream release
  (`ARG COMFYUI_VERSION`, currently `v0.36.0`) because RunPod's own bake lags
  upstream by weeks; `make image-build COMFYUI_VERSION=v0.37.0` moves it. CUDA
  13 is required by some node deps (e.g. comfyui-rmbg BodySegment →
  `libcudart.so.13`). Because it needs an R580+ host driver and dstack can't
  filter by driver, the config whitelists CUDA-13 GPU architectures, and the
  entrypoint runs a CUDA preflight that exits so dstack's `retry` lands a
  working host.
- **R2 is an exact mirror** of five directories: `custom_nodes/`, `user/`,
  `models/`, `input/`, and `output/`. Nothing is uploaded to the pod —
  everything the pod needs is restored from R2 at boot.
- **`entrypoint.sh`** at boot: populate ComfyUI from the baked image if the disk
  is fresh → restore `custom_nodes` and `user` from R2 (blocking) → install
  custom-node dependencies → restore `input`, `models`, and `output` from R2 in
  the background (ComfyUI comes up while they stream) → pin ComfyUI to a loopback
  bind (see Trade-offs) → hand off to the image's `/start.sh` (venv, ComfyUI,
  SSH, JupyterLab, FileBrowser). A filesystem watcher per directory then mirrors
  any change back to R2, starting only once that directory's restore has
  succeeded.

## Usage

```bash
make image-build   # once (and when entrypoint.sh or the ComfyUI pin changes); needs `docker login ghcr.io`
make server        # terminal 1, leave running
make fleet         # once — registers the instance pool dstack provisions into
make up            # provision pod + attach (RTX5090, pinned)
# ...or: make up-cheap   # provision on whatever Blackwell GPU is cheapest right now
# → http://localhost:8188 (ComfyUI), :8888 (Jupyter), :8080 (FileBrowser)
make down          # tear down
```

Install models and nodes on the running pod (ComfyUI-Manager); they mirror to
R2 automatically.

## Trade-offs & Persistence

- **Models** — R2 is the sole source; there's no manifest. A first-ever boot
  against an empty R2 has zero models. Download what you need once
  (ComfyUI-Manager, or the MCP download tool) and the watcher seeds R2; every
  later boot restores from there. Gated repos (Flux.2 Klein 9B) still need an HF
  token + license acceptance at huggingface.co/black-forest-labs/FLUX.2-klein-9B.
- **Persistence** — R2 mirrors `custom_nodes/`, `user/`, `models/`, `input/`,
  and `output/` exactly. Restore (R2 → pod) uses `copy`; the running mirror
  (pod → R2) uses `sync`, so deletions and renames propagate to R2 — delete
  something on the pod and it's gone from R2 after the next debounce.
- **Excludes** — `.venv`, `venv`, `__pycache__`, `*.pyc`, `*.part*`, `*.tmp`,
  `*.log`, and `comfyui.db*` are excluded everywhere; `user` additionally
  excludes `__manager/cache/**`. `.git` is kept, so ComfyUI-Manager can still
  identify each node's repo and version.
- **Safety** — a directory's watcher starts only after its restore succeeds, so
  a degraded boot can never wipe R2.
- **Loopback bind** — the entrypoint appends `--listen 127.0.0.1` to
  `/workspace/runpod-slim/comfyui_args.txt`, which `/start.sh` appends after its
  own `--listen 0.0.0.0` (argparse takes the last one). ComfyUI-Manager permits
  installs from outside the default channel — git URLs, nightly versions,
  unregistered packs — only when `args.listen` is a loopback address; on
  `0.0.0.0` they fail with 404 no matter what `security_level` or
  `allow_git_url_install` say. Reach the pod through the dstack forward
  (`http://localhost:8188`); the RunPod HTTP proxy cannot reach a loopback bind.
- **Setup** — unchanged: `make r2-bucket` (once), then `make secrets-help` for
  the secrets to set (`HF_TOKEN`, `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`,
  `R2_SECRET_ACCESS_KEY`) — account-specific values stay out of this public
  repo. `HF_TOKEN` is now optional: it's only used by nodes that call Hugging
  Face at runtime, not for model seeding. Create the R2 API token in the
  Cloudflare dashboard (R2 → Manage R2 API Tokens → Object Read & Write).

## Files

| File | Purpose |
|---|---|
| `Dockerfile`, `entrypoint.sh` | custom image; entrypoint restores + mirrors the five R2 directories |
| `comfyui.dstack.yml` | the run (task), RTX5090-pinned mode: image, GPU, ports, R2 env |
| `comfyui-cheap.dstack.yml` | the run (task), cheapest-Blackwell mode — same as above minus the GPU pin |
| `comfyui-fleet.dstack.yml` | the instance pool |
| `Makefile` | commands |

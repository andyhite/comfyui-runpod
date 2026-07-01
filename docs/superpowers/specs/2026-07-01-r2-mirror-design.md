# R2 Directory Mirror — Design

**Date:** 2026-07-01
**Status:** Approved, pending implementation
**Supersedes:** `2026-06-30-r2-auto-snapshots-design.md` (snapshot-based approach)

## Problem

The current `entrypoint.sh` persists pod state to R2 through four unrelated
mechanisms: a marker-gated ComfyUI-Manager snapshot restore, an event-driven
snapshot uploader, a manifest-driven model downloader (R2 cache → HF origin →
cache-up), and a 30s time-based copy loop for outputs + the user dir. It works,
but the moving parts are hard to reason about and each behaves differently.

Replace all of it with **one uniform idea**: watch the directories we care about,
and mirror them to R2 so R2 is an *exact copy*. Restore from R2 on boot.

## Goal

R2 is an exact mirror of four pod directories:

- `custom_nodes/`
- `user/`
- `models/`
- `output/`

A filesystem watcher on each directory `rclone sync`s changes up to R2. On boot,
the pod restores each directory from R2, then (re)installs custom-node
dependencies so the restored nodes actually work in the fresh venv.

## Key Decisions

1. **Models: R2 is the sole source of truth.** Drop the `pod/models.txt`
   manifest and the Hugging Face origin fallback entirely. Models are just
   another mirrored directory. Consequence: a first-ever boot against an empty
   R2 has **zero** models — you seed them once by downloading into the pod (via
   ComfyUI-Manager or the MCP download tool) and the watcher pushes them up.
   Every subsequent boot restores them from R2.

2. **Custom-node restore = code from R2 + dependency install.** The mirror brings
   back the node *code* (including each node's `.git`). It does **not** bring back
   the venv, so on boot we run `cm-cli restore-dependencies` to install each
   node's `requirements.txt`, plus a sweep that runs any `install.py`. No node
   updates on boot — nodes stay at whatever commit R2 holds; you update them
   deliberately via Manager.

3. **Architecture: four independent watcher+sync loops** (one per directory), not
   a single unified watcher. A slow 100 GB `models` scan must never block a fast
   `output` push, and each directory can carry exclusion rules suited to it.

4. **Sync direction is asymmetric.** Restore (R2 → pod) uses `rclone copy`
   (non-destructive). The running mirror (pod → R2) uses `rclone sync` (exact
   mirror — deletions and renames propagate to R2). This is intentional: R2
   should be an exact copy, including removals.

5. **Boot gating: block on `custom_nodes` + `user`, stream `models` + `output`.**
   The first two are small and required for a correct launch (deps installed,
   workflows/config present). Models and outputs restore in the background so
   ComfyUI is usable within ~a minute; a run only fails if its specific model
   has not landed yet.

## The Safety Invariant

`rclone sync` (pod → R2) is destructive: if it runs against an empty or
half-restored local directory, it will **delete those paths in R2**.

Therefore: **a directory's up-sync watcher starts only after that directory's
restore has completed successfully.**

- `custom_nodes` / `user` watchers start after the blocking restore (and dep
  install) finishes.
- `models` / `output` watchers start after their background restore finishes.
- If a restore **fails**, that directory's watcher **never starts** — no up-sync,
  so a stale/degraded pod can never wipe good data in R2. A stale pod beats a
  wiped bucket.

This closes the race where a watcher fires mid-restore (because one file landed)
and `sync` deletes every not-yet-downloaded file from R2.

## Boot Sequence (`entrypoint.sh`)

1. **CUDA-13 preflight** — unchanged. Force a CUDA allocation; exit 1 on an
   old-driver host so dstack retries elsewhere.
2. **Populate ComfyUI from the baked image** if the disk is fresh — unchanged.
3. **Detect R2** — enable persistence only if `RCLONE_CONFIG_R2_ACCESS_KEY_ID`,
   `R2_BUCKET`, and `R2_ACCOUNT_ID` are all set; build the R2 endpoint from
   `R2_ACCOUNT_ID`. Otherwise the pod runs with no persistence. Unchanged.
4. **Blocking restore — `custom_nodes` + `user`** via `rclone copy` R2 → pod,
   with the exclusion sets below.
5. **Install node deps** — `cm-cli restore-dependencies` (installs each restored
   node's `requirements.txt` into the fresh venv), followed by a sweep that runs
   any `install.py` found in a node directory. During implementation, verify
   whether `restore-dependencies` already runs `install.py`; if so, drop the
   sweep as redundant.
6. **Background restore — `models` + `output`** via `rclone copy` R2 → pod, kicked
   off as background jobs. Each job starts that directory's watcher **only after**
   its copy completes (per the safety invariant).
7. **Start the `custom_nodes` + `user` watchers** — gated on step 4/5 success.
8. **`exec /start.sh`** — hands off to the base image, which creates the venv and
   launches ComfyUI, SSH, JupyterLab, FileBrowser. Backgrounded watcher processes
   survive the `exec`.

If R2 is not configured, skip steps 4–7 entirely; the pod runs with no
persistence (models must be downloaded fresh, outputs are ephemeral).

## The Watcher Unit

One reusable shell function, instantiated four times:

```
watch_sync <name> <local_dir> <r2_subpath> <inotify-exclude-regex> <rclone-exclude-globs...>
```

Behavior:

```
inotifywait -m -r -q \
  -e create -e delete -e modify -e moved_to -e moved_from \
  --exclude <inotify-exclude-regex> \
  <local_dir> |
while read -r _; do
  # Debounce: drain further events until DEBOUNCE seconds of quiet.
  while read -r -t "${DEBOUNCE:-15}" _; do :; done
  rclone sync <local_dir> "r2:$R2_BUCKET/<r2_subpath>" <rclone-exclude-globs>
done
```

- **Debounce** coalesces bursts (a node install, a multi-file workflow save, a
  large model write) into a single sync once the directory goes quiet.
  `DEBOUNCE` defaults to 15s, env-overridable.
- Because in-progress downloads are excluded (`*.part*`) and large writes keep
  the directory "noisy" until they finish, a multi-GB model only syncs after its
  write completes — never mid-transfer.
- One `rclone sync` runs at a time per loop; events arriving during a sync queue
  in the pipe and are drained by the next debounce. On sync failure, log and
  continue — the next event retries.

Each instance is a background process started per the gating rules above.

## Exclusion Rules

Applied to **both** the inotify `--exclude` regex (POSIX extended regex, single
pattern) and the `rclone --exclude` globs (multiple patterns) — same intent, two
syntaxes.

**Global (all four directories):**

| Pattern | Reason |
|---|---|
| `.venv/`, `venv/` | Per-node virtualenvs — large, machine-specific, regenerable |
| `__pycache__/`, `*.pyc` | Python bytecode caches |
| `*.part*` | In-progress downloads |
| `*.tmp` | Temp files |
| `*.log` | Logs |
| `comfyui.db*` | ComfyUI sqlite db — regenerable and can be locked |

**`.git` is NOT excluded** — ComfyUI-Manager needs it to identify each node's
repo and version and to update nodes later.

**`user`-directory addition:** also exclude `__manager/cache/**` — large and
regenerable (excluded under the current design too).

Example rclone globs: `--exclude '.venv/**' --exclude 'venv/**' --exclude
'__pycache__/**' --exclude '*.pyc' --exclude '*.part*' --exclude '*.tmp'
--exclude '*.log' --exclude 'comfyui.db*'` (plus `--exclude '__manager/cache/**'`
for `user`).

Example inotify regex: `(/\.venv/|/venv/|/__pycache__/|\.pyc$|\.part|\.tmp$|\.log$|comfyui\.db)`
(plus `|/__manager/cache/` for `user`).

## What Gets Removed

- **All snapshot machinery** in `entrypoint.sh`: `_snapshot_generate`,
  `snapshot_seed`, `snapshot_reconcile`, `snapshot_watch`, the `BASELINE_SHA` /
  `MARKER` SHA logic, the boot `restore-snapshot` block, and the
  `r2:$R2_BUCKET/snapshot.json` object.
- **The manifest model downloader**: the `models.txt` read loop, the origin/HF
  `wget` fallback, the download heartbeat, and the 120s R2 cache-up loop.
- **The 30s `output` + `user` copy loop** — replaced by watchers.
- **`pod/models.txt`** and its `files:` entry in `comfyui.dstack.yml`.
- **`tests/snapshot_watch_test.sh`** — replaced by a `watch_sync` test.
- **Snapshot references in docs**: `README.md` and the
  `docs/superpowers/{specs,plans}/2026-06-30-r2-auto-snapshots*` files, updated to
  describe the mirror model (or marked superseded).

## Environment / Config Impact

- `comfyui.dstack.yml`: remove the `pod/models.txt` `files:` entry. The R2 env
  vars and secrets are unchanged. `HF_TOKEN` is no longer needed for model
  downloads (R2 is sole source) but may stay for any node that uses it at
  runtime — leave it, note it's no longer used for seeding.
- No new secrets. `DEBOUNCE` is an optional env override (default 15s).

## Testing

- **`watch_sync` unit test** (replacing `snapshot_watch_test.sh`): source
  `entrypoint.sh` with `ENTRYPOINT_LIB_ONLY=1`, point the function at a temp dir
  and a fake `rclone` on `PATH`, and assert:
  - a burst of file events produces exactly one `rclone sync` after the debounce;
  - excluded paths (`.venv/`, `__pycache__/`, `*.part`) do not trigger a sync;
  - the sync targets the correct `r2:` subpath with the expected `--exclude`
    globs.
- **Boot-gating test**: assert (via a stubbed `rclone` that records call order)
  that no up-sync for a directory is issued before that directory's restore has
  returned, and that a simulated restore failure leaves that directory's watcher
  unstarted.

## Consequences / Accepted Trade-offs

- **Empty R2 = no models on first boot.** Seed once, then restore forever. This
  is the direct, accepted result of "R2 is sole source."
- **Destructive mirror.** Deleting a workflow, output, node, or model on the pod
  deletes it from R2 after the next debounce. This is the intended "exact copy"
  behavior — there is no longer an additive-only safety net. Deliberate deletion
  is the only way things leave R2.
- **Up to `DEBOUNCE` seconds of edits can be lost on an abrupt pod stop** — the
  last un-synced burst. Same class of window as today's 30s loop, smaller.
- **Node deps reinstall every cold start.** The venv is fresh each boot (no
  volume), so `restore-dependencies` runs every time. This is inherent to the
  no-volume ephemeral-pod model and is what happens today.

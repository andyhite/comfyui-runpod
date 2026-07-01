> **SUPERSEDED (2026-07-01)** by the R2 directory-mirror design
> (`docs/superpowers/specs/2026-07-01-r2-mirror-design.md`). The snapshot-based
> approach described below is no longer implemented.

# R2-backed auto-snapshots — design

**Date:** 2026-06-30
**Status:** Approved (pending spec review)

## Problem

Today `pod/snapshot.json` (a ComfyUI-Manager snapshot: custom nodes pinned to
commits + their pip deps) is committed to the repo and shipped *up* to the pod:
via `files:` in `comfyui.dstack.yml`, baked into the image, and restored at boot.
Keeping it current is a manual chore — SSH in, `save-snapshot`, download, commit,
`make up`.

We want to invert this: **R2 becomes the single source of truth for the
snapshot, and the pod maintains it automatically.** When custom nodes change on a
running pod (install/update/remove via ComfyUI-Manager), the pod regenerates the
snapshot and uploads it to `r2://$R2_BUCKET/snapshot.json`. Cold starts restore
that snapshot from R2 as a delta over the base image's nodes.

## Decisions

- **Trigger:** inotify watch on `custom_nodes` (real-time), debounced.
- **Baking:** dropped entirely. No committed snapshot, no build-time bake. Cold
  starts restore the delta from the R2 snapshot at boot.
- **Startup seed without upload:** on watcher start, generate a baseline snapshot
  and record it *without uploading*, so a possibly-degraded boot state never
  clobbers the good R2 snapshot. Only genuine subsequent changes are pushed.
- **Capture updates too:** include `modify` events (not just create/delete) so
  node *updates* (git pulls that change working-tree files) are captured, with a
  diff-guard to suppress redundant uploads.

## Changes

### Removals — snapshot no longer ships up

- **Delete `pod/snapshot.json`.**
- **`comfyui.dstack.yml`:** remove `./pod/snapshot.json:/opt/uploads/snapshot.json`
  from `files:` (keep `./pod/models.txt`). Update the surrounding comment that
  says updating nodes ships snapshot.json.
- **`Dockerfile`:**
  - Remove the bake block: `COPY pod/snapshot.json /opt/baked-snapshot.json` and
    the `RUN` that runs `restore-snapshot` / `restore-dependencies` and writes the
    `.dstack-applied-snapshot.sha` marker (current lines ~31–45).
  - Add `inotify-tools` to the existing `apt-get install` line (alongside
    `rclone`).
  - Rewrite the "HYBRID model" header comment to describe the new flow (base
    nodes in the image, delta restored from R2 at boot, auto-maintained).
- **`.dockerignore`:** drop the `!pod/snapshot.json` allow-line (and its comment
  reference).
- **`Makefile`:** retire the `snapshot-help` target (snapshotting is now
  automatic). Fix the day-to-day comment ("edit pod/snapshot.json or
  pod/models.txt, then make up") to reference only `models.txt`. Fix the `up`
  target's help text ("uploads snapshot + model list") to "uploads model list".
- **`README.md`:** update the snapshot sections — `pod/snapshot.json` is gone;
  describe R2 as the source of truth and the auto-snapshot behavior. Remove the
  `make snapshot-help` reference and the hybrid-bake explanation.

### Boot restore — from R2 (entrypoint step 2)

Replace the `$UPLOADS/snapshot.json` source with R2:

- Keep the existing idempotent structure (checksum marker
  `$COMFY_DIR/.dstack-applied-snapshot.sha`).
- When `R2=1`, pull the snapshot first:
  `rclone copyto "r2:$R2_BUCKET/snapshot.json" /tmp/snapshot.json` (tolerate a
  missing object — first-ever run has none).
- If `/tmp/snapshot.json` exists → run the same checksum-guarded
  `restore-snapshot` + `restore-dependencies` against it.
- If no snapshot in R2 → skip restore; ComfyUI comes up with only the base image
  nodes. The user installs nodes via Manager and the watcher seeds R2. This is
  the new bootstrapping path (no committed baseline).
- When R2 is not configured, there is no snapshot source at all — pod runs with
  base nodes only (documented; matches "pod still works without R2").

### Auto-snapshot watcher (new background block in entrypoint)

Placed **after** step 2's restore completes (so it never reacts to the restore's
own re-cloning or snapshots a half-installed state). Runs only when `R2=1`.

Behavior:

1. **Startup seed:** run `cm-cli.py save-snapshot --output /tmp/snap.json`,
   sha256 → store as `BASELINE_SHA`. Do **not** upload.
2. **Watch:** `inotifywait -m -r -q` on `$COMFY_DIR/custom_nodes` for events
   `create,delete,modify,moved_to,moved_from`, excluding `/\.git/`,
   `__pycache__`, and `\.part` paths.
3. **Debounce:** on the first event, keep draining events until ~30s of
   quiescence (`read -t 30` timeout loop) so a multi-file install coalesces into
   one change.
4. **Generate + diff-guard:** `save-snapshot --output /tmp/snap.json`, sha256. If
   equal to `BASELINE_SHA` → do nothing. If changed →
   `rclone copyto /tmp/snap.json r2:$R2_BUCKET/snapshot.json`, update
   `BASELINE_SHA`, and write the sha to `.dstack-applied-snapshot.sha` (so a
   same-disk reboot doesn't re-restore what we just captured).
5. Log every step with a `[snapshot]` prefix, matching the existing `[models]`
   heartbeat style. Failures are logged and the loop continues — never fatal.

Config knobs (env, with defaults): `SNAPSHOT_DEBOUNCE=30`.

## Data flow

```
Manager installs/updates/removes a node
  -> custom_nodes/ file events
  -> inotifywait (debounced ~30s)
  -> save-snapshot -> sha256 diff vs BASELINE_SHA
  -> changed? rclone copyto -> r2://$R2_BUCKET/snapshot.json   (R2 now current)
                            -> update .dstack-applied-snapshot.sha

Next cold start:
  base image nodes -> rclone copyto r2://.../snapshot.json -> restore-snapshot
  (delta) -> restore-dependencies -> watcher seeds baseline -> ...
```

## Error handling

- **No R2:** watcher never starts; boot restore is skipped. Pod runs on base
  nodes. (Same "works without R2" contract as models/outputs.)
- **Missing R2 object (first run):** `rclone copyto` yields no file; restore is
  skipped cleanly.
- **`inotifywait` / `save-snapshot` / `rclone` failure:** logged under
  `[snapshot]`; the watch loop continues. Never blocks `/start.sh` handoff (the
  block is backgrounded).
- **Churn suppression:** the 30s debounce coalesces install bursts; the sha
  diff-guard prevents uploading semantically-identical snapshots caused by git or
  pip file noise.

## Testing

Bash-in-container work, so:

- `shellcheck entrypoint.sh` passes (no new warnings).
- **Watcher unit simulation:** extract the "on quiescence: generate → diff →
  maybe upload" step into a shell function and drive it locally with stub
  `save-snapshot` (emits a fixed file) and stub `rclone` (records calls),
  asserting:
  - startup seed records baseline and performs **no** upload,
  - an event that yields an identical snapshot performs **no** upload,
  - an event that yields a different snapshot performs **exactly one** upload and
    advances the baseline.
- **Manual pod verification** (documented in README): install a node via Manager,
  confirm `[snapshot]` log lines and that `r2://comfyui/snapshot.json` updates;
  reboot and confirm the node is restored.

## Out of scope (YAGNI)

- Detecting pip changes made outside a custom node (the trigger is scoped to the
  `custom_nodes` directory, per the request).
- Snapshot versioning/history in R2 (single `snapshot.json`, last-write-wins).
- Periodic/time-based snapshots (event-driven only).

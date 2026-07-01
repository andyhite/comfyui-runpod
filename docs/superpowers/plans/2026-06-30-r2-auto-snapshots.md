> **SUPERSEDED (2026-07-01)** by the R2 directory-mirror design
> (`docs/superpowers/specs/2026-07-01-r2-mirror-design.md`). The snapshot-based
> approach described below is no longer implemented.

# R2-backed auto-snapshots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make R2 the single source of truth for the ComfyUI-Manager snapshot — the pod restores it at boot and auto-uploads a fresh snapshot whenever `custom_nodes` changes.

**Architecture:** Drop the committed `pod/snapshot.json` and the build-time bake. `entrypoint.sh` restores the snapshot from `r2://$R2_BUCKET/snapshot.json` at boot (idempotent via a checksum marker), then a backgrounded `inotifywait` watcher on `custom_nodes` debounces file events, regenerates the snapshot with `cm-cli save-snapshot`, and uploads it to R2 only when it changed.

**Tech Stack:** Bash, `inotify-tools` (`inotifywait`), `rclone` (R2/S3), ComfyUI-Manager `cm-cli.py`, Docker, dstack.

## Global Constraints

- Bash scripts use `set -uo pipefail` (no `set -e`); the entrypoint must never fail fatally on snapshot errors — log and continue.
- All snapshot log lines use the `[snapshot]` prefix (matches the existing `[models]` heartbeat style).
- Snapshot behavior is gated on `R2=1`; with no R2 the watcher does not start and boot restore is skipped — the pod must still run on base-image nodes.
- The Manager CLI is invoked as `python3.12 "$CM_CLI" <cmd>` where `CM_CLI="$COMFY_DIR/custom_nodes/ComfyUI-Manager/cm-cli.py"` and `COMFY_DIR=/workspace/runpod-slim/ComfyUI`.
- `COMFYUI_PATH` must be exported before any `cm-cli` call (already exported at the top of `entrypoint.sh`).
- Debounce window is configurable via env `SNAPSHOT_DEBOUNCE` (default `30` seconds).
- Trigger scope is strictly the `custom_nodes` directory (out of scope: pip changes made outside a node, snapshot history/versioning, time-based snapshots).

---

### Task 1: Snapshot watcher functions + unit test (TDD)

Add the reusable snapshot functions to `entrypoint.sh` behind a source-only guard, and a bash test that drives them with stubbed `python3.12` (fake `save-snapshot`) and `rclone`.

**Files:**
- Modify: `entrypoint.sh` (add functions + lib-only guard near the top)
- Test: `tests/snapshot_watch_test.sh` (create)

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `log_snap <msg>` — echoes `[snapshot] <msg>`.
  - Globals read by the functions: `CM_CLI`, `R2_BUCKET`, `MARKER` (path to `.dstack-applied-snapshot.sha`), and mutable `BASELINE_SHA`.
  - `snapshot_seed()` — generates a snapshot to `/tmp/snapshot.gen.json`, sets `BASELINE_SHA` to its sha256, uploads nothing. On generate failure sets `BASELINE_SHA=""`.
  - `snapshot_reconcile <reason>` — generates a snapshot; if its sha256 differs from `BASELINE_SHA`, uploads it to `r2:$R2_BUCKET/snapshot.json`, advances `BASELINE_SHA`, and writes the sha to `$MARKER`. Always returns 0.
  - `snapshot_watch()` — calls `snapshot_seed`, then runs the debounced `inotifywait` loop calling `snapshot_reconcile` on each quiescent burst.
  - Source-only guard: when `ENTRYPOINT_LIB_ONLY` is non-empty, `entrypoint.sh` defines the functions/vars and `return 0`s before running the main boot flow.

- [ ] **Step 1: Write the failing test**

Create `tests/snapshot_watch_test.sh`:

```bash
#!/usr/bin/env bash
# Unit test for entrypoint.sh snapshot functions. Sources the entrypoint in
# lib-only mode and drives snapshot_seed / snapshot_reconcile with stubbed
# `python3.12` (fake save-snapshot) and `rclone`.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# --- stubs on PATH -----------------------------------------------------------
mkdir -p "$WORK/bin"
# Fake `python3.12`: on `save-snapshot --output X`, copy $SNAP_FIXTURE to X.
cat > "$WORK/bin/python3.12" <<'STUB'
#!/usr/bin/env bash
args=("$@"); out=""
for ((i=0; i<${#args[@]}; i++)); do
  [ "${args[$i]}" = "--output" ] && out="${args[$((i+1))]}"
done
case " $* " in
  *" save-snapshot "*) [ -n "$out" ] && cp "$SNAP_FIXTURE" "$out"; exit 0 ;;
esac
exit 0
STUB
# Fake `rclone`: record each copyto destination to $RCLONE_LOG, succeed.
cat > "$WORK/bin/rclone" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "copyto" ]; then echo "$3" >> "$RCLONE_LOG"; fi
exit 0
STUB
chmod +x "$WORK/bin/python3.12" "$WORK/bin/rclone"
export PATH="$WORK/bin:$PATH"

# --- fixtures ----------------------------------------------------------------
printf '{"nodes":"A"}\n' > "$WORK/snapA.json"
printf '{"nodes":"B"}\n' > "$WORK/snapB.json"
export RCLONE_LOG="$WORK/rclone.log"; : > "$RCLONE_LOG"
export MARKER_FILE="$WORK/marker.sha"

# --- source entrypoint in lib-only mode --------------------------------------
export ENTRYPOINT_LIB_ONLY=1
# shellcheck disable=SC1090
. "$ROOT/entrypoint.sh"
CM_CLI="/does/not/matter"   # save-snapshot is stubbed
R2_BUCKET="testbucket"
MARKER="$MARKER_FILE"

# --- assertions --------------------------------------------------------------
# seed with fixture A: baseline set, NO upload.
export SNAP_FIXTURE="$WORK/snapA.json"
snapshot_seed
[ -n "$BASELINE_SHA" ] || fail "seed did not set BASELINE_SHA"
[ ! -s "$RCLONE_LOG" ] || fail "seed uploaded (should not)"
pass "seed sets baseline without uploading"

# reconcile with identical fixture A: NO upload.
snapshot_reconcile "no-change"
[ ! -s "$RCLONE_LOG" ] || fail "reconcile uploaded on no-op change"
pass "reconcile is a no-op when snapshot is unchanged"

# reconcile with fixture B: exactly one upload, marker + baseline advanced.
prev_sha="$BASELINE_SHA"
export SNAP_FIXTURE="$WORK/snapB.json"
snapshot_reconcile "changed"
[ "$(wc -l < "$RCLONE_LOG" | tr -d ' ')" = "1" ] || fail "expected exactly one upload"
grep -q "testbucket/snapshot.json" "$RCLONE_LOG" || fail "wrong upload destination"
[ "$BASELINE_SHA" != "$prev_sha" ] || fail "baseline not advanced"
[ "$(cat "$MARKER_FILE")" = "$BASELINE_SHA" ] || fail "marker not written with new sha"
pass "reconcile uploads once and advances baseline+marker on change"

echo "ALL PASS"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/snapshot_watch_test.sh`
Expected: FAIL — the source step errors or `snapshot_seed: command not found` (functions/guard not in `entrypoint.sh` yet).

- [ ] **Step 3: Add the functions + guard to `entrypoint.sh`**

In `entrypoint.sh`, immediately after the `log() { echo "[dstack-entry] $*"; }` line (currently line 24), insert:

```bash
log_snap() { echo "[snapshot] $*"; }

CM_CLI="$COMFY_DIR/custom_nodes/ComfyUI-Manager/cm-cli.py"
MARKER="$COMFY_DIR/.dstack-applied-snapshot.sha"

# Generate a Manager snapshot of the current custom_nodes state to a temp file.
# Returns 0 and prints the temp path on success; non-zero on failure.
_snapshot_generate() {
  local tmp="/tmp/snapshot.gen.json"
  if python3.12 "$CM_CLI" save-snapshot --output "$tmp" >/dev/null 2>&1; then
    printf '%s' "$tmp"; return 0
  fi
  return 1
}

# Record the current state as the baseline WITHOUT uploading. Treats whatever is
# on disk now (e.g. just restored from R2) as truth, so a degraded boot state
# never clobbers the good R2 snapshot.
snapshot_seed() {
  local tmp
  if tmp="$(_snapshot_generate)"; then
    BASELINE_SHA="$(sha256sum "$tmp" | cut -d' ' -f1)"
    log_snap "baseline seeded (no upload) — watching custom_nodes for changes"
  else
    BASELINE_SHA=""
    log_snap "baseline seed failed — first change will upload"
  fi
}

# Regenerate the snapshot; if it changed vs BASELINE_SHA, upload to R2 and
# advance the baseline + boot marker. Never fatal.
snapshot_reconcile() {
  local reason="${1:-change}" tmp sha
  if ! tmp="$(_snapshot_generate)"; then
    log_snap "save-snapshot failed ($reason) — will retry on next event"
    return 0
  fi
  sha="$(sha256sum "$tmp" | cut -d' ' -f1)"
  if [ "$sha" = "${BASELINE_SHA:-}" ]; then
    log_snap "no change ($reason)"
    return 0
  fi
  if rclone copyto "$tmp" "r2:$R2_BUCKET/snapshot.json" 2>/dev/null; then
    BASELINE_SHA="$sha"
    echo "$sha" > "$MARKER"
    log_snap "uploaded new snapshot to r2:$R2_BUCKET/snapshot.json ($reason)"
  else
    log_snap "upload failed ($reason) — will retry on next event"
  fi
}

# Seed the baseline, then watch custom_nodes and reconcile on each debounced
# burst of file events. Runs until the pod stops.
snapshot_watch() {
  snapshot_seed
  inotifywait -m -r -q \
    -e create -e delete -e modify -e moved_to -e moved_from \
    --exclude '(/\.git/|__pycache__|\.part)' \
    "$COMFY_DIR/custom_nodes" |
  while read -r _; do
    # Debounce: drain further events until SNAPSHOT_DEBOUNCE seconds of quiet.
    while read -r -t "${SNAPSHOT_DEBOUNCE:-30}" _; do :; done
    snapshot_reconcile "custom_nodes change"
  done
}

# When sourced by the test harness, stop here: define lib, skip the boot flow.
if [ -n "${ENTRYPOINT_LIB_ONLY:-}" ]; then
  return 0
fi
```

Note: `COMFY_DIR` and `export COMFYUI_PATH="$COMFY_DIR"` are already set above line 24, so `CM_CLI`/`MARKER` resolve correctly.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/snapshot_watch_test.sh`
Expected: prints `ok:` lines and ends with `ALL PASS` (exit 0).

- [ ] **Step 5: Shellcheck the entrypoint**

Run: `shellcheck entrypoint.sh` (skip if `shellcheck` is not installed).
Expected: no new errors introduced by the added functions. `SC1090` in the test file is already suppressed inline.

- [ ] **Step 6: Commit**

```bash
git add entrypoint.sh tests/snapshot_watch_test.sh
git commit -m "feat: add R2 snapshot watcher functions + unit test

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BrDmZQ4tg7JMD84U5vdqQS"
```

---

### Task 2: Wire boot-restore-from-R2 + watcher into the entrypoint boot flow

Change step 2 to restore the snapshot from R2 instead of `/opt/uploads`, and add a new step 6 that backgrounds `snapshot_watch` when R2 is enabled.

**Files:**
- Modify: `entrypoint.sh` (step 2 block; new step 6 before the `/start.sh` handoff)
- Test: `tests/snapshot_watch_test.sh` (must still pass), plus `bash -n`

**Interfaces:**
- Consumes: `snapshot_watch`, `CM_CLI`, `MARKER`, `R2`, `R2_BUCKET` from Task 1 / existing entrypoint.
- Produces: no new symbols — modifies the boot sequence only.

- [ ] **Step 1: Replace the step-2 snapshot restore block**

In `entrypoint.sh`, replace the entire current step-2 block (from the comment `# 2) Restore the Manager snapshot ...` through its closing `fi`, currently lines 55–77) with:

```bash
# 2) Restore the Manager snapshot from R2 (idempotent — skip if unchanged on
#    this disk). R2 is the source of truth; the watcher (step 6) keeps it fresh.
#    First-ever run (or no R2) has no snapshot: come up on the base image nodes.
SNAP=/tmp/snapshot.json
if [ "$R2" = 1 ] && rclone copyto "r2:$R2_BUCKET/snapshot.json" "$SNAP" 2>/dev/null && [ -s "$SNAP" ]; then
  sum="$(sha256sum "$SNAP" | cut -d' ' -f1)"
  if [ "$(cat "$MARKER" 2>/dev/null || true)" != "$sum" ]; then
    log "restoring ComfyUI-Manager snapshot from R2..."
    if python3.12 "$CM_CLI" restore-snapshot "$SNAP"; then
      # restore-snapshot re-clones the nodes but does NOT install their pip deps
      # (e.g. Impact Pack -> scikit-image, WAS -> numba). restore-dependencies
      # runs each installed node's requirements.txt (resolved via cu130 index).
      log "installing node dependencies (restore-dependencies)..."
      python3.12 "$CM_CLI" restore-dependencies \
        || log "WARNING: some node deps failed to install — check the logs."
      echo "$sum" > "$MARKER"; log "snapshot restored."
    else
      log "WARNING: snapshot restore had errors — continuing so SSH/Jupyter come up."
    fi
  else
    log "snapshot unchanged — skipping restore."
  fi
else
  log "no snapshot in R2 (or R2 disabled) — starting with base image nodes."
fi
```

This removes the old `SNAP="$UPLOADS/snapshot.json"` and inline `MARKER=` (now set in Task 1). `UPLOADS` stays defined at the top because step 4 still uses `MANIFEST="$UPLOADS/models.txt"`.

- [ ] **Step 2: Add step 6 (watcher) before the handoff**

In `entrypoint.sh`, immediately before the final `log "handing off to /start.sh"` line, insert:

```bash
# 6) Auto-snapshot: watch custom_nodes and push a fresh Manager snapshot to R2
#    whenever nodes are installed / updated / removed (debounced). Keeps
#    r2:$R2_BUCKET/snapshot.json current so the next cold start restores exactly
#    this node set. Starts AFTER the boot restore above so it never reacts to the
#    restore's own re-cloning or captures a half-installed state.
if [ "$R2" = 1 ]; then
  log "starting custom_nodes snapshot watcher -> r2:$R2_BUCKET/snapshot.json (on change)..."
  snapshot_watch &
fi

```

- [ ] **Step 3: Syntax-check and re-run the unit test**

Run: `bash -n entrypoint.sh && bash tests/snapshot_watch_test.sh`
Expected: `bash -n` prints nothing (valid syntax); the test ends with `ALL PASS`.

- [ ] **Step 4: Confirm no stale upload path remains**

Run: `grep -n "opt/uploads/snapshot" entrypoint.sh || echo "clean"`
Expected: `clean` (the entrypoint no longer references the uploaded snapshot).

- [ ] **Step 5: Commit**

```bash
git add entrypoint.sh
git commit -m "feat: restore snapshot from R2 at boot + start snapshot watcher

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BrDmZQ4tg7JMD84U5vdqQS"
```

---

### Task 3: Dockerfile — drop the bake, add inotify-tools

Remove the build-time snapshot bake and install `inotify-tools` for the watcher.

**Files:**
- Modify: `Dockerfile`

**Interfaces:**
- Consumes: nothing.
- Produces: image with `inotify-tools` present and no reference to `pod/snapshot.json`.

- [ ] **Step 1: Add `inotify-tools` to the apt install**

Replace (currently lines 27–29):

```dockerfile
# rclone — the entrypoint uses it for the R2 model cache + output persistence
RUN apt-get update && apt-get install -y --no-install-recommends rclone \
 && rm -rf /var/lib/apt/lists/*
```

with:

```dockerfile
# rclone — R2 model cache + output/snapshot persistence.
# inotify-tools — the entrypoint's custom_nodes snapshot watcher (inotifywait).
RUN apt-get update && apt-get install -y --no-install-recommends rclone inotify-tools \
 && rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 2: Remove the bake block**

Delete the entire bake block (currently lines 31–45), i.e. from the comment `# --- Bake the snapshot ...` through the closing `# ----...----` line, including the `COPY pod/snapshot.json ...` and its `RUN ...` command. After this edit the `ENTRYPOINT` line follows directly after the apt `RUN`.

- [ ] **Step 3: Rewrite the header comment**

Replace the "HYBRID model" comment block (currently lines 7–14):

```dockerfile
# HYBRID model:
#   - Bake the snapshot below so cold starts skip clone/install for the stable set.
#   - `files:` still ships the CURRENT pod/snapshot.json every `make up`; the
#     entrypoint's restore-snapshot then applies only the DELTA since the bake.
#   - When the delta grows enough to slow boots, `make image-build` to re-bake.
#
# The bake also writes the snapshot's checksum as the entrypoint's idempotency
# marker, so an unchanged snapshot skips restore-snapshot entirely at boot.
```

with:

```dockerfile
# Snapshot ownership lives in R2, not the image:
#   - The entrypoint restores the ComfyUI-Manager snapshot from
#     r2://$R2_BUCKET/snapshot.json at boot (delta over the base image nodes).
#   - A background inotify watcher re-uploads a fresh snapshot to R2 whenever
#     custom_nodes changes, so R2 stays current with no repo edit or rebuild.
#   - This image only needs a rebuild when entrypoint.sh (or deps below) change.
```

- [ ] **Step 4: Verify no snapshot bake references remain**

Run: `grep -n "snapshot" Dockerfile || echo "clean"`
Expected: `clean`.

Run: `grep -n "inotify-tools" Dockerfile`
Expected: one match in the apt `RUN`.

- [ ] **Step 5: Commit**

```bash
git add Dockerfile
git commit -m "build: drop snapshot bake, add inotify-tools for the watcher

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BrDmZQ4tg7JMD84U5vdqQS"
```

---

### Task 4: Remove the snapshot from the pod payload

Stop shipping `pod/snapshot.json` and delete the committed file.

**Files:**
- Modify: `comfyui.dstack.yml`
- Modify: `.dockerignore`
- Delete: `pod/snapshot.json`

**Interfaces:**
- Consumes: nothing.
- Produces: a repo where nothing ships `snapshot.json` to the pod.

- [ ] **Step 1: Drop the `files:` upload in `comfyui.dstack.yml`**

Replace (currently lines 22–29):

```yaml
# Sync the small declarative bits to the pod on every `apply`. They stage at
# /opt/uploads; the image entrypoint lays them into ComfyUI at boot. Updating
# nodes (snapshot.json) or the model list (models.txt) needs NO rebuild. The
# user dir (workflows + config) is NOT shipped here — it lives in R2 and is
# restored/persisted by the entrypoint.
files:
  - ./pod/snapshot.json:/opt/uploads/snapshot.json
  - ./pod/models.txt:/opt/uploads/models.txt
```

with:

```yaml
# Sync the small declarative bits to the pod on every `apply`. They stage at
# /opt/uploads; the image entrypoint lays them into ComfyUI at boot. Updating
# the model list (models.txt) needs NO rebuild. The snapshot is NOT shipped
# here — it lives in R2 (restored at boot, auto-updated on custom_nodes change),
# as does the user dir (workflows + config).
files:
  - ./pod/models.txt:/opt/uploads/models.txt
```

- [ ] **Step 2: Drop the snapshot allow-line in `.dockerignore`**

Replace the full contents of `.dockerignore`:

```
# Keep the image build context tiny — only entrypoint.sh is needed (plus
# pod/snapshot.json if you enable build-time baking in the Dockerfile).
*
!entrypoint.sh
!pod/snapshot.json
```

with:

```
# Keep the image build context tiny — only entrypoint.sh is needed by the build.
*
!entrypoint.sh
```

- [ ] **Step 3: Delete the committed snapshot**

Run: `git rm pod/snapshot.json`
Expected: `rm 'pod/snapshot.json'`.

- [ ] **Step 4: Verify nothing ships the snapshot**

Run: `grep -rn "snapshot.json" comfyui.dstack.yml .dockerignore || echo "clean"`
Expected: `clean`.

- [ ] **Step 5: Commit**

```bash
git add comfyui.dstack.yml .dockerignore
git commit -m "chore: stop shipping pod/snapshot.json (R2 is source of truth)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BrDmZQ4tg7JMD84U5vdqQS"
```

---

### Task 5: Update docs — Makefile + README

Retire the manual snapshot workflow and describe the R2 auto-snapshot behavior.

**Files:**
- Modify: `Makefile`
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: docs consistent with the new flow.

- [ ] **Step 1: Remove `snapshot-help` from the Makefile `.PHONY` list**

Replace (currently lines 37–38):

```makefile
.PHONY: help image-build server fleet up down logs attach ps status snapshot-help \
        r2-bucket secrets-help
```

with:

```makefile
.PHONY: help image-build server fleet up down logs attach ps status \
        r2-bucket secrets-help
```

- [ ] **Step 2: Delete the `snapshot-help` target and its now-unused vars**

Delete the entire `snapshot-help` target (currently lines 84–91, from `snapshot-help: ## ...` through the last `@echo` line). Then delete the two now-unused variable definitions (currently lines 30–31):

```makefile
COMFY_DIR    := /workspace/runpod-slim/ComfyUI
CM_CLI       := $(COMFY_DIR)/custom_nodes/ComfyUI-Manager/cm-cli.py
```

- [ ] **Step 3: Fix the Makefile header + `up` help text**

Replace (currently lines 7 and 11–13):

```makefile
#   make up              # provision the pod (uploads snapshot + model list) + attach
```

with:

```makefile
#   make up              # provision the pod (uploads model list) + attach
```

and replace:

```makefile
# Day-to-day: edit pod/snapshot.json or pod/models.txt, then `make up`. No image
# rebuild needed for those — only when entrypoint.sh changes. Workflows + config
# live in the user dir, which persists to R2 automatically (no repo edit needed).
```

with:

```makefile
# Day-to-day: edit pod/models.txt, then `make up`. No image rebuild needed for
# that — only when entrypoint.sh changes. Custom nodes are snapshotted to R2
# automatically on change; workflows + config persist to R2 too (no repo edit).
```

Then replace the `up` target help (currently line 53):

```makefile
up: ## Provision the pod + attach (uploads snapshot + model list via files:)
```

with:

```makefile
up: ## Provision the pod + attach (uploads model list via files:)
```

- [ ] **Step 4: Verify the Makefile**

Run: `grep -n "snapshot" Makefile || echo "clean"`
Expected: `clean`.

Run: `make help`
Expected: prints the target list without a `snapshot-help` entry and without error.

- [ ] **Step 5: Rewrite the README snapshot sections**

In `README.md`, replace the `pod/` payload bullet (currently lines 16–17):

```markdown
  - `pod/snapshot.json` — a **ComfyUI-Manager snapshot**: your custom nodes, pinned
    to commits, with their pip deps. Restored at boot (`cm-cli restore-snapshot`).
```

with:

```markdown
  - The **custom-node snapshot** is *not* in `pod/` — it lives in R2. It is
    restored at boot (`cm-cli restore-snapshot`) and re-uploaded automatically
    whenever `custom_nodes` changes (see Persistence below).
```

Replace the entrypoint summary (currently lines 21–23):

```markdown
- **`entrypoint.sh`** at boot: populate ComfyUI → restore the snapshot (idempotent,
  skipped if unchanged) → restore the user dir from R2 → hand off to the image's
  `/start.sh` (venv, ComfyUI, SSH, JupyterLab, FileBrowser).
```

with:

```markdown
- **`entrypoint.sh`** at boot: populate ComfyUI → restore the snapshot from R2
  (idempotent, skipped if unchanged) → restore the user dir from R2 → hand off to
  the image's `/start.sh` (venv, ComfyUI, SSH, JupyterLab, FileBrowser) → watch
  `custom_nodes` and re-upload the snapshot to R2 on change.
```

Replace the entire "Hybrid bake + overlay" paragraph (currently lines 25–31):

```markdown
**Hybrid bake + overlay (default):** the image **bakes** the snapshot at build
time (fast cold starts — nodes pre-installed), while `files:` still ships the
*current* snapshot every `make up`. At boot, `restore-snapshot` applies only the
**delta** since the last bake — so you add/update nodes by editing
`pod/snapshot.json` and re-running `make up` (no rebuild), and `make image-build`
periodically to re-bake when the delta grows. An unchanged snapshot skips restore
entirely (the bake writes its checksum as the boot idempotency marker).
```

with:

```markdown
**R2-owned snapshot:** there is no committed snapshot and no build-time bake.
R2 is the source of truth. Install/update/remove custom nodes the normal way
(ComfyUI-Manager UI, or git in `custom_nodes/`) and a background `inotifywait`
watcher debounces the change, regenerates the snapshot, and uploads it to
`r2://comfyui/snapshot.json` — only when it actually changed. The next cold start
restores that snapshot as a **delta** over the base image nodes (an unchanged
snapshot skips restore via a checksum marker). First-ever boot (empty R2) comes
up on base nodes; install what you want and the watcher seeds R2.
```

- [ ] **Step 6: Fix the remaining README references**

Replace (currently line 44):

```markdown
Generate `pod/snapshot.json` from a working setup: `make snapshot-help`.
```

with:

```markdown
Custom nodes are snapshotted to R2 automatically — just install them on the pod
(ComfyUI-Manager) and the watcher keeps `r2://comfyui/snapshot.json` current.
```

Replace the "Boot cost" trade-off bullet (currently lines 48–51):

```markdown
- **Boot cost:** mostly handled by the hybrid bake — cold starts only install the
  *delta* between the baked snapshot and the current one. Keep it small by
  re-baking (`make image-build`) when you've accumulated node changes. (Building on
  an Apple-silicon Mac uses amd64 emulation, so the bake step is slower there.)
```

with:

```markdown
- **Boot cost:** a cold start clones + installs every node in the R2 snapshot
  (no bake). Node deps download fresh each boot; models are cached in R2 (below).
  If cold-start time becomes a problem, re-introducing a build-time bake of the
  stable node set is the lever to pull.
```

Add a snapshot bullet to the Persistence (R2) list — insert immediately after the "Models cache" sub-bullet (after current line 59), at the same indent:

```markdown
  - **Snapshot** (`r2://comfyui/snapshot.json`): the ComfyUI-Manager snapshot of
    your custom nodes. Restored at boot and re-uploaded automatically whenever
    `custom_nodes` changes (debounced ~30s; only on a real change). This is the
    only place the node set is persisted — there is no committed copy.
```

Replace the Files table `pod/` row (currently line 86):

```markdown
| `pod/` | snapshot + model list synced to the pod (user dir lives in R2) |
```

with:

```markdown
| `pod/` | model list synced to the pod (snapshot + user dir live in R2) |
```

- [ ] **Step 7: Verify the README**

Run: `grep -n "snapshot.json\|snapshot-help\|hybrid bake\|Hybrid bake" README.md`
Expected: matches only in the new R2/Persistence wording — no `pod/snapshot.json`, no `make snapshot-help`, no "Hybrid bake".

- [ ] **Step 8: Commit**

```bash
git add Makefile README.md
git commit -m "docs: describe R2 auto-snapshots, retire manual snapshot workflow

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BrDmZQ4tg7JMD84U5vdqQS"
```

---

## Self-Review

**Spec coverage:**
- Delete `pod/snapshot.json` → Task 4 Step 3. ✅
- Remove `files:` upload → Task 4 Step 1. ✅
- Dockerfile: drop bake + add inotify-tools + rewrite header → Task 3. ✅
- `.dockerignore` drop allow-line → Task 4 Step 2. ✅
- Makefile retire `snapshot-help` + fix guidance → Task 5 Steps 1–3. ✅
- README updates → Task 5 Steps 5–6. ✅
- Boot restore from R2 (idempotent) → Task 2 Step 1. ✅
- No-snapshot / no-R2 fallback → Task 2 Step 1 (`else` branch). ✅
- Watcher: inotify create/delete/modify/moved, excludes, debounce, generate+diff-guard, startup seed without upload, `[snapshot]` logs, marker update → Task 1 (functions + tests) + Task 2 Step 2 (wiring). ✅
- `SNAPSHOT_DEBOUNCE=30` default → Task 1 Step 3 (`${SNAPSHOT_DEBOUNCE:-30}`). ✅
- Error handling never fatal → functions `return 0`; watcher backgrounded. ✅
- Testing (shellcheck + watcher unit simulation) → Task 1 Steps 4–5. ✅

**Placeholder scan:** No TBD/TODO; every code step shows full content; test code is complete. ✅

**Type/name consistency:** `snapshot_seed`, `snapshot_reconcile`, `snapshot_watch`, `_snapshot_generate`, `log_snap`, `BASELINE_SHA`, `CM_CLI`, `MARKER`, `R2_BUCKET`, `SNAPSHOT_DEBOUNCE` are used identically across Task 1 (definitions/tests) and Task 2 (wiring). ✅

#!/usr/bin/env bash
# dstack / RunPod entrypoint wrapper.
#
# Runs BEFORE the base image's /start.sh so we can set the pod up on a fresh
# (volume-less) disk before ComfyUI launches:
#   1. CUDA-13 preflight (exit non-zero on an old-driver host so dstack retries)
#   2. populate ComfyUI from the baked copy if the disk is fresh
#   3. restore the deployment's custom_nodes and user from R2 (blocking), then
#      install node deps
#   4. restore the deployment's models from R2 in the background (ComfyUI comes
#      up first)
#   5. start a filesystem-watcher per dir that pushes it to R2: the deployment's
#      dirs are mirrored exactly, each watcher starting only after its restore
#      succeeds; input and output are never restored, only uploaded to this
#      pod's own data folder.
# then run /start.sh (venv, ComfyUI, SSH, JupyterLab, FileBrowser) and, when the
# pod is stopped, push every watched dir one last time.
#
# R2 persistence activates only when RCLONE_CONFIG_R2_* + R2_BUCKET +
# R2_ACCOUNT_ID + DEPLOYMENT are set (dstack secrets/env); otherwise the pod
# runs with no persistence.
set -uo pipefail

COMFY_DIR=/workspace/runpod-slim/ComfyUI
BAKED=/opt/comfyui-baked
export COMFYUI_PATH="$COMFY_DIR"
# The base image's torch pin. /start.sh exports it too, but node deps install
# before /start.sh runs — without it a node requirement can swap the CUDA-13
# torch for a stock build.
export PIP_CONSTRAINT=/opt/comfyui-runtime-constraints.txt
# One file per watched dir, holding its push args: exactly the dirs the shutdown
# flush may push to R2.
MIRROR_STATE=/tmp/r2-mirrors

log() { echo "[dstack-entry] $*"; }

# ---------------------------------------------------------------------------
# R2 library. The bucket holds two trees:
#   deployments/<DEPLOYMENT>/{custom_nodes,user,models} — restored at boot
#     (R2->pod), then mirrored back with `sync` (destructive: deletions and
#     renames propagate). A dir's watcher starts ONLY after its restore
#     succeeds, so a degraded pod can never wipe good data in R2.
#   data/<pod id>/{input,output} — never restored, uploaded with `copy`, so
#     nothing the pod does can delete from R2.
# ---------------------------------------------------------------------------

# Exclude sets. Kept in sync across two syntaxes: rclone globs and one POSIX
# extended-regex for inotifywait. NOTE: `.git` is intentionally NOT excluded.
GLOBAL_RCLONE_EXCLUDES=(
  --exclude '.venv/**' --exclude 'venv/**'
  --exclude '__pycache__/**' --exclude '*.pyc'
  --exclude '*.part*' --exclude '*.tmp'
  --exclude '*.log' --exclude 'comfyui.db*'
)
USER_RCLONE_EXCLUDES=("${GLOBAL_RCLONE_EXCLUDES[@]}" --exclude '__manager/cache/**')
GLOBAL_INOTIFY_EXCLUDE='(/\.venv/|/venv/|/__pycache__/|\.pyc$|\.part|\.tmp$|\.log$|comfyui\.db)'
USER_INOTIFY_EXCLUDE='(/\.venv/|/venv/|/__pycache__/|\.pyc$|\.part|\.tmp$|\.log$|comfyui\.db|/__manager/cache/)'

# Run `rclone copy|sync SRC DST ARGS...` guarded against a stalled transfer: if
# it moves less than RESTORE_STALL_MIN_BYTES in RESTORE_STALL_AFTER seconds
# (bytes transferred, polled via rclone's rc API), kill it and retry. Covers a
# single file's multi-thread chunk hitting a badly degraded connection while the
# rest of the transfer is fine — observed once taking 40+ minutes on a ~14GB
# file whose identically sized sibling, started at the same moment, finished in
# under 4. rclone has no "minimum speed" abort flag, and a true idle-connection
# --timeout doesn't fire here since the stalled chunk still trickles a few bytes
# rather than going fully silent — hence a progress floor, not "zero bytes".
# rclone is safe to kill and rerun: local destinations write to a temp file and
# atomically rename on success, and `sync` deletes only after every transfer
# succeeded, so a retry only redoes whatever didn't finish.
rclone_stall_guarded() {
  local verb="$1" src="$2" dst="$3"; shift 3
  local max_attempts="${RESTORE_MAX_ATTEMPTS:-3}" stall_after="${RESTORE_STALL_AFTER:-360}" \
        min_progress="${RESTORE_STALL_MIN_BYTES:-1048576}" \
        poll_every="${RESTORE_POLL_EVERY:-30}" retry_backoff="${RESTORE_RETRY_BACKOFF:-10}"
  local attempt port pid bytes mark stalled rc waited
  for attempt in $(seq 1 "$max_attempts"); do
    # Random port per attempt: avoids racing the OS over releasing the
    # previous attempt's port right after killing it.
    port=$((20000 + RANDOM % 20000))
    rclone "$verb" "$src" "$dst" --rc --rc-addr "127.0.0.1:$port" --rc-no-auth "$@" &
    pid=$!
    mark=-1 stalled=0
    while kill -0 "$pid" 2>/dev/null; do
      # Poll for exit every 1s (not a blind sleep poll_every) so a process
      # that finishes mid-interval is noticed promptly instead of up to
      # poll_every seconds late.
      waited=0
      while [ "$waited" -lt "$poll_every" ] && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
      done
      kill -0 "$pid" 2>/dev/null || break
      # core/stats is tab-indented JSON (`"bytes": 123`). Its keys are sorted,
      # so the first "bytes" is the top-level total, not a `transferring` entry.
      bytes="$(curl -s -m 5 -X POST "http://127.0.0.1:$port/core/stats" 2>/dev/null \
        | grep -oE '"bytes": *[0-9]+' | head -1 | grep -oE '[0-9]+$')"
      [ -z "$bytes" ] && continue
      if [ "$mark" -lt 0 ] || [ $((bytes - mark)) -ge "$min_progress" ]; then
        mark="$bytes" stalled=0
      else
        stalled=$((stalled + poll_every))
      fi
      if [ "$stalled" -ge "$stall_after" ]; then
        log "rclone $verb to $dst moved under $min_progress bytes in ${stall_after}s (attempt $attempt/$max_attempts) — killing and retrying"
        kill -TERM "$pid" 2>/dev/null
        for waited in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        kill -KILL "$pid" 2>/dev/null
        break
      fi
    done
    wait "$pid"
    rc=$?
    [ "$rc" -eq 0 ] && return 0
    log "rclone $verb to $dst exited $rc (attempt $attempt/$max_attempts)"
    [ "$attempt" -lt "$max_attempts" ] && sleep "$retry_backoff"
  done
  return 1
}

# Restore a directory from R2 with `rclone VERB`: `sync` makes the pod an exact
# copy, `copy` keeps files that exist only on the pod. An empty/absent R2 path
# is a valid FRESH state (return 0 so the watcher starts and seeds it). An lsf
# failure means R2 is unreachable/misconfigured (return 1 — do NOT let a watcher
# start). A partial transfer failure also returns non-zero. Distinguishing these
# is the safety hinge.
restore_dir() {
  local local_dir="$1" subpath="$2" verb="$3"; shift 3
  mkdir -p "$local_dir"
  # One lsf call: its exit code gates "unreachable" (fail closed -> return 1, no
  # copy) and its captured output gates "empty prefix" (fresh -> return 0, no
  # copy). Do NOT split into two calls — a transient failure on a second call
  # with empty output would be misread as "fresh" and wrongly start the watcher
  # against a degraded R2. `local listing` is declared separately so the
  # assignment's exit code (not `local`'s) drives the `if`.
  local listing
  if ! listing="$(rclone lsf "r2:$R2_BUCKET/$subpath" 2>/dev/null)"; then
    log "cannot list r2:$R2_BUCKET/$subpath (R2 unreachable?) — NOT starting its watcher"
    return 1
  fi
  if [ -z "$listing" ]; then
    log "r2:$R2_BUCKET/$subpath is empty — fresh; watcher will seed it"
    return 0
  fi
  log "restoring $subpath from R2 ($verb)..."
  # rclone's periodic --stats are logged at INFO by default, i.e. invisible at
  # our default NOTICE level — --stats-log-level NOTICE surfaces them without
  # also turning on -v's noisy per-file transfer lines.
  #
  # Tuned for many-small-file restores (quantized/sharded models). rclone's
  # defaults — 4 concurrent --transfers, and multi-thread streaming only above
  # the 256Mi cutoff — collapse to a few MiB/s on a pile of sub-cutoff files
  # (each is single-stream, only 4 at a time, latency-bound). More transfers +
  # checkers, a lower multi-thread cutoff, and --fast-list (one recursive
  # listing instead of per-directory round-trips) keep throughput up. Big
  # monolithic checkpoints still multi-thread and saturate the link as before.
  rclone_stall_guarded "$verb" "r2:$R2_BUCKET/$subpath" "$local_dir" \
    --transfers 16 --checkers 16 --multi-thread-cutoff 64Mi --fast-list \
    --stats=20s --stats-one-line --stats-log-level NOTICE "$@"
}

# Push a directory to R2 with `rclone VERB`: `sync` makes R2 an exact copy
# (deletions propagate), `copy` only adds and updates. --fast-list: one
# recursive listing instead of a ListObjects call per directory.
push() {
  local local_dir="$1" subpath="$2" verb="$3"; shift 3
  rclone "$verb" "$local_dir" "r2:$R2_BUCKET/$subpath" --fast-list \
    --stats=20s --stats-one-line --stats-log-level NOTICE "$@"
}

# One watcher session: push once up front — catching anything written before
# the watch was set up, e.g. a model downloaded while models was restoring —
# then once per debounced burst of events. Returns when inotifywait exits.
watch_once() {
  local local_dir="$1" subpath="$2" verb="$3" regex="$4"; shift 4
  { echo initial
    inotifywait -m -r -q \
      -e create -e delete -e modify -e moved_to -e moved_from \
      --exclude "$regex" \
      "$local_dir"
  } |
  while read -r _; do
    # Debounce: drain further events until DEBOUNCE seconds of quiet.
    while read -r -t "${DEBOUNCE:-15}" _; do :; done
    push "$local_dir" "$subpath" "$verb" "$@"
  done
}

# Push a dir until the pod stops. inotifywait can exit (e.g. when the host's
# inotify instance/watch limits run out); restart it instead of silently
# dropping the dir. Each restart pushes first, so at worst this degrades to a
# push every minute.
watch_sync() {
  while :; do
    watch_once "$@"
    log "WARNING: $2 watcher exited — restarting in 60s"
    sleep 60
  done
}

# Arm a dir: record its push args (local dir, R2 subpath, verb, inotify regex,
# rclone excludes) for the shutdown flush, then background its watcher. Split
# out so tests can override it.
start_watcher() {
  printf '%s\0' "$@" > "$MIRROR_STATE/${1##*/}"
  watch_sync "$@" &
}

# Restore a deployment dir, and ONLY on success start mirroring it back with
# `sync`. The gate that upholds the safety invariant.
restore_and_watch() {
  local local_dir="$1" subpath="$2" verb="$3" regex="$4"; shift 4
  if restore_dir "$local_dir" "$subpath" "$verb" "$@"; then
    start_watcher "$local_dir" "$subpath" sync "$regex" "$@"
    return 0
  fi
  return 1
}

# Final push of every armed dir (a deployment dir is armed only once its restore
# succeeded — the watchers' gate), in parallel so it fits dstack's stop grace
# period.
flush_mirrors() {
  local marker args pids=()
  for marker in "$MIRROR_STATE"/*; do
    [ -f "$marker" ] || continue
    mapfile -d '' -t args < "$marker"
    log "final ${args[2]} of ${args[1]} to R2..."
    push "${args[0]}" "${args[1]}" "${args[2]}" "${args[@]:4}" &
    pids+=("$!")
  done
  # Never a bare `wait`: it would also wait on the never-ending watchers.
  [ "${#pids[@]}" -eq 0 ] || wait "${pids[@]}"
}

# SIGTERM/SIGINT handler: forward the stop to /start.sh (it stops ComfyUI and
# exits; it can't react while parked in `sleep infinity` after a ComfyUI crash,
# hence the bounded wait), push the last changes to R2, exit.
stop_and_flush() {
  log "stop requested — stopping ComfyUI, then a final sync to R2"
  kill -TERM "$1" 2>/dev/null
  for _ in $(seq 1 30); do kill -0 "$1" 2>/dev/null || break; sleep 1; done
  flush_mirrors
  exit 0
}

# Run a command (the base image's /start.sh) as a child instead of exec'ing it,
# so the mirrors get a final sync when the pod stops: dstack sends SIGTERM and
# allows stop_duration (default 5m) before SIGKILL. Returns the child's status.
supervise() {
  local child=
  trap 'stop_and_flush "$child"' TERM INT
  "$@" &
  child=$!
  wait "$child"
  local rc=$?
  log "$1 exited $rc"
  flush_mirrors
  return "$rc"
}

# Install restored custom nodes' Python deps into the system site-packages (the
# venv /start.sh creates next inherits them via --system-site-packages).
# restore-dependencies covers each node's requirements.txt AND its install.py.
install_node_deps() {
  local cm_cli="$COMFY_DIR/custom_nodes/ComfyUI-Manager/cm-cli.py"
  if [ ! -f "$cm_cli" ]; then
    log "WARNING: no ComfyUI-Manager in custom_nodes — node deps NOT installed"
    return
  fi
  log "installing node dependencies (cm-cli restore-dependencies)..."
  # -u: unbuffered stdout/stderr. Without it, cm-cli's pip-install chatter
  # sits in Python's block-buffered pipe and only appears (if at all) as one
  # dump at process exit, since stdout isn't a tty here.
  python3.12 -u "$cm_cli" restore-dependencies \
    || log "WARNING: some node deps failed to install — check the logs."
}

# Restore + mirror the deployment's dirs, and arm this pod's data uploads.
#
# Deployment (deployments/$DEPLOYMENT/), each watcher gated on its restore:
# custom_nodes and user block — ComfyUI reads them at startup — and restore
# with `sync`: the pod becomes an exact copy instead of R2 + the baked tree (a
# baked node pack you uninstalled would otherwise come back and be
# re-mirrored). models — the bulk of the bytes — streams in the background
# while ComfyUI comes up, with `copy`, so a model downloaded mid-restore
# survives.
#
# Data (data/$POD_ID/): input and output start empty and are only uploaded,
# with `copy`, so R2 keeps everything the pod produced even after it's deleted
# on the pod. Skipping the restore is safe because every pod writes its own
# folder: ComfyUI numbers new files from what's on disk, so two pods sharing a
# folder would overwrite each other's ComfyUI_00001_.png.
start_r2_persistence() {
  rm -rf "$MIRROR_STATE"; mkdir -p "$MIRROR_STATE"
  local deployment="deployments/$DEPLOYMENT" dir

  for dir in input output; do
    mkdir -p "$COMFY_DIR/$dir"
    start_watcher "$COMFY_DIR/$dir" "data/$POD_ID/$dir" copy "$GLOBAL_INOTIFY_EXCLUDE" "${GLOBAL_RCLONE_EXCLUDES[@]}"
  done

  if restore_dir "$COMFY_DIR/custom_nodes" "$deployment/custom_nodes" sync "${GLOBAL_RCLONE_EXCLUDES[@]}"; then
    install_node_deps
    start_watcher "$COMFY_DIR/custom_nodes" "$deployment/custom_nodes" sync "$GLOBAL_INOTIFY_EXCLUDE" "${GLOBAL_RCLONE_EXCLUDES[@]}"
  else
    log "custom_nodes restore failed — skipping node dep install + watcher (protecting R2)"
  fi

  restore_and_watch "$COMFY_DIR/user" "$deployment/user" sync "$USER_INOTIFY_EXCLUDE" "${USER_RCLONE_EXCLUDES[@]}" \
    || log "user restore failed — skipping its watcher (protecting R2)"

  { restore_and_watch "$COMFY_DIR/models" "$deployment/models" copy "$GLOBAL_INOTIFY_EXCLUDE" "${GLOBAL_RCLONE_EXCLUDES[@]}" \
      || log "models restore failed — skipping its watcher (protecting R2)"
  } &
}

# When sourced by the test harness, stop here: define lib, skip the boot flow.
if [ -n "${ENTRYPOINT_LIB_ONLY:-}" ]; then
  return 0
fi

# Preflight: this is a CUDA 13 image. If we landed on a host whose driver is too
# old to run it, bail immediately (exit non-zero) so dstack retries on another
# host — it can't filter hosts by driver version, only GPU type. Doing this first
# avoids wasting time populating ComfyUI and downloading ~100GB on a dead pod.
#
# This forces a real CUDA allocation with the image's CUDA-13 torch — the same
# op that would otherwise crash ComfyUI. On an old-driver host it raises
# "driver is too old" and python exits non-zero; on a good host it's a no-op.
# Its error stays in the log, so a broken image isn't mistaken for a bad host.
if ! python3.12 -c "import torch; torch.zeros(1, device='cuda')"; then
  log "CUDA 13 unusable on this host (error above) — exiting 1 so dstack retries another host."
  exit 1
fi
log "CUDA 13 preflight OK."

R2=0
if [ -n "${RCLONE_CONFIG_R2_ACCESS_KEY_ID:-}" ] && [ -n "${R2_BUCKET:-}" ] && [ -n "${R2_ACCOUNT_ID:-}" ] \
   && [ -n "${DEPLOYMENT:-}" ]; then
  export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  # RunPod sets RUNPOD_POD_ID and the dstack runner passes the container's env
  # through to the job; the hostname is only a fallback off RunPod.
  POD_ID="${RUNPOD_POD_ID:-$HOSTNAME}"
  R2=1
  log "R2 persistence enabled: r2:$R2_BUCKET/deployments/$DEPLOYMENT (restore + mirror), r2:$R2_BUCKET/data/$POD_ID (uploads)"
else
  log "R2 or DEPLOYMENT not configured — no persistence (nothing restored or mirrored)"
fi

# 1) Fresh disk: populate ComfyUI ourselves so we can modify it before launch.
if [ ! -d "$COMFY_DIR" ]; then
  log "populating ComfyUI from baked image..."
  mkdir -p "$(dirname "$COMFY_DIR")"
  cp -r "$BAKED" "$COMFY_DIR"
fi

# Restore the deployment from R2 and start the watchers. custom_nodes and user
# finish before ComfyUI launches; models streams in the background; input and
# output only upload. Skipped entirely when R2 or DEPLOYMENT isn't configured.
if [ "$R2" = 1 ]; then
  start_r2_persistence
fi

# Pin ComfyUI to a loopback bind. /start.sh hardcodes `--listen 0.0.0.0`, then
# appends whatever this args file holds — and argparse takes the LAST --listen,
# so the file is the supported way to override it without touching the base image.
#
# Why: ComfyUI-Manager (v3.38+) gates every install whose source isn't in the
# default channel — git URLs, nightly versions, unregistered packs — behind
# `flag AND is_loopback(args.listen)` (glob/manager_server.py:88-97, called at
# :1415 and :1477). The loopback term is NOT configurable: under `--listen
# 0.0.0.0` those installs return 404 regardless of security_level or
# allow_git_url_install, and the UI reports 'With the current security level
# configuration, only custom nodes from the "default channel" can be installed'.
# Loopback also flips Manager's is_local_mode, which is the posture Manager
# assumes for a pod reached through a tunnel instead of an exposed port.
#
# Access is unchanged: dstack forwards with `ssh -L localhost:8188:localhost:8188`,
# so the tunnel's far end connects to 127.0.0.1 inside the pod. The RunPod HTTP
# proxy (https://<pod>-8188.proxy.runpod.net) does NOT reach a loopback bind —
# use `make up` / `make attach` and http://localhost:8188.
COMFY_ARGS_FILE=/workspace/runpod-slim/comfyui_args.txt
mkdir -p "$(dirname "$COMFY_ARGS_FILE")"
if ! grep -qx -- '--listen 127.0.0.1' "$COMFY_ARGS_FILE" 2>/dev/null; then
  printf '%s\n' '--listen 127.0.0.1' >> "$COMFY_ARGS_FILE"
  log "pinned ComfyUI to 127.0.0.1 via $COMFY_ARGS_FILE (Manager's non-default-channel install gate)"
fi

log "starting /start.sh"
supervise /start.sh

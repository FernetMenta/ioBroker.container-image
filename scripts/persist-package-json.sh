#!/usr/bin/env bash
# persist-package-json.sh - keep /opt/iobroker/package.json and its sibling
# /opt/iobroker/package-lock.json alive across a container RECREATE by capturing
# them verbatim into the persistent node_modules volume and restoring them on
# start.
#
# THE PROBLEM
# -----------
# node_modules is a persistent VOLUME; package.json is NOT — it lives in the
# image/container layer. js-controller and adapters (e.g. the javascript adapter
# installing script modules) rewrite package.json's dependency list at runtime
# to match the installed adapter set.
#
#   * `docker restart` reuses the same writable layer, so the current
#     package.json survives and stays in sync with the node_modules volume ->
#     no issue.
#   * `docker compose up` / recreate starts a FRESH layer, resetting package.json
#     to the image baseline (only iobroker.js-controller) while the node_modules
#     volume still holds every adapter. They are now OUT OF SYNC, and the next
#     `npm install` (reconcile OR a runtime adapter install) treats every adapter
#     as EXTRANEOUS and PRUNES it, collapsing node_modules and forcing a full
#     reinstall. This is why the breakage appears only after a RECREATE, never
#     after a restart.
#
# THE APPROACH: CAPTURE VERBATIM, DON'T REBUILD
# ---------------------------------------------
# The authoritative package.json is the one js-controller/adapters write; its
# dependency specs are heterogeneous (github:, npm: aliases, ranges, pinned
# versions, vendor renames, non-`iobroker.*` names) and cannot be reliably
# reconstructed by inspecting node_modules — an earlier "rebuild from disk"
# attempt wrongly promoted all ~800 hoisted transitive packages to direct
# dependencies. So we do NOT rebuild: we keep a byte-for-byte SNAPSHOT of the
# real file inside the persistent node_modules volume as a dotfile
# (`.iob-package.json`, never mistaken for a package) and:
#
#   restore : on start, BEFORE any npm/reconcile runs, copy the snapshot over
#             /opt/iobroker/package.json so it matches the node_modules the
#             volume actually carries -> no npm invocation prunes the adapters.
#             On first start (no snapshot yet) SEED the snapshot from the current
#             package.json instead.
#   watch   : run in the background for the container's lifetime; poll
#             package.json and copy it to the snapshot whenever it CHANGES (mtime
#             + size differ). This captures every runtime edit — an adapter
#             installed via admin, a javascript-adapter module install, a
#             js-controller rewrite — immediately, so the snapshot always
#             reflects the latest real manifest for the next recreate. It only
#             writes when the file actually changed.
#
# package-lock.json is handled IDENTICALLY and as the COHERENT PAIR of
# package.json: it lives next to package.json in the same reset layer, and it is
# npm's record of the resolved tree. If only package.json is restored, npm finds
# no matching lockfile, judges the tree out of date, and re-resolves/reinstalls
# everything on recreate — even though the node_modules volume is correct (a
# restart proves it). Restoring both keeps npm on its `up to date` fast path.
#
# A dotfile + COPY (not a symlink) is deliberate: npm/js-controller write these
# files atomically (write temp + rename), which would silently replace a symlink
# with a regular file. Because the writes are atomic, the watcher only ever
# copies a complete file, never a half-written one.
#
# All operations are BEST-EFFORT: failures are logged and do not block startup
# (worst case is the pre-fix behavior, which reconcile's completeness check and
# the node_modules self-heal still recover).
#
# Usage:  persist-package-json.sh restore
#         persist-package-json.sh watch      # long-running; run in background
#
# Environment:
#   IOB_ROOT               ioBroker install root (default /opt/iobroker)
#   IOB_NODE_MODULES_DIR   node_modules dir     (default $IOB_ROOT/node_modules)
#   IOB_PKG_JSON           package.json path    (default $IOB_ROOT/package.json)
#   IOB_PKG_JSON_SNAPSHOT  snapshot path        (default $IOB_NODE_MODULES_DIR/.iob-package.json)
#   IOB_PKG_LOCK           package-lock.json    (default $IOB_ROOT/package-lock.json)
#   IOB_PKG_LOCK_SNAPSHOT  lock snapshot path   (default $IOB_NODE_MODULES_DIR/.iob-package-lock.json)
#   IOB_PKG_WATCH_INTERVAL watch poll seconds   (default 10)
set -u

IOB_ROOT="${IOB_ROOT:-/opt/iobroker}"
IOB_NODE_MODULES_DIR="${IOB_NODE_MODULES_DIR:-${IOB_ROOT}/node_modules}"
IOB_PKG_JSON="${IOB_PKG_JSON:-${IOB_ROOT}/package.json}"
IOB_PKG_JSON_SNAPSHOT="${IOB_PKG_JSON_SNAPSHOT:-${IOB_NODE_MODULES_DIR}/.iob-package.json}"
# package-lock.json sits next to package.json in $IOB_ROOT and is reset on the
# same recreate, so it is snapshotted/restored identically. Both must be put
# back as a coherent pair or npm judges the tree out of date and reinstalls it.
IOB_PKG_LOCK="${IOB_PKG_LOCK:-${IOB_ROOT}/package-lock.json}"
IOB_PKG_LOCK_SNAPSHOT="${IOB_PKG_LOCK_SNAPSHOT:-${IOB_NODE_MODULES_DIR}/.iob-package-lock.json}"
IOB_PKG_WATCH_INTERVAL="${IOB_PKG_WATCH_INTERVAL:-10}"

log() { printf 'persist-package-json: %s\n' "$*"; }

# files_differ: return 0 (true) when the two files differ in CONTENT, 1 when
# they are byte-identical. Missing live file -> treat as "no change" (nothing to
# capture). Used by the watcher so it copies ONLY on a real content change, not
# on a mere mtime bump (js-controller's atomic rewrites can touch mtime without
# changing bytes). package.json is small, so cmp is negligible.
files_differ() {
  local live="$1" snap="$2"
  [[ -f "${live}" ]] || return 1
  cmp -s -- "${live}" "${snap}" && return 1
  return 0
}

do_restore() {
  [[ -d "${IOB_NODE_MODULES_DIR}" ]] || { log "node_modules dir ${IOB_NODE_MODULES_DIR} absent; nothing to restore"; return 0; }
  if [[ -f "${IOB_PKG_JSON_SNAPSHOT}" ]]; then
    if cp -f -- "${IOB_PKG_JSON_SNAPSHOT}" "${IOB_PKG_JSON}" 2>/dev/null; then
      log "restored package.json from snapshot ${IOB_PKG_JSON_SNAPSHOT} (keeps node_modules in sync across recreate; prevents npm prune)"
    else
      log "WARNING could not restore package.json from ${IOB_PKG_JSON_SNAPSHOT}; an install-time npm prune may occur (reconcile/self-heal will recover)"
    fi
  elif [[ -f "${IOB_PKG_JSON}" ]]; then
    if cp -f -- "${IOB_PKG_JSON}" "${IOB_PKG_JSON_SNAPSHOT}" 2>/dev/null; then
      log "seeded snapshot ${IOB_PKG_JSON_SNAPSHOT} from current package.json (first start; will survive future recreates)"
    else
      log "WARNING could not seed snapshot ${IOB_PKG_JSON_SNAPSHOT} (continuing)"
    fi
  else
    log "no package.json at ${IOB_PKG_JSON} and no snapshot; nothing to do"
  fi

  # package-lock.json: identical restore-or-seed, as the coherent pair of
  # package.json. Restored AFTER package.json (and touched) so its mtime is not
  # older than package.json's — npm treats a lockfile older than package.json as
  # stale and re-resolves the whole tree, which is exactly what we prevent.
  if [[ -f "${IOB_PKG_LOCK_SNAPSHOT}" ]]; then
    if cp -f -- "${IOB_PKG_LOCK_SNAPSHOT}" "${IOB_PKG_LOCK}" 2>/dev/null; then
      touch -- "${IOB_PKG_LOCK}" 2>/dev/null || true
      log "restored package-lock.json from snapshot ${IOB_PKG_LOCK_SNAPSHOT} (paired with package.json so npm sees an up-to-date tree; skips the full reinstall)"
    else
      log "WARNING could not restore package-lock.json from ${IOB_PKG_LOCK_SNAPSHOT}; npm may re-resolve and reinstall on this start (self-heal will recover, but slowly)"
    fi
  elif [[ -f "${IOB_PKG_LOCK}" ]]; then
    if cp -f -- "${IOB_PKG_LOCK}" "${IOB_PKG_LOCK_SNAPSHOT}" 2>/dev/null; then
      log "seeded snapshot ${IOB_PKG_LOCK_SNAPSHOT} from current package-lock.json (first start; will survive future recreates)"
    else
      log "WARNING could not seed snapshot ${IOB_PKG_LOCK_SNAPSHOT} (continuing)"
    fi
  else
    log "no package-lock.json at ${IOB_PKG_LOCK} and no snapshot; nothing to do"
  fi
  return 0
}

# do_watch: poll package.json and copy it to the snapshot whenever it changes.
# Long-running; intended to be started in the background by the entrypoint just
# before it execs js-controller. Copies ONLY on an actual change (mtime/size
# signature differs from the last captured one). Exits cleanly on SIGTERM/SIGINT
# so container stop is not delayed.
do_watch() {
  local interval="${IOB_PKG_WATCH_INTERVAL}"
  [[ "${interval}" =~ ^[0-9]+$ ]] && [[ "${interval}" -gt 0 ]] || interval=10

  # Terminate promptly when the container stops.
  local running=1
  trap 'running=0' TERM INT

  log "watching ${IOB_PKG_JSON} + ${IOB_PKG_LOCK} for changes (every ${interval}s); snapshots -> ${IOB_PKG_JSON_SNAPSHOT}, ${IOB_PKG_LOCK_SNAPSHOT}"

  while [[ "${running}" -eq 1 ]]; do
    # Copy ONLY when a file differs in content from its snapshot, so an atomic
    # rewrite that does not change the bytes produces no spurious copy. Each of
    # package.json / package-lock.json is captured independently on its own
    # change (an install rewrites both; a dedupe may touch only the lockfile).
    if files_differ "${IOB_PKG_JSON}" "${IOB_PKG_JSON_SNAPSHOT}"; then
      if cp -f -- "${IOB_PKG_JSON}" "${IOB_PKG_JSON_SNAPSHOT}" 2>/dev/null; then
        log "package.json changed; updated snapshot ${IOB_PKG_JSON_SNAPSHOT}"
      else
        log "WARNING package.json changed but snapshot update failed (will retry)"
      fi
    fi
    if files_differ "${IOB_PKG_LOCK}" "${IOB_PKG_LOCK_SNAPSHOT}"; then
      if cp -f -- "${IOB_PKG_LOCK}" "${IOB_PKG_LOCK_SNAPSHOT}" 2>/dev/null; then
        log "package-lock.json changed; updated snapshot ${IOB_PKG_LOCK_SNAPSHOT}"
      else
        log "WARNING package-lock.json changed but snapshot update failed (will retry)"
      fi
    fi
    # Sleep in the background and wait, so a TERM interrupts the wait promptly.
    sleep "${interval}" &
    wait $! 2>/dev/null || true
  done
  log "watcher stopping"
  return 0
}

case "${1:-}" in
  restore) do_restore ;;
  watch) do_watch ;;
  *)
    printf 'usage: %s restore|watch\n' "${0##*/}" >&2
    exit 2
    ;;
esac
exit 0

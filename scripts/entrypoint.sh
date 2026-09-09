#!/usr/bin/env bash
# entrypoint.sh - PID-1-wrapped ioBroker startup pipeline (design §4).
#
# This is the thin shell glue for the entrypoint component. It orchestrates the
# ordered startup sequence and defers every decision to the pure `lib/` modules
# (resolveDefaults/DEFAULT_TABLE, validateDbPort/validateDbType/validateRole,
# planDbConfig, planReconciliation, ensureNpmrc) which it invokes through
# `node --input-type=module`, mirroring the pattern established by
# `scripts/ensure-npmrc.sh`. The script itself owns only the side effects the
# modules cannot: reading the process environment, touching the filesystem
# (timezone, group-writable dirs), and `exec`-ing js-controller.
#
# Ordered sequence (design §4 flow diagram):
#   1. Capture initial env snapshot (defaults resolved from THIS snapshot only,
#      later mutations ignored).                                     (Req 10.4)
#   2. Resolve defaults via lib/defaults (resolveDefaults, DEFAULT_TABLE).
#   3. Validate redis port (1-65535) and multihost role
#      (master|slave) via lib/validate; on failure emit an error naming the
#      value and exit non-zero WITHOUT starting js-controller.  (Req 4.7, 12.9)
#   4. Apply TZ / LANG and configure the timezone when TZ is valid. (Req 10.5)
#   5. Resolve runtime UID/GID; when the UID is absent from /etc/passwd, join
#      GID 0 and ensure the writable dirs are group-writable (arbitrary-UID
#      path only).                                                (Req 4.1-4.6)
#   6. Ensure .npmrc via scripts/ensure-npmrc.sh (block if corrupt).  (Req 11.4)
#   7. Run reconciliation via scripts/reconcile.sh: init default config on an
#      empty Data_Volume (creates the objects/states DB + iobroker.json),
#      bootstrap admin, install recorded adapters.                    (Req 8)
#   8. Configure objects/states DB backends + multihost role via
#      scripts/configure-db.sh (idempotent; patches only operator-specified
#      fields). Runs AFTER reconciliation so iobroker.json exists.    (Req 12)
#   9. exec js-controller under tini.
#
# It NEVER sources a user startup script and ignores any mounted startup script
# (Req 13.1, 13.2, 13.3): there is simply no hook-sourcing step in this pipeline.
set -euo pipefail

# --- Locate ourselves and the sibling lib/ modules --------------------------
# Resolve this script's directory so we can find lib/ regardless of the working
# directory tini/Docker launches us from (same approach as ensure-npmrc.sh).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
LIB_DIR="${REPO_ROOT}/lib"

# ioBroker install location (design §8 / Data Models). The js-controller entry
# point and the writable volumes live under here. Overridable for tests.
IOBROKER_DIR="${IOBROKER_DIR:-/opt/iobroker}"
JS_CONTROLLER="${IOBROKER_DIR}/node_modules/iobroker.js-controller/controller.js"

# Writable directories that must remain accessible under an arbitrary UID.
# Data_Volume (iobroker-data) and Log_Volume (log) plus the install root itself
# so npm/adapter installs can write there (Req 4.5, 4.6).
WRITABLE_DIRS=(
  "${IOBROKER_DIR}"
  "${IOBROKER_DIR}/iobroker-data"
  "${IOBROKER_DIR}/log"
  "${IOBROKER_DIR}/node_modules"
)

log() { echo "entrypoint: $*" >&2; }
die() {
  echo "entrypoint: $*" >&2
  exit 1
}

# Run a small ES-module snippet against the pure lib/ modules. Extra args are
# passed through to node so callers can hand values in via `process.argv`.
run_node() {
  local snippet="$1"
  shift
  node --input-type=module -e "${snippet}" "$@"
}

# ---------------------------------------------------------------------------
# 1. Capture initial env snapshot.
#
# We snapshot the process environment as JSON right now. Default resolution and
# every validation below reads ONLY from this snapshot, so any variable set by
# a later phase of startup cannot change a resolved default (Req 10.4). `env0`
# holds the raw snapshot; `defaults` holds the resolved effective values.
# ---------------------------------------------------------------------------
log "capturing initial environment snapshot"
ENV_SNAPSHOT="$(run_node "process.stdout.write(JSON.stringify(process.env));")"

# ---------------------------------------------------------------------------
# 2. Resolve defaults from the snapshot via lib/defaults.
#
# resolveDefaults returns every defaulted variable resolved to its snapshot
# value (when set) or its encoded default (when unset). We read the individual
# resolved values back into shell variables for the steps that follow.
# ---------------------------------------------------------------------------
log "resolving defaults from initial snapshot"
read_defaults() {
  IOB_DEFAULTS_JSON="${ENV_SNAPSHOT}" run_node "
    import { resolveDefaults } from '${LIB_DIR}/defaults.js';
    const snapshot = JSON.parse(process.env.IOB_DEFAULTS_JSON ?? '{}');
    const resolved = resolveDefaults(snapshot);
    // Emit shell-eval'able assignments; values are our own controlled defaults
    // or operator-supplied strings, quoted to survive spaces.
    const keys = ['TZ','LANG'];
    for (const k of keys) {
      const v = resolved[k] ?? '';
      process.stdout.write('RESOLVED_' + k + '=' + JSON.stringify(String(v)) + '\n');
    }
  "
}
# shellcheck disable=SC2046 # each line is a single KEY="value" assignment
eval "$(read_defaults)"

# ---------------------------------------------------------------------------
# 3. (Configuration validation for the objects/states database backends and the
#    multihost role happens inside the database configurator in step 8, which
#    rejects an invalid type/port/role and exits non-zero before js-controller
#    starts. There is no separate validation step here anymore.) (Req 12.9)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 4. Apply TZ / LANG and configure the timezone.
#
# Export the resolved values so js-controller and any child processes inherit
# them. When TZ names a zoneinfo file we know about, point /etc/localtime at it
# (best-effort: an arbitrary UID may not be able to write /etc, which is fine —
# exporting TZ already governs libc's time handling). (Req 10.5)
# ---------------------------------------------------------------------------
export TZ="${RESOLVED_TZ}"
export LANG="${RESOLVED_LANG}"
log "applied TZ=${TZ} LANG=${LANG}"

if [[ -n "${TZ}" && -f "/usr/share/zoneinfo/${TZ}" ]]; then
  if ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime 2>/dev/null; then
    printf '%s\n' "${TZ}" >/etc/timezone 2>/dev/null || true
    log "configured container timezone to ${TZ}"
  else
    log "could not update /etc/localtime (non-writable); TZ export still applies"
  fi
elif [[ -n "${TZ}" ]]; then
  log "TZ=${TZ} has no matching zoneinfo entry; leaving system timezone unchanged"
fi

# ---------------------------------------------------------------------------
# 5. Resolve runtime UID/GID; arbitrary-UID handling.
#
# Determine the UID we are actually running as. When that UID has no entry in
# /etc/passwd (the OpenShift-style arbitrary-UID case) we must (a) ensure the
# process participates in GID 0 and (b) make the writable dirs group-writable
# so GID 0 has read/write access to the Data_Volume and Log_Volume. When the
# UID IS present in /etc/passwd we do NOT touch group membership or
# permissions (Req 4.6). (Req 4.1-4.6)
# ---------------------------------------------------------------------------
RUNTIME_UID="$(id -u)"
RUNTIME_GID="$(id -g)"
log "running as uid=${RUNTIME_UID} gid=${RUNTIME_GID}"

if getent passwd "${RUNTIME_UID}" >/dev/null 2>&1; then
  log "uid ${RUNTIME_UID} is present in /etc/passwd; no arbitrary-UID adjustments needed"
else
  log "uid ${RUNTIME_UID} is absent from /etc/passwd; applying arbitrary-UID handling"

  # Try to register the arbitrary UID against GID 0 in /etc/passwd via nss_wrapper
  # if available, but the authoritative requirement is GID 0 group membership +
  # group-writable dirs. When /etc/passwd is writable we add a minimal entry so
  # tools that look up the user by UID resolve it; failures are non-fatal.
  if [[ -w /etc/passwd ]]; then
    if ! getent passwd "${RUNTIME_UID}" >/dev/null 2>&1; then
      printf 'iobroker:x:%s:0:iobroker arbitrary uid:%s:/sbin/nologin\n' \
        "${RUNTIME_UID}" "${IOBROKER_DIR}" >>/etc/passwd 2>/dev/null || \
        log "could not append arbitrary-UID entry to /etc/passwd (continuing)"
    fi
  else
    log "/etc/passwd is not writable; relying on GID 0 membership for access"
  fi

  # Ensure the writable dirs are owned by / writable via GID 0 so the process
  # (which is a member of GID 0 in this case) can read and write them.
  for dir in "${WRITABLE_DIRS[@]}"; do
    [[ -d "${dir}" ]] || continue
    if chgrp -R 0 "${dir}" 2>/dev/null && chmod -R g+rwX "${dir}" 2>/dev/null; then
      log "ensured GID 0 group-writable access on ${dir}"
    else
      log "could not adjust group ownership/permissions on ${dir} (continuing)"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 6. Ensure .npmrc (block if corrupt/inaccessible).
#
# Delegate to the dedicated glue, which calls lib/npmrc. A non-zero exit means
# the settings file is corrupt or inaccessible and the adapter install must be
# blocked, so we refuse to continue (Req 11.4 / 11.5).
# ---------------------------------------------------------------------------
log "ensuring .npmrc npm settings"
if ! "${SCRIPT_DIR}/ensure-npmrc.sh"; then
  die "npm settings could not be ensured; refusing to start js-controller"
fi

# ---------------------------------------------------------------------------
# 7. Run reconciliation via scripts/reconcile.sh.
#
# reconcile.sh is the thin glue that OBSERVES the environment (empty Data_Volume,
# node_modules mount state, registry reachability, ABI mismatch, recorded vs.
# installed adapter sets), asks lib/reconcile-plan.js (planReconciliation) for
# the ordered actions, and EXECUTES them (iobroker setup first, iobroker add,
# npm rebuild, ...). It mirrors how steps 6/7 delegate to ensure-npmrc.sh /
# ensure-npmrc.sh. On an empty Data_Volume it initializes the default config
# and bootstraps the admin adapter so a fresh container comes up with a setup UI.
#
# Reconciliation never fails startup when persisted modules are usable offline
# or when an ABI rebuild cannot be done (Req 8.11, 8.13); it exits non-zero only
# if a required install/rebuild command genuinely fails. We surface that as a
# hard error so we do not exec a half-provisioned runtime.
# ---------------------------------------------------------------------------
log "running reconciliation"
if ! IOB_ROOT="${IOBROKER_DIR}" \
  IOB_DATA_DIR="${IOBROKER_DIR}/iobroker-data" \
  IOB_NODE_MODULES_DIR="${IOBROKER_DIR}/node_modules" \
  "${SCRIPT_DIR}/reconcile.sh"; then
  die "reconciliation failed; refusing to start js-controller"
fi

# ---------------------------------------------------------------------------
# 8. Configure objects/states database backends + multihost role via
#    scripts/configure-db.sh (idempotent).
#
# ioBroker keeps objects and states in two SEPARATE databases, each with its own
# type (jsonl | file | redis) / host / port. Multihost does NOT require Redis: a
# common setup is networked `jsonl` (a slave points its objects/states host at
# the master). configure-db.sh reads the operator's IOB_OBJECTSDB_* /
# IOB_STATESDB_* / IOB_MULTIHOST variables and the current iobroker.json, asks
# lib/db-plan.js for the plan, and patches ONLY the operator-specified fields
# when changed (idempotent; Req 12.7/12.8). When the operator specified nothing,
# it is a no-op and the local `jsonl` config from `iobroker setup first` is left
# untouched (Req 12.3) — this is why patching-only-what-was-asked matters. It
# validates type/port/role and exits non-zero naming an invalid value (Req 12.9).
#
# Runs AFTER reconciliation so iobroker.json created by `iobroker setup first`
# exists to read/patch. The operator's IOB_* DB variables are passed through
# from the entrypoint environment (they are opt-in and NOT defaulted).
# ---------------------------------------------------------------------------
log "configuring database backends / multihost"
if ! IOB_ROOT="${IOBROKER_DIR}" \
  IOB_MULTIHOST="${IOB_MULTIHOST:-}" \
  IOB_OBJECTSDB_TYPE="${IOB_OBJECTSDB_TYPE:-}" \
  IOB_OBJECTSDB_HOST="${IOB_OBJECTSDB_HOST:-}" \
  IOB_OBJECTSDB_PORT="${IOB_OBJECTSDB_PORT:-}" \
  IOB_OBJECTSDB_NAME="${IOB_OBJECTSDB_NAME:-}" \
  IOB_OBJECTSDB_PASS="${IOB_OBJECTSDB_PASS:-}" \
  IOB_STATESDB_TYPE="${IOB_STATESDB_TYPE:-}" \
  IOB_STATESDB_HOST="${IOB_STATESDB_HOST:-}" \
  IOB_STATESDB_PORT="${IOB_STATESDB_PORT:-}" \
  IOB_STATESDB_NAME="${IOB_STATESDB_NAME:-}" \
  IOB_STATESDB_PASS="${IOB_STATESDB_PASS:-}" \
  "${SCRIPT_DIR}/configure-db.sh"; then
  die "database/multihost configuration failed; refusing to start js-controller"
fi

# ---------------------------------------------------------------------------
# 9. exec js-controller under tini.
#
# We hand the current process image over to js-controller so tini (PID 1)
# supervises it directly for signal forwarding and exit-code propagation. No
# user startup script is ever sourced, and any mounted one is ignored — there
# is no hook step here by design (Req 13.1, 13.2, 13.3).
# ---------------------------------------------------------------------------
if [[ ! -f "${JS_CONTROLLER}" ]]; then
  die "js-controller not found at ${JS_CONTROLLER}"
fi

log "starting js-controller"
exec node "${JS_CONTROLLER}" "$@"

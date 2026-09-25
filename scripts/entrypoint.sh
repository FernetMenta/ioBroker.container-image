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
#   7. Reconcile INIT phase via scripts/reconcile.sh (IOB_RECONCILE_PHASE=init):
#      on an empty Data_Volume, initialize the default config + local DB so
#      iobroker.json exists for the next step to patch.                (Req 8.6)
#   7b. Restore an ioBroker backup on request via scripts/restore-backup.sh:
#      when a `restore/` folder with a single backup file exists in the
#      Data_Volume, run `iobroker restore` here (js-controller is stopped, so
#      this is the only safe point), log to log/restore.log, delete the folder
#      on success, and refuse to start on any error. Runs after init (so the
#      CLI has a config/DB to operate on, making a fresh-container restore work)
#      and before DB config so the restored config drives the steps below.
#   8. Configure objects/states DB backends + multihost role via
#      scripts/configure-db.sh (idempotent; patches only operator-specified
#      fields). Runs AFTER init so iobroker.json exists, and BEFORE the install
#      phase so the desired-adapter query reads the master's shared DB when a
#      multihost slave/backend is configured.                          (Req 12)
#   9. Reconcile INSTALL phase via scripts/reconcile.sh
#      (IOB_RECONCILE_PHASE=install): query the (now correctly targeted) DB for
#      this host's adapters, install their code, and rebuild native modules on
#      an ABI mismatch.                                                (Req 8)
#  10. exec js-controller under tini.
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

# --- Human-readable staged startup logging ----------------------------------
# The pipeline logs each stage as a boxed banner (plus per-line detail via
# `log`) so an operator reading `docker logs` can see how far startup got and
# where it stopped if something goes wrong. This is diagnostic output only; the
# banners carry no logic. Width matches the classic reference image (80 cols).
BANNER_WIDTH=80

# rule: a full-width line of a single repeated character (default '-').
rule() {
  local ch="${1:--}"
  printf '%*s\n' "${BANNER_WIDTH}" '' | tr ' ' "${ch}"
}

# banner_line: center TEXT inside a "-----   ...   -----" framed line so the
# blocks line up regardless of message length.
banner_line() {
  local text="$1"
  local inner=$((BANNER_WIDTH - 12)) # space between the two "----- " frames
  local pad_total=$((inner - ${#text}))
  ((pad_total < 0)) && pad_total=0
  local left=$((pad_total / 2))
  local right=$((pad_total - left))
  printf -- '----- %*s%s%*s -----\n' "${left}" '' "${text}" "${right}" '' >&2
}

# stage: emit a boxed banner announcing a startup stage, e.g.
#   stage "Step 3 of 6: Reconciling adapters"
stage() {
  {
    rule
    banner_line "$1"
    rule
  } >&2
}

# kv_line: a right-framed "key: value" info line used by the summary block,
# padded so the trailing "-----" frame lands on the banner's right edge.
kv_line() {
  local key="$1" val="$2"
  # Interior between the two 5-dash frames, minus the 5-space left indent.
  local inner=$((BANNER_WIDTH - 10 - 5))
  local body
  body="$(printf '%-24s%s' "${key}" "${val}")"
  # Truncate an over-long body so the frame stays aligned.
  ((${#body} > inner)) && body="${body:0:inner}"
  printf -- '-----     %-*s -----\n' "${inner}" "${body}" >&2
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

# --- Welcome banner + system / version / environment summary ----------------
# Printed once at the very top so `docker logs` opens with a clear, greppable
# snapshot of the container's identity and the ioBroker-relevant environment.
# Purely informational; nothing below depends on it.
{
  rule
  banner_line "$(date '+%Y-%m-%d %H:%M:%S')"
  rule
  banner_line ""
  banner_line "Welcome to your rootless ioBroker container!"
  banner_line "Startup is now running - please be patient."
  banner_line ""
  rule
  banner_line "System Information"
  kv_line "image tag:" "$(cat "${IOBROKER_DIR}/.image-tag" 2>/dev/null || echo unknown)"
  kv_line "arch:" "$(uname -m 2>/dev/null || echo unknown)"
  kv_line "hostname:" "$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)"
  kv_line "node:" "$(node --version 2>/dev/null || echo unknown)"
  kv_line "npm:" "$(npm --version 2>/dev/null || echo unknown)"
  banner_line ""
  banner_line "ioBroker Environment"
  # Only surface the ioBroker-relevant variables (unset ones show as empty).
  for _v in IOB_MULTIHOST \
    IOB_OBJECTSDB_TYPE IOB_OBJECTSDB_HOST IOB_OBJECTSDB_PORT \
    IOB_STATESDB_TYPE IOB_STATESDB_HOST IOB_STATESDB_PORT \
    IOB_ADMIN_PORT IOB_WEB_PORT TZ LANG; do
    kv_line "${_v}:" "${!_v:-}"
  done
  rule
} >&2

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
stage "Step 1 of 6: Ensuring npm settings"
log "ensuring .npmrc npm settings"
if ! "${SCRIPT_DIR}/ensure-npmrc.sh"; then
  die "npm settings could not be ensured; refusing to start js-controller"
fi

# Shared environment for both reconcile passes (init and install) and the
# package.json persistence helper (which reads IOB_ROOT / IOB_NODE_MODULES_DIR).
# Defined here so the restore call below can use it.
RECONCILE_ENV=(
  "IOB_ROOT=${IOBROKER_DIR}"
  "IOB_DATA_DIR=${IOBROKER_DIR}/iobroker-data"
  "IOB_NODE_MODULES_DIR=${IOBROKER_DIR}/node_modules"
)

# ---------------------------------------------------------------------------
# Persist /opt/iobroker/package.json across container RECREATE.
#
# node_modules is a persistent VOLUME but package.json is NOT — it lives in the
# image/container layer. js-controller and adapters (e.g. the javascript adapter
# installing script modules) grow package.json's dependency list at runtime to
# match the installed adapter set. A `docker restart` reuses the same writable
# layer, so that grown package.json survives and stays in sync with the
# node_modules volume. A `docker compose up`/recreate starts a FRESH layer,
# resetting package.json to the image baseline (only iobroker.js-controller)
# while the node_modules volume still holds every adapter — out of sync, so the
# next `npm install` (reconcile OR a runtime adapter install) prunes every
# adapter as extraneous and forces a full reinstall. This is why the breakage
# appears only after a recreate, never after a restart.
#
# `restore` copies an authoritative package.json AND package-lock.json kept
# inside the persistent node_modules volume back over the (possibly image-reset)
# files BEFORE any npm/reconcile runs, re-syncing them with the volume so nothing
# prunes and npm sees an up-to-date tree (restoring package.json alone leaves npm
# without a matching lockfile, so it re-resolves and reinstalls the whole tree).
# It runs here, before the reconcile passes and the DB config. A background
# `watch` process (started before exec) keeps both snapshots current as the files
# change at runtime. See scripts/persist-package-json.sh.
# ---------------------------------------------------------------------------
if ! env "${RECONCILE_ENV[@]}" "${SCRIPT_DIR}/persist-package-json.sh" restore; then
  log "package.json restore reported a problem (continuing; reconcile will recover any prune)"
fi

# ---------------------------------------------------------------------------
# Self-heal the node_modules dependency tree.
#
# Adapters depend on shared libraries npm HOISTS to the top of node_modules
# (express, @iobroker/adapter-core, http-mitm-proxy, ...). If that tree was ever
# left incomplete (e.g. an earlier npm prune removed hoisted packages and the
# piecemeal reinstall did not restore them), adapters crash at runtime with
# `Cannot find module '<dep>'` even though their own directory is present.
# Restoring package.json above prevents FUTURE prunes but cannot rebuild an
# ALREADY-incomplete tree, so we run one `npm install` against the now-complete
# package.json to materialize any missing dependency. It prunes nothing (the
# manifest is the full set) and is a fast no-op when the tree is already
# consistent. Runs here, in the pre-controller window (no concurrent writer),
# after the restore and before reconcile. Best-effort: never blocks startup.
# Disable with IOB_HEAL_NODE_MODULES=false. See scripts/heal-node-modules.sh.
# ---------------------------------------------------------------------------
log "verifying adapter dependencies (self-heal); this may take several minutes on the first run"
if ! env "${RECONCILE_ENV[@]}" \
  IOB_HEAL_NODE_MODULES="${IOB_HEAL_NODE_MODULES:-true}" \
  IOB_HEAL_TIMEOUT="${IOB_HEAL_TIMEOUT:-1800}" \
  "${SCRIPT_DIR}/heal-node-modules.sh"; then
  log "node_modules self-heal reported a problem (continuing)"
fi

# The controller config file (objects/states DB backend definition).
IOB_JSON="${IOB_JSON:-${IOBROKER_DIR}/iobroker-data/iobroker.json}"

# ---------------------------------------------------------------------------
# Install-phase DB isolation (keep a multihost slave OUT during startup).
#
# A multihost MASTER serves its objects/states jsonl DB on the network (e.g.
# `host: 0.0.0.0`, ports 9001/9000) so slaves on the LAN can connect. But adapter
# installs run BEFORE js-controller: each `iobroker` CLI call stands up its OWN
# transient jsonl server on those ports and file-locks objects.jsonl/states.jsonl
# for the duration of that call. If a running slave keeps connecting to the
# master's network address, it latches onto those transient servers and holds the
# port/lock open, so the NEXT install cannot acquire it — producing "Failed to
# lock DB file" errors that no retry can win, and the whole start hangs.
#
# The fix has TWO parts, both applied for the install phase ONLY and both
# reverted before we `exec` js-controller:
#
#   (a) bind the objects/states DB to loopback (`127.0.0.1`). The transient
#       servers then listen only inside the container, so a slave hitting the
#       master's LAN address is connection-refused and cannot interfere.
#
#   (b) disable multihostService.enabled. This is the part that actually stops
#       the scary error flood. `configure-db.sh` set enabled=true for a master;
#       while it is true, every pre-controller CLI whose transient objects
#       server overlaps the previous one hits js-controller's guard and throws
#       "Objects DB is not allowed to start in the current Multihost
#       environment" as an UNHANDLED rejection, tearing the connection down and
#       spewing `ECONNREFUSED 127.0.0.1:9001` until the attempt times out. With
#       enabled=false for the install phase, each transient server is a plain
#       standalone jsonl server: the guard never fires, servers tear down
#       cleanly, and the residual lock-race window shrinks dramatically. Our own
#       multihostService.role marker is left intact so nothing else loses track
#       of the configured role, and enabled=true is restored before exec so the
#       master serves its slaves normally once it is actually up.
#
# Ports are left unchanged; only the host is narrowed and the flag toggled.
#
# ROLE-DRIVEN, not host-guessing: isolation is applied IFF this container is a
# multihost MASTER (`multihostService.enabled === true` in iobroker.json — the
# authoritative, persisted role written by configure-db.sh). We do this
# unconditionally for a master, even if its host already reads `127.0.0.1`, so the
# slave lockout does not depend on the current host value happening to be
# non-loopback. For a SLAVE (its DB is the REMOTE master's address — rewriting it
# to loopback would break the slave's own install queries) and for a STANDALONE
# (no slave exists to lock out, no network exposure) isolation is a no-op.
#
# This is a pure file patch (same mechanism configure-db.sh uses) and is made
# crash-safe by a trap: if the install phase fails or the container is killed
# mid-install, the original hosts are restored so a master is never left stuck on
# loopback (which would silently cut off every slave after a bad start).
DB_HOST_BACKUP=""          # "<objectsHost>\t<statesHost>" captured before isolation
DB_HOSTS_ISOLATED=false    # whether we actually narrowed the hosts (needs restore)
DB_MULTIHOST_DISABLED=false # whether we temporarily disabled multihostService.enabled (needs restore)

# read_db_state: print "<objectsHost>\t<statesHost>\t<isMaster>" from iobroker.json
# (host fields empty when absent; isMaster is "true"/"false"). isMaster reflects
# ioBroker's own multihostService.enabled flag — the master is the host that runs
# the multihost service. Best-effort; prints nothing if the file is unreadable.
read_db_state() {
  [[ -r "${IOB_JSON}" ]] || return 0
  IOB_JSON_PATH="${IOB_JSON}" run_node "
    import { readFileSync } from 'node:fs';
    try {
      const c = JSON.parse(readFileSync(process.env.IOB_JSON_PATH, 'utf8'));
      const o = (c.objects && c.objects.host) ?? '';
      const s = (c.states && c.states.host) ?? '';
      const master = !!(c.multihostService && c.multihostService.enabled === true);
      process.stdout.write(String(o) + '\t' + String(s) + '\t' + (master ? 'true' : 'false'));
    } catch { /* no output */ }
  "
}

# set_multihost_enabled: set multihostService.enabled to the given boolean
# ("true"/"false") in iobroker.json, leaving multihostService.role (our own
# marker) and everything else untouched. Returns non-zero on failure. Used to
# temporarily quiesce the master's multihost guard for the install phase (see
# isolate_db_hosts_for_install) so the pre-controller CLI's transient jsonl
# servers are plain standalone servers rather than tripping js-controller's
# "Objects DB is not allowed to start in the current Multihost environment"
# guard (which throws an unhandled rejection and spews ECONNREFUSED until the
# attempt times out).
set_multihost_enabled() {
  local enabled="$1"
  IOB_JSON_PATH="${IOB_JSON}" IOB_MH_ENABLED="${enabled}" run_node "
    import { readFileSync, writeFileSync, renameSync } from 'node:fs';
    const path = process.env.IOB_JSON_PATH;
    const c = JSON.parse(readFileSync(path, 'utf8'));
    if (c.multihostService && typeof c.multihostService === 'object') {
      c.multihostService.enabled = process.env.IOB_MH_ENABLED === 'true';
    }
    const tmp = path + '.tmp';
    writeFileSync(tmp, JSON.stringify(c, null, 2) + '\n');
    renameSync(tmp, path);
  "
}

# set_db_hosts: patch objects.host and states.host in iobroker.json to the given
# values (arg1 = objects host, arg2 = states host). Only touches the two host
# fields; everything else in the file is preserved. Returns non-zero on failure.
set_db_hosts() {
  local obj_host="$1" states_host="$2"
  IOB_JSON_PATH="${IOB_JSON}" IOB_OBJ_HOST="${obj_host}" IOB_STATES_HOST="${states_host}" run_node "
    import { readFileSync, writeFileSync, renameSync } from 'node:fs';
    const path = process.env.IOB_JSON_PATH;
    const c = JSON.parse(readFileSync(path, 'utf8'));
    if (c.objects && typeof c.objects === 'object') c.objects.host = process.env.IOB_OBJ_HOST;
    if (c.states && typeof c.states === 'object') c.states.host = process.env.IOB_STATES_HOST;
    const tmp = path + '.tmp';
    writeFileSync(tmp, JSON.stringify(c, null, 2) + '\n');
    renameSync(tmp, path);
  "
}

# isolate_db_hosts_for_install: on a multihost MASTER, back up both DB hosts and
# rewrite them to 127.0.0.1 for the install phase (unconditionally — see the
# role-driven rationale above). No-op for slave/standalone. Idempotent restore is
# guaranteed by restore_db_hosts via the EXIT trap.
isolate_db_hosts_for_install() {
  local state obj_host states_host is_master
  state="$(read_db_state)"
  [[ -n "${state}" ]] || { log "install-phase DB isolation: cannot read ${IOB_JSON}; skipping"; return 0; }
  obj_host="${state%%$'\t'*}"
  local rest="${state#*$'\t'}"
  states_host="${rest%%$'\t'*}"
  is_master="${rest#*$'\t'}"

  # Only a master hosts a network DB that a slave can latch onto and only a master
  # carries the multihostService.enabled flag that trips the DB guard; slave and
  # standalone have nothing to isolate (and a slave's host points at the REMOTE
  # master, which must not be rewritten).
  if [[ "${is_master}" != "true" ]]; then
    log "install-phase DB isolation: not a multihost master (objects='${obj_host}' states='${states_host}'); no isolation needed"
    return 0
  fi

  # Part (b): disable the multihost service flag for the install phase. This is
  # done UNCONDITIONALLY for a master — including when the hosts are already
  # loopback — because js-controller's "Objects DB is not allowed to start in the
  # current Multihost environment" guard keys off multihostService.enabled, NOT
  # off the host, so it fires (and floods ECONNREFUSED) even on a loopback-bound
  # master. Only the `enabled` boolean is touched; our `role` marker is kept.
  if set_multihost_enabled "false"; then
    DB_MULTIHOST_DISABLED=true
    log "install-phase DB isolation: multihostService.enabled disabled for the install phase" \
      "(prevents the 'Objects DB is not allowed to start in the current Multihost environment' guard)"
  else
    log "install-phase DB isolation: WARNING could not disable multihostService.enabled in ${IOB_JSON};" \
      "the install phase may log the multihost DB guard error and retry"
  fi

  # Part (a): narrow the DB hosts to loopback. If they are already loopback a
  # slave cannot reach us regardless, so there is nothing to narrow and no host
  # restore is needed. (A master persisted on loopback cannot serve slaves after
  # startup, but that is a configuration choice, not ours to change.) Note this
  # short-circuits ONLY the host narrowing; the flag toggle above already ran.
  local already_loopback=true
  case "${obj_host}" in ''|127.0.0.1|localhost|::1) : ;; *) already_loopback=false ;; esac
  case "${states_host}" in ''|127.0.0.1|localhost|::1) : ;; *) already_loopback=false ;; esac
  if [[ "${already_loopback}" == "true" ]]; then
    log "install-phase DB isolation: master DB already loopback (objects='${obj_host}' states='${states_host}'); a slave cannot connect during startup"
    return 0
  fi

  DB_HOST_BACKUP="${obj_host}"$'\t'"${states_host}"
  if set_db_hosts "127.0.0.1" "127.0.0.1"; then
    DB_HOSTS_ISOLATED=true
    log "install-phase DB isolation: master DB bound to 127.0.0.1 for the install phase" \
      "(was objects='${obj_host}' states='${states_host}'); a slave cannot connect during startup"
  else
    # If we could not patch, leave the file as-is and continue. The install may
    # then hit the lock race, but we must not proceed believing we isolated when
    # we did not, so clear the backup marker.
    DB_HOST_BACKUP=""
    log "install-phase DB isolation: FAILED to patch ${IOB_JSON}; continuing without isolation"
  fi
}

# restore_db_hosts: undo BOTH parts of the install-phase isolation — put the
# original objects/states hosts back AND re-enable multihostService.enabled.
# Registered on EXIT (and called explicitly before exec) so the master's public
# binding and multihost role are always restored, even if the install phase
# fails or the container is killed mid-install. Idempotent: each part acts only
# when it was actually applied. (Name kept for continuity with the EXIT trap.)
restore_db_hosts() {
  if [[ "${DB_HOSTS_ISOLATED}" == "true" ]]; then
    local obj_host states_host
    obj_host="${DB_HOST_BACKUP%%$'\t'*}"
    states_host="${DB_HOST_BACKUP#*$'\t'}"
    if set_db_hosts "${obj_host}" "${states_host}"; then
      log "install-phase DB isolation: restored objects/states hosts (objects='${obj_host}' states='${states_host}')"
    else
      log "install-phase DB isolation: WARNING could not restore original DB hosts in ${IOB_JSON};" \
        "expected objects='${obj_host}' states='${states_host}' — check the file before slaves reconnect"
    fi
    DB_HOSTS_ISOLATED=false
  fi

  if [[ "${DB_MULTIHOST_DISABLED}" == "true" ]]; then
    if set_multihost_enabled "true"; then
      log "install-phase DB isolation: re-enabled multihostService.enabled (master serves slaves again)"
    else
      log "install-phase DB isolation: WARNING could not re-enable multihostService.enabled in ${IOB_JSON};" \
        "the master will not serve slaves until this is fixed — check the file"
    fi
    DB_MULTIHOST_DISABLED=false
  fi
}

# ---------------------------------------------------------------------------
# 7. Reconcile INIT phase via scripts/reconcile.sh (IOB_RECONCILE_PHASE=init).
#
# On an empty Data_Volume this runs `iobroker setup first`, creating the local
# objects/states DB and iobroker.json. It MUST precede DB configuration (step 8)
# so there is an iobroker.json for configure-db to patch. On a populated
# Data_Volume there is nothing to init and this pass is a no-op.
# ---------------------------------------------------------------------------
stage "Step 2 of 6: Initializing configuration"
log "running reconciliation (init phase)"
if ! env "${RECONCILE_ENV[@]}" IOB_RECONCILE_PHASE=init \
  "${SCRIPT_DIR}/reconcile.sh"; then
  die "configuration initialization failed; refusing to start js-controller"
fi

# ---------------------------------------------------------------------------
# 7b. Restore an ioBroker backup on request (BEFORE js-controller starts).
#
# `iobroker restore` requires js-controller to be STOPPED while it rewrites the
# objects/states DBs and iobroker.json. Here js-controller is PID 1's foreground
# process (exec'd as the very last step), so there is no running container in
# which an operator could stop-restore-start — stopping the controller would
# terminate the container. The only safe moment to restore is DURING startup,
# before the exec, which is here.
#
# An operator triggers a restore by dropping a SINGLE backup file into a
# `restore/` folder in the Data_Volume and (re)creating the container. On this
# start we detect the folder, run the restore, log the full CLI transcript to
# Log_Volume/restore.log, and — on success — delete the folder so the restore
# happens EXACTLY ONCE (a later restart must not re-apply it over live data). On
# ANY restore error we refuse to start (a half-restored DB is worse than a clear
# failure), leaving the folder in place for inspection.
#
# It runs AFTER the reconcile init phase (so iobroker.json + the local DB exist
# for the CLI to operate on, making a restore onto a FRESH container work) and
# BEFORE DB configuration + the install phase, so the restored config is what
# configure-db patches and what the desired-adapter query reads — the adapters
# the backup expects then get installed by the install phase below.
#
# RECONCILE_ENV does not carry the Log_Volume path, so pass IOB_LOG_DIR
# explicitly for restore.log.
stage "Step 3 of 6: Restoring backup (if requested)"
log "checking for a backup restore request"
if ! env "${RECONCILE_ENV[@]}" \
  "IOB_LOG_DIR=${IOBROKER_DIR}/log" \
  "${SCRIPT_DIR}/restore-backup.sh"; then
  die "backup restore failed; refusing to start js-controller"
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
# Runs AFTER the reconcile init phase so iobroker.json created by `iobroker
# setup first` exists to read/patch, and BEFORE the reconcile install phase so
# the desired-adapter query reads the correctly targeted DB. The operator's
# IOB_* DB variables are passed through from the entrypoint environment (they
# are opt-in and NOT defaulted).
# ---------------------------------------------------------------------------
stage "Step 4 of 6: Configuring database / multihost"
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
# 9. Reconcile INSTALL phase via scripts/reconcile.sh
#    (IOB_RECONCILE_PHASE=install).
#
# reconcile.sh OBSERVES the environment (registry reachability, ABI mismatch,
# desired vs. installed adapter sets) and EXECUTES the install actions
# (iobroker install, npm rebuild, ...). Because step 8 has already pointed the
# DB at the master when configured, the desired-adapter query here reads the
# correct objects DB. On an empty Data_Volume the desired set is just the
# bootstrapped `admin`, so a fresh container comes up with a setup UI.
#
# Reconciliation never fails startup when persisted modules are usable offline
# or when an ABI rebuild cannot be done (Req 8.11, 8.13); it exits non-zero only
# if a required install/rebuild command genuinely fails. We surface that as a
# hard error so we do not exec a half-provisioned runtime.
# ---------------------------------------------------------------------------
stage "Step 5 of 6: Reconciling adapters"
log "running reconciliation (install phase)"
# Keep any running multihost slave OUT during the install phase by binding the
# objects/states DB to loopback (see isolate_db_hosts_for_install above). Restore
# is guaranteed by the EXIT trap so a failed/killed install never leaves a master
# stuck on loopback; we also restore explicitly right after the phase.
trap 'restore_db_hosts' EXIT
isolate_db_hosts_for_install
if ! env "${RECONCILE_ENV[@]}" IOB_RECONCILE_PHASE=install \
  "${SCRIPT_DIR}/reconcile.sh"; then
  # restore_db_hosts runs via the EXIT trap before the process exits.
  die "reconciliation failed; refusing to start js-controller"
fi
# Success: restore the public DB binding now (before exec) and clear the trap so
# the normal exec path is unaffected.
restore_db_hosts
trap - EXIT

# A background watcher (started just before exec, below) keeps the package.json
# and package-lock.json snapshots on the node_modules volume current: it copies
# each to its snapshot whenever it changes at runtime (an adapter installed via
# admin, a javascript-adapter module install, a js-controller rewrite). There is
# deliberately no post-install "save" here: the reconcile install phase already
# updated both files, and the watcher captures those (and every later change)
# verbatim, so the snapshots always reflect the real manifest + lockfile for the
# next recreate.

# ---------------------------------------------------------------------------
# 10. exec js-controller under tini.
#
# We hand the current process image over to js-controller so tini (PID 1)
# supervises it directly for signal forwarding and exit-code propagation. No
# user startup script is ever sourced, and any mounted one is ignored — there
# is no hook step here by design (Req 13.1, 13.2, 13.3).
# ---------------------------------------------------------------------------
# Write the runtime start marker just before handing off to js-controller. The
# healthcheck anchors its startup grace window to this marker's mtime ("since
# THIS runtime started") and only falls back to PID 1's start time when the
# marker is absent. Writing it here — after reconciliation and DB configuration,
# immediately before exec — means the startup grace clock begins when the
# controller actually starts, not when the (possibly long) reconcile phase began;
# the reconcile phase has its own liveness signal. Best-effort: a non-writable
# Data_Volume must not block startup, it just leaves the healthcheck on its PID 1
# fallback. The reconcile markers are already cleared by reconcile.sh's EXIT trap.
IOB_START_MARKER="${IOB_START_MARKER:-${IOBROKER_DIR}/iobroker-data/.iob-started}"
if : >>"${IOB_START_MARKER}" 2>/dev/null && touch -- "${IOB_START_MARKER}" 2>/dev/null; then
  log "wrote runtime start marker ${IOB_START_MARKER}"
else
  log "could not write start marker ${IOB_START_MARKER} (healthcheck will fall back to PID 1 start time)"
fi

if [[ ! -f "${JS_CONTROLLER}" ]]; then
  die "js-controller not found at ${JS_CONTROLLER}. \
This usually means the ${IOBROKER_DIR}/node_modules mount is empty or shadows \
the image's node_modules: js-controller and its dependencies live there and are \
NOT rebuilt by reconciliation. Use a NAMED volume for node_modules (it is \
seeded from the image on first start) rather than an empty host bind mount, or \
omit the node_modules mount entirely. See docs/volumes-and-multihost.md."
fi

stage "Step 6 of 6: Starting ioBroker"

# Start the package.json snapshot watcher in the BACKGROUND for the container's
# lifetime. It copies /opt/iobroker/package.json to the snapshot on the
# persistent node_modules volume whenever it changes (only on an actual change),
# so adapters installed via admin at runtime — and any other manifest edit — are
# captured for the next recreate. `exec` below replaces this shell with
# js-controller, reparenting the watcher to tini (PID 1), which reaps it on
# exit. Best-effort: launched with a guard so a failure to start never blocks
# the controller. Disable by setting IOB_PKG_WATCH_INTERVAL=0.
if [[ "${IOB_PKG_WATCH_INTERVAL:-10}" != "0" ]]; then
  env "${RECONCILE_ENV[@]}" \
    IOB_PKG_WATCH_INTERVAL="${IOB_PKG_WATCH_INTERVAL:-10}" \
    "${SCRIPT_DIR}/persist-package-json.sh" watch &
  log "started package.json snapshot watcher (pid $!)"
else
  log "package.json snapshot watcher disabled (IOB_PKG_WATCH_INTERVAL=0)"
fi

log "starting js-controller"
exec node "${JS_CONTROLLER}" "$@"

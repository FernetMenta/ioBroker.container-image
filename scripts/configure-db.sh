#!/usr/bin/env bash
# configure-db.sh - thin shell glue for the database-backend configurator.
#
# ioBroker stores objects and states in two SEPARATE databases, each with its
# own type / host / port (and optional name / password). The type is `jsonl`
# (the network-capable default), `file`, or `redis`. Multihost does NOT require
# Redis: a common setup is a `jsonl` objects/states server on the master with
# slaves pointing their objects/states host at it.
#
# This script (observe -> plan -> act):
#   1. OBSERVE the operator-specified desired config from IOB_OBJECTSDB_* /
#      IOB_STATESDB_* / IOB_MULTIHOST (only variables the operator actually set),
#      and the CURRENT objects/states config read back from iobroker.json.
#   2. PLAN via `planDbConfig` in `lib/db-plan.js`.
#   3. ACT: when the plan is `changed`, patch ONLY the specified fields of the
#      objects/states sections of iobroker.json, and set the multihost role via
#      the `iobroker` CLI. When nothing is specified or nothing changed, do
#      NOTHING (leave the local `jsonl` config from `iobroker setup first`
#      untouched — patching it would break the working local DB).
#
# On an invalid type/port/role the pure module returns a rejection; this script
# exits non-zero naming the value so the entrypoint refuses to start (Req 12.9).
#
# Usage:
#   configure-db.sh
#
# Desired-config inputs (each optional; unset = do not touch that field):
#   IOB_MULTIHOST         master | slave        (unset = standalone)
#   IOB_OBJECTSDB_TYPE    jsonl | file | redis
#   IOB_OBJECTSDB_HOST    hostname/IP
#   IOB_OBJECTSDB_PORT    1..65535
#   IOB_OBJECTSDB_NAME    optional db name
#   IOB_OBJECTSDB_PASS    optional db password
#   IOB_STATESDB_TYPE / _HOST / _PORT / _NAME / _PASS   (same, for states)
#
# Environment overrides (testing / non-default layouts):
#   IOB_ROOT             ioBroker install root (default /opt/iobroker)
#   IOB_JSON             iobroker.json path (default $IOB_ROOT/iobroker-data/iobroker.json)
#   IOB_DB_DRY_RUN       when "true", log actions instead of patching / running CLI
#
# Exit codes:
#   0  no-op (nothing specified or nothing changed) or applied successfully
#   1  invalid value (Req 12.9), an apply step failed, or unexpected plan result
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
DB_MODULE="${REPO_ROOT}/lib/db-plan.js"

IOB_ROOT="${IOB_ROOT:-/opt/iobroker}"
IOB_JSON="${IOB_JSON:-${IOB_ROOT}/iobroker-data/iobroker.json}"
IOB_DB_DRY_RUN="${IOB_DB_DRY_RUN:-false}"

log() { echo "configure-db: $*" >&2; }

run() {
  if [[ "${IOB_DB_DRY_RUN}" == "true" ]]; then
    log "[dry-run] $*"
    return 0
  fi
  "$@"
}

# --- Short-circuit: nothing to do unless the operator specified DB vars/role ---
# If none of the IOB_OBJECTSDB_* / IOB_STATESDB_* / IOB_MULTIHOST variables are
# set, leave iobroker.json exactly as `iobroker setup first` wrote it (the local
# jsonl databases). This is the standalone default and MUST NOT be patched.
any_db_var_set=false
for v in \
  IOB_MULTIHOST \
  IOB_OBJECTSDB_TYPE IOB_OBJECTSDB_HOST IOB_OBJECTSDB_PORT IOB_OBJECTSDB_NAME IOB_OBJECTSDB_PASS \
  IOB_STATESDB_TYPE IOB_STATESDB_HOST IOB_STATESDB_PORT IOB_STATESDB_NAME IOB_STATESDB_PASS; do
  if [[ -n "${!v:-}" ]]; then any_db_var_set=true; break; fi
done

if [[ "${any_db_var_set}" != "true" ]]; then
  log "no database/multihost variables set; leaving local database configuration untouched"
  exit 0
fi

# --- OBSERVE current objects/states config from iobroker.json ----------------
read_current() {
  [[ -r "${IOB_JSON}" ]] || return 0
  IOB_JSON_PATH="${IOB_JSON}" node --input-type=module -e "
    import { readFileSync } from 'node:fs';
    let cfg;
    try { cfg = JSON.parse(readFileSync(process.env.IOB_JSON_PATH, 'utf8')); }
    catch { process.exit(0); }
    const o = cfg.objects ?? {};
    const s = cfg.states ?? {};
    // ioBroker expresses master via multihostService.enabled (the master runs
    // the multihost service; a slave/standalone does not). We ALSO write a
    // 'role' marker when we apply a role, so the idempotency diff can tell a
    // configured 'slave' (enabled=false, role='slave') apart from a plain
    // standalone (enabled=false, no role). Read the explicit marker first; fall
    // back to enabled=true => 'master' for configs written before the marker
    // existed. Absent/disabled with no marker reads as '' (standalone).
    let role = '';
    if (cfg.multihostService && typeof cfg.multihostService === 'object') {
      if (typeof cfg.multihostService.role === 'string' && cfg.multihostService.role !== '') {
        role = cfg.multihostService.role;
      } else if (cfg.multihostService.enabled === true) {
        role = 'master';
      }
    }
    const emit = (k, v) => process.stdout.write('CUR_' + k + '=' + JSON.stringify(String(v ?? '')) + '\n');
    emit('O_TYPE', o.type); emit('O_HOST', o.host); emit('O_PORT', o.port);
    emit('S_TYPE', s.type); emit('S_HOST', s.host); emit('S_PORT', s.port);
    emit('ROLE', role);
  "
}
CUR_O_TYPE=""; CUR_O_HOST=""; CUR_O_PORT=""
CUR_S_TYPE=""; CUR_S_HOST=""; CUR_S_PORT=""; CUR_ROLE=""
# shellcheck disable=SC2046
eval "$(read_current)"

log "desired: role='${IOB_MULTIHOST:-}' objects{type='${IOB_OBJECTSDB_TYPE:-}' host='${IOB_OBJECTSDB_HOST:-}' port='${IOB_OBJECTSDB_PORT:-}'}" \
  "states{type='${IOB_STATESDB_TYPE:-}' host='${IOB_STATESDB_HOST:-}' port='${IOB_STATESDB_PORT:-}'}"
log "current: role='${CUR_ROLE}' objects{type='${CUR_O_TYPE}' host='${CUR_O_HOST}' port='${CUR_O_PORT}'}" \
  "states{type='${CUR_S_TYPE}' host='${CUR_S_HOST}' port='${CUR_S_PORT}'}"

# --- PLAN via lib/db-plan.js -------------------------------------------------
# Emit one of:
#   reject\t<reason>\t<value>
#   noop
#   apply\t<json plan>
plan="$(
  CUR_O_TYPE="${CUR_O_TYPE}" CUR_O_HOST="${CUR_O_HOST}" CUR_O_PORT="${CUR_O_PORT}" \
  CUR_S_TYPE="${CUR_S_TYPE}" CUR_S_HOST="${CUR_S_HOST}" CUR_S_PORT="${CUR_S_PORT}" \
  CUR_ROLE="${CUR_ROLE}" \
  node --input-type=module -e "
    import { planDbConfig } from '${DB_MODULE}';
    const env = process.env;
    const sect = (p) => {
      const o = {};
      if (env[p+'_TYPE']) o.type = env[p+'_TYPE'];
      if (env[p+'_HOST']) o.host = env[p+'_HOST'];
      if (env[p+'_PORT']) o.port = env[p+'_PORT'];
      if (env[p+'_NAME']) o.name = env[p+'_NAME'];
      if (env[p+'_PASS']) o.pass = env[p+'_PASS'];
      return o;
    };
    const desired = {
      objects: sect('IOB_OBJECTSDB'),
      states: sect('IOB_STATESDB'),
      role: env.IOB_MULTIHOST || '',
    };
    const current = {
      objects: { type: env.CUR_O_TYPE, host: env.CUR_O_HOST, port: env.CUR_O_PORT },
      states:  { type: env.CUR_S_TYPE, host: env.CUR_S_HOST, port: env.CUR_S_PORT },
      role: env.CUR_ROLE || '',
    };
    const r = planDbConfig(desired, current);
    if (r.valid === false) {
      process.stdout.write('reject\t' + r.reason + '\t' + JSON.stringify(r.value) + '\n');
      process.exit(0);
    }
    if (!r.changed) { process.stdout.write('noop\n'); process.exit(0); }
    process.stdout.write('apply\t' + JSON.stringify({objects:r.objects,states:r.states,role:r.role,changes:r.changes}) + '\n');
  "
)"

action="${plan%%$'\t'*}"
case "${action}" in
  reject)
    rest="${plan#reject$'\t'}"; reason="${rest%%$'\t'*}"; value="${rest#*$'\t'}"
    log "invalid database/multihost configuration (${reason}): ${value}"
    exit 1
    ;;
  noop)
    log "database/multihost configuration unchanged; leaving it as-is (idempotent)"
    exit 0
    ;;
  apply)
    plan_json="${plan#apply$'\t'}"
    log "applying database/multihost configuration: ${plan_json}"
    if [[ "${IOB_DB_DRY_RUN}" == "true" ]]; then
      log "[dry-run] patch ${IOB_JSON} objects/states with: ${plan_json}"
    else
      # Patch ONLY the specified fields of objects/states in iobroker.json.
      if ! IOB_JSON_PATH="${IOB_JSON}" IOB_PLAN="${plan_json}" node --input-type=module -e "
        import { readFileSync, writeFileSync, renameSync } from 'node:fs';
        const path = process.env.IOB_JSON_PATH;
        const plan = JSON.parse(process.env.IOB_PLAN);
        let cfg = {};
        try { cfg = JSON.parse(readFileSync(path, 'utf8')); }
        catch (e) { process.stderr.write('cannot parse ' + path + ': ' + e.message + '\n'); process.exit(1); }
        const applySection = (name, sect) => {
          if (!sect || Object.keys(sect).length === 0) return;
          cfg[name] = cfg[name] ?? {};
          if (sect.type !== undefined) cfg[name].type = sect.type;
          if (sect.host !== undefined) cfg[name].host = sect.host;
          if (sect.port !== undefined) cfg[name].port = Number(sect.port);
          if (sect.name !== undefined) cfg[name].dataDir = sect.name; // name maps where applicable
          // password/name for redis live under options; set defensively.
          if (sect.pass !== undefined) { cfg[name].options = cfg[name].options ?? {}; cfg[name].options.auth_pass = sect.pass; }
          if (sect.name !== undefined) { cfg[name].options = cfg[name].options ?? {}; cfg[name].options.db = cfg[name].options.db ?? 0; }
        };
        applySection('objects', plan.objects);
        applySection('states', plan.states);
        // Multihost role is expressed purely in iobroker.json: ioBroker's
        // multihost 'master' is the host that RUNS the multihost service, i.e.
        // multihostService.enabled = true; a 'slave' does not run the service
        // (enabled = false) and instead points its objects/states host at the
        // master (handled by the objects/states patch above). We set this by
        // FILE here rather than via `iobroker multihost enable/disable`, because
        // that CLI opens a live connection to the objects/states DB — and at
        // this point in startup js-controller (which hosts the local jsonl DB
        // server) is not running yet, so the CLI would fail with
        // ECONNREFUSED against the not-yet-listening DB. Patching the file is
        // equivalent, side-effect-free, and idempotent.
        if (plan.role) {
          cfg.multihostService = cfg.multihostService ?? {};
          // enabled drives ioBroker's actual multihost behavior (master runs
          // the service); role is our own marker so the idempotency diff can
          // tell 'slave' apart from 'standalone' (both have enabled=false).
          cfg.multihostService.enabled = plan.role === 'master';
          cfg.multihostService.role = plan.role;
        }
        const tmp = path + '.tmp';
        writeFileSync(tmp, JSON.stringify(cfg, null, 2) + '\n');
        renameSync(tmp, path);
        process.stderr.write('patched ' + path + '\n');
      "; then
        log "failed to patch ${IOB_JSON}; refusing to start js-controller"
        exit 1
      fi
    fi

    # The multihost role is applied entirely by the iobroker.json patch above
    # (multihostService.enabled). We intentionally do NOT run `iobroker
    # multihost enable/disable` here: that CLI connects to the live
    # objects/states DB, which is not serving yet at this startup stage (the
    # local jsonl server is hosted by js-controller, started later), so it would
    # fail with ECONNREFUSED. The file patch is the equivalent, connectionless
    # way to select the role and stays idempotent across restarts.
    log "database/multihost configuration applied"
    exit 0
    ;;
  *)
    log "unexpected plan result from db planner: '${plan}'"
    exit 1
    ;;
esac

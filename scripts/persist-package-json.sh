#!/usr/bin/env bash
# persist-package-json.sh - keep /opt/iobroker/package.json alive across a
# container RECREATE by mirroring it into the persistent node_modules volume.
#
# THE PROBLEM
# -----------
# node_modules is a persistent VOLUME; package.json is NOT — it lives in the
# image/container layer. js-controller and adapters (e.g. the javascript adapter
# installing script modules) grow package.json's dependency list at runtime to
# match the installed adapter set.
#
#   * `docker restart` reuses the same writable layer, so the grown package.json
#     survives and stays in sync with the node_modules volume -> no issue.
#   * `docker compose up` / recreate starts a FRESH layer, resetting package.json
#     to the image baseline (only iobroker.js-controller) while the node_modules
#     volume still holds every adapter. They are now OUT OF SYNC: the next
#     `npm install` (reconcile OR a runtime adapter install) treats every adapter
#     as EXTRANEOUS and PRUNES it, collapsing node_modules and forcing a full
#     reinstall. This is why the breakage appears only after a RECREATE, never
#     after a restart.
#
# THE FIX
# -------
# Keep an authoritative copy of package.json INSIDE the persistent node_modules
# volume as a DOTFILE (`.iob-package.json`, never mistaken for a package) and:
#
#   restore : on start, BEFORE any npm/reconcile runs, rebuild
#             /opt/iobroker/package.json as a SUPERSET of everything present
#             under node_modules so no npm invocation prunes an installed
#             package. This is a spec-PRESERVING MERGE (see do_restore): existing
#             dependency specs (github:, npm: aliases, ranges, pinned versions)
#             are kept verbatim from the snapshot / live file, and only packages
#             on disk but absent from the manifest are ADDED (with their on-disk
#             version). This also covers an adapter a user installed via admin
#             while running: it is on disk, so the rebuild lists it and the next
#             recreate cannot prune it. On first start (no snapshot yet) it seeds
#             from the current package.json. The rebuild writes BOTH the live
#             package.json and the snapshot, so the snapshot always tracks the
#             on-disk truth — there is no separate "save" step.
#
# There is deliberately NO shutdown/post-install "save": rebuilding from on-disk
# truth on every start always runs (a shutdown handler may not, e.g. docker kill
# / OOM), captures adapters installed via admin at runtime (they are on disk),
# and cannot persist a half-written manifest.
#
# A dotfile + COPY/merge (not a symlink) is deliberate: npm/js-controller write
# package.json atomically (write temp + rename), which would silently replace a
# symlink with a regular file and break persistence.
#
# All operations are BEST-EFFORT: failures are logged and exit 0 so package.json
# upkeep never blocks startup (worst case is the pre-fix behavior, which
# reconcile's completeness check still recovers).
#
# Usage:  persist-package-json.sh restore
#
# Environment:
#   IOB_ROOT              ioBroker install root (default /opt/iobroker)
#   IOB_NODE_MODULES_DIR  node_modules dir     (default $IOB_ROOT/node_modules)
#   IOB_PKG_JSON          package.json path    (default $IOB_ROOT/package.json)
#   IOB_PKG_JSON_PERSIST  persisted copy path  (default $IOB_NODE_MODULES_DIR/.iob-package.json)
set -u

IOB_ROOT="${IOB_ROOT:-/opt/iobroker}"
IOB_NODE_MODULES_DIR="${IOB_NODE_MODULES_DIR:-${IOB_ROOT}/node_modules}"
IOB_PKG_JSON="${IOB_PKG_JSON:-${IOB_ROOT}/package.json}"
IOB_PKG_JSON_PERSIST="${IOB_PKG_JSON_PERSIST:-${IOB_NODE_MODULES_DIR}/.iob-package.json}"

log() { printf 'persist-package-json: %s\n' "$*"; }

# do_restore: rebuild /opt/iobroker/package.json so its dependencies are a
# SUPERSET of everything actually present under node_modules, then mirror the
# result into the persistent snapshot. This is a spec-PRESERVING MERGE, not a
# blind copy, because package.json dependency specs are heterogeneous and the
# on-disk version is NOT a safe substitute for them:
#
#   "iobroker.mielecloudservice": "github:Grizzelbee/...#development"   (git)
#   "iobroker.nanoleaf-lightpanels": "github:FernetMenta/...#..."       (git)
#   "@iobroker-javascript.0/csv-parse": "npm:csv-parse@^7.0.2"          (alias)
#   "iobroker.lovelace": "^6.1.3"                                       (range)
#   "iobroker.admin": "8.0.11"                                          (pinned)
#
# Rewriting any of these to the installed bare version (e.g. a github adapter as
# "7.0.0") could make a later `npm install` fetch the wrong thing from the npm
# registry or fail. So we NEVER overwrite an existing dependency spec. The merge:
#
#   base    = persisted snapshot (.iob-package.json) if present, else the live
#             package.json (first start). Carries the authoritative specs.
#   overlay = the CURRENT live package.json dependencies layered on top (keys the
#             live file has win). On a recreate the live file was reset to the
#             image baseline, so this only re-adds js-controller (harmless, the
#             snapshot already has it); when the layer was NOT reset it captures
#             anything installed since the last save.
#   fill    = for every package present on disk under node_modules that is STILL
#             not a dependency key after base+overlay, ADD it with its own
#             package.json version. This is what protects an adapter a user
#             installed via admin (present on disk, but not yet in the snapshot)
#             from being pruned on the next recreate. A bare version is only ever
#             ADDED for a key nobody else specified — it never replaces a spec.
#
# The merged manifest (preserving the base's name/version/engines/etc. fields) is
# written to BOTH the live package.json and the snapshot. Runs pre-controller, so
# there is no concurrent writer. Best-effort: on any error the live file is left
# as the plain restored snapshot (or untouched) and we return 0.
do_restore() {
  [[ -d "${IOB_NODE_MODULES_DIR}" ]] || { log "node_modules dir ${IOB_NODE_MODULES_DIR} absent; nothing to restore"; return 0; }
  command -v node >/dev/null 2>&1 || { do_restore_copy_fallback; return 0; }

  local result
  result="$(IOB_PP_PERSIST="${IOB_PKG_JSON_PERSIST}" IOB_PP_LIVE="${IOB_PKG_JSON}" IOB_PP_NM="${IOB_NODE_MODULES_DIR}" \
    node --input-type=module -e '
      import { readFileSync, writeFileSync, readdirSync } from "node:fs";
      import { join } from "node:path";
      const persist = process.env.IOB_PP_PERSIST;
      const live = process.env.IOB_PP_LIVE;
      const nm = process.env.IOB_PP_NM;

      const readJson = (p) => { try { return JSON.parse(readFileSync(p, "utf8")); } catch { return null; } };

      const snap = readJson(persist);
      const cur = readJson(live);

      // Base object: prefer the snapshot (authoritative full manifest), else the
      // live file (first start). If neither parses, we cannot merge safely.
      const base = snap || cur;
      if (!base || typeof base !== "object") { process.stdout.write("NOBASE"); process.exit(0); }

      const deps = (base.dependencies && typeof base.dependencies === "object") ? { ...base.dependencies } : {};

      // overlay: current live deps win for keys they define (captures runtime
      // installs since the last save when the layer was not reset).
      if (cur && cur.dependencies && typeof cur.dependencies === "object") {
        for (const [k, v] of Object.entries(cur.dependencies)) {
          if (typeof v === "string" && v.length) deps[k] = v;
        }
      }

      // fill: add any on-disk package not already keyed, using its own version.
      // Walk one level, and one extra level into @scope dirs (scoped packages).
      let filled = 0;
      const addFromDir = (pkgDir, keyName) => {
        if (Object.prototype.hasOwnProperty.call(deps, keyName)) return; // never override a spec
        const p = readJson(join(pkgDir, "package.json"));
        const ver = p && typeof p.version === "string" && p.version.length ? p.version : null;
        if (!ver) return; // no usable version -> leave out rather than guess
        deps[keyName] = ver;
        filled++;
      };
      let top = [];
      try { top = readdirSync(nm, { withFileTypes: true }); } catch { top = []; }
      for (const e of top) {
        if (!e.isDirectory()) continue;
        const name = e.name;
        if (name.startsWith(".")) continue;   // .bin, .iob-package.json, .node-abi, ...
        if (name.startsWith("@")) {
          // scope dir: each child is a package named @scope/child
          let kids = [];
          try { kids = readdirSync(join(nm, name), { withFileTypes: true }); } catch { kids = []; }
          for (const k of kids) {
            if (!k.isDirectory()) continue;
            addFromDir(join(nm, name, k.name), `${name}/${k.name}`);
          }
          continue;
        }
        addFromDir(join(nm, name), name);
      }

      const out = { ...base, dependencies: deps };
      const text = JSON.stringify(out, null, 2) + "\n";
      let wroteLive = false, wroteSnap = false;
      try { writeFileSync(live, text); wroteLive = true; } catch {}
      try { writeFileSync(persist, text); wroteSnap = true; } catch {}
      process.stdout.write(`OK filled=${filled} deps=${Object.keys(deps).length} live=${wroteLive} snap=${wroteSnap}`);
    ' 2>/dev/null)" || result="ERR"

  case "${result}" in
    OK\ *)
      log "rebuilt package.json as a superset of node_modules (${result#OK }); prevents npm prune across recreate and preserves github/alias specs"
      ;;
    NOBASE)
      log "no parseable snapshot or package.json to merge; falling back to copy"
      do_restore_copy_fallback
      ;;
    *)
      log "WARNING package.json merge failed (${result}); falling back to copy"
      do_restore_copy_fallback
      ;;
  esac
  return 0
}

# do_restore_copy_fallback: the original blind-copy behavior, used when node is
# unavailable or the merge could not run. Still prevents the common prune case.
do_restore_copy_fallback() {
  if [[ -f "${IOB_PKG_JSON_PERSIST}" ]]; then
    if cp -f -- "${IOB_PKG_JSON_PERSIST}" "${IOB_PKG_JSON}" 2>/dev/null; then
      log "restored package.json from ${IOB_PKG_JSON_PERSIST} (copy fallback)"
    else
      log "WARNING could not restore package.json from ${IOB_PKG_JSON_PERSIST}; an install-time npm prune may occur (reconcile will recover)"
    fi
  elif [[ -f "${IOB_PKG_JSON}" ]]; then
    if cp -f -- "${IOB_PKG_JSON}" "${IOB_PKG_JSON_PERSIST}" 2>/dev/null; then
      log "seeded ${IOB_PKG_JSON_PERSIST} from current package.json (first start; copy fallback)"
    else
      log "WARNING could not seed ${IOB_PKG_JSON_PERSIST} (continuing)"
    fi
  else
    log "no package.json at ${IOB_PKG_JSON} and no persisted copy; nothing to do"
  fi
}

case "${1:-}" in
  restore) do_restore ;;
  *)
    printf 'usage: %s restore\n' "${0##*/}" >&2
    exit 2
    ;;
esac
exit 0

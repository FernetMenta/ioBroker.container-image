#!/usr/bin/env bash
# restore-backup.sh - restore an ioBroker backup at container startup.
#
# WHY THIS EXISTS
# ---------------
# The `iobroker restore <backup>` CLI requires js-controller to be STOPPED while
# it rewrites the objects/states DBs and iobroker.json. In this image
# js-controller is PID-1's foreground process (the entrypoint `exec`s it as the
# last step), so there is no running container in which an operator could
# "stop iobroker, restore, start iobroker": stopping the controller terminates
# the container. The only safe moment to restore is DURING startup, BEFORE
# js-controller is exec'd — which is exactly where the entrypoint calls us.
#
# This lets an operator seed a brand-new (or existing) container from a backup:
# drop a single backup file into a `restore/` folder inside the Data_Volume and
# (re)create the container. On the next start we detect the folder, restore it,
# and remove the folder so the restore happens EXACTLY ONCE (a later restart
# must not re-restore stale data over live changes).
#
# CONTRACT (observe -> act)
# -------------------------
#   1. OBSERVE: look for `${IOB_DATA_DIR}/restore`.
#        * absent            -> nothing to do, exit 0 (the common case).
#        * present, EMPTY    -> nothing to restore; remove it and exit 0.
#        * present, EXACTLY  -> restore that file.
#          ONE backup file
#        * present, MORE THAN-> ambiguous; we will not guess. Exit non-zero so
#          ONE file             the entrypoint refuses to start (leave the folder
#                               in place so the operator can fix it).
#   2. ACT: run `iobroker restore <path>` from IOB_ROOT (the CLI resolves paths
#      and its data dir relative to the install root) with `--yes` so it never
#      blocks on a prompt. All output is tee'd to `${IOB_LOG_DIR}/restore.log`.
#        * restore FAILS  -> exit non-zero; the entrypoint must NOT start the
#          container (a half-restored DB is worse than a clear failure).
#        * restore OK     -> delete `${IOB_DATA_DIR}/restore` and exit 0 so the
#          entrypoint continues with the remaining startup steps.
#
# It works on a FRESH container with no prior data: the entrypoint runs the
# reconcile INIT phase (`iobroker setup first`) before us, so iobroker.json and
# the local DB exist for the CLI to operate on; `iobroker restore` then replaces
# that fresh baseline with the backup's objects/states/config. The subsequent
# install phase installs the adapter code the restored config expects.
#
# A backup file is recognized by ioBroker's own naming convention — a
# `.tar.gz` archive (the format `iobroker backup` produces, e.g.
# `2015_02_10-17_49_45_backupIoBroker.tar.gz`). Any single regular file in the
# folder is accepted and handed to the CLI, but non-archive files are ignored
# when counting so a stray `.gitkeep`/`README` next to the backup does not make
# the folder look ambiguous.
#
# Usage:
#   restore-backup.sh
#
# Environment overrides (primarily for testing / non-default layouts):
#   IOB_ROOT          ioBroker install root (default /opt/iobroker)
#   IOB_DATA_DIR      Data_Volume dir       (default $IOB_ROOT/iobroker-data)
#   IOB_LOG_DIR       Log_Volume dir        (default $IOB_ROOT/log)
#   IOB_RESTORE_DIR   restore folder        (default $IOB_DATA_DIR/restore)
#   IOB_RESTORE_LOG   restore log file      (default $IOB_LOG_DIR/restore.log)
#   IOB_CLI           iobroker CLI path     (default $IOB_ROOT/iobroker)
#   IOB_RESTORE_DRY_RUN  when "true", log the restore command instead of running it
#
# Exit codes:
#   0  nothing to restore, or a restore completed successfully
#   1  ambiguous restore folder (more than one backup file), the restore command
#      failed, or a required precondition (readable folder, usable CLI) was not met
set -euo pipefail

IOB_ROOT="${IOB_ROOT:-/opt/iobroker}"
IOB_DATA_DIR="${IOB_DATA_DIR:-${IOB_ROOT}/iobroker-data}"
IOB_LOG_DIR="${IOB_LOG_DIR:-${IOB_ROOT}/log}"
IOB_RESTORE_DIR="${IOB_RESTORE_DIR:-${IOB_DATA_DIR}/restore}"
IOB_RESTORE_LOG="${IOB_RESTORE_LOG:-${IOB_LOG_DIR}/restore.log}"
IOB_CLI="${IOB_CLI:-${IOB_ROOT}/iobroker}"
IOB_RESTORE_DRY_RUN="${IOB_RESTORE_DRY_RUN:-false}"

# --- Logging -----------------------------------------------------------------
# Every line goes to the container's stderr (visible via `docker logs`) AND, when
# the Log_Volume is writable, is appended to restore.log with a timestamp so the
# restore has a durable record next to the other logs. Best-effort: a
# non-writable Log_Volume just means stderr-only logging and never aborts.
LOG_FILE_OK=false
log_init() {
  local dir
  dir="$(dirname -- "${IOB_RESTORE_LOG}")"
  [[ -d "${dir}" ]] || mkdir -p -- "${dir}" 2>/dev/null || true
  # Truncate to start a fresh log for THIS start (a prior start's restore is not
  # relevant once the folder has been consumed). Run the truncation in a subshell
  # so a redirection failure on a non-writable Log_Volume (the shell prints that
  # to the CURRENT stderr, before an inline `2>/dev/null` on the `:` builtin can
  # apply) is fully swallowed and we quietly fall back to stderr-only logging.
  if ( : >"${IOB_RESTORE_LOG}" ) 2>/dev/null; then
    LOG_FILE_OK=true
  fi
}

log() {
  echo "restore: $*" >&2
  if [[ "${LOG_FILE_OK}" == "true" ]]; then
    printf '%s restore: %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')" "$*" \
      >>"${IOB_RESTORE_LOG}" 2>/dev/null || true
  fi
}

die() {
  log "ERROR: $*"
  exit 1
}

# is_backup_file: recognize an ioBroker backup archive by extension. `iobroker
# backup` always writes a gzip tarball; we accept the common archive suffixes so
# a stray non-archive file (README, .gitkeep) next to the backup is ignored when
# counting candidates.
is_backup_file() {
  case "$1" in
    *.tar.gz | *.tgz) return 0 ;;
    *) return 1 ;;
  esac
}

# --- 1. OBSERVE the restore folder ------------------------------------------

# No folder at all: the overwhelmingly common case. Say nothing noisy and move on.
if [[ ! -e "${IOB_RESTORE_DIR}" ]]; then
  exit 0
fi

# It exists — from here on we have something to report, so open the log.
log_init
log "detected restore request folder: ${IOB_RESTORE_DIR}"

if [[ ! -d "${IOB_RESTORE_DIR}" ]]; then
  die "${IOB_RESTORE_DIR} exists but is not a directory; expected a folder containing a single backup file"
fi
if [[ ! -r "${IOB_RESTORE_DIR}" ]]; then
  die "restore folder ${IOB_RESTORE_DIR} is not readable"
fi

# Collect the candidate backup archives (regular files with a backup extension),
# ignoring subdirectories and non-archive files. Use a NUL-safe glob loop so
# names with spaces are handled correctly.
candidates=()
all_files=()
shopt -s nullglob dotglob
for entry in "${IOB_RESTORE_DIR}"/*; do
  [[ -f "${entry}" ]] || continue
  all_files+=("${entry}")
  if is_backup_file "${entry}"; then
    candidates+=("${entry}")
  fi
done
shopt -u nullglob dotglob

# Empty folder (or only subdirectories): nothing to restore. Remove the folder so
# it does not linger, and continue startup normally.
if [[ ${#all_files[@]} -eq 0 ]]; then
  log "restore folder is empty; nothing to restore"
  rm -rf -- "${IOB_RESTORE_DIR}" 2>/dev/null \
    || log "note: could not remove empty restore folder ${IOB_RESTORE_DIR} (continuing)"
  exit 0
fi

# No recognizable backup archive among the files present: refuse to guess.
if [[ ${#candidates[@]} -eq 0 ]]; then
  die "restore folder ${IOB_RESTORE_DIR} contains file(s) but no ioBroker backup archive (*.tar.gz / *.tgz); place exactly one backup file and recreate the container"
fi

# More than one backup archive: ambiguous. We will NOT pick one for the operator.
# Leave the folder in place (do not destroy their files) and fail so the
# container does not start with the wrong data.
if [[ ${#candidates[@]} -gt 1 ]]; then
  log "found ${#candidates[@]} backup archives in ${IOB_RESTORE_DIR}:"
  for f in "${candidates[@]}"; do
    log "  - $(basename -- "${f}")"
  done
  die "the restore folder must contain EXACTLY ONE backup file; remove the extras and recreate the container"
fi

BACKUP_FILE="${candidates[0]}"
log "selected backup file: ${BACKUP_FILE}"

# --- 2. ACT: run the restore -------------------------------------------------

# Verify the CLI is available before we commit to restoring.
if [[ ! -x "${IOB_CLI}" ]] && ! command -v iobroker >/dev/null 2>&1; then
  die "iobroker CLI not found (looked for ${IOB_CLI} and 'iobroker' on PATH); cannot restore"
fi
# Prefer the explicit CLI path in the install root; fall back to PATH.
if [[ ! -x "${IOB_CLI}" ]]; then
  IOB_CLI="$(command -v iobroker)"
fi

if [[ "${IOB_RESTORE_DRY_RUN}" == "true" ]]; then
  log "[dry-run] (cd ${IOB_ROOT} && ${IOB_CLI} restore ${BACKUP_FILE} --yes)"
  log "[dry-run] would remove ${IOB_RESTORE_DIR} on success"
  exit 0
fi

log "restoring ioBroker from ${BACKUP_FILE} (js-controller is not yet running)"
log "this can take several minutes; see ${IOB_RESTORE_LOG} for the full CLI output"

# Run the restore from the install root (the CLI resolves its data dir relative
# to it) and tee ALL of its stdout+stderr into restore.log so the operator has
# the complete CLI transcript, not just our summary lines. `--yes` answers the
# CLI's confirmation prompt so it never blocks a headless start. We must capture
# the CLI's exit status, NOT tee's, so pipefail is required (set above) and we
# check ${PIPESTATUS[0]}.
restore_rc=0
if [[ "${LOG_FILE_OK}" == "true" ]]; then
  # Tee the CLI's stdout+stderr into restore.log AND to the container's stderr.
  # We must read the RESTORE's exit code, not tee's, so we (a) rely on pipefail
  # being set and read PIPESTATUS[0] explicitly, and (b) suspend `set -e` around
  # the pipeline so a non-zero restore does not abort the script before we can
  # capture and act on it. Appending `|| true` instead would run a second command
  # and clobber PIPESTATUS, masking the real exit code.
  set +e
  ( cd -- "${IOB_ROOT}" && "${IOB_CLI}" restore "${BACKUP_FILE}" --yes ) \
    2>&1 | tee -a "${IOB_RESTORE_LOG}" >&2
  restore_rc="${PIPESTATUS[0]}"
  set -e
else
  ( cd -- "${IOB_ROOT}" && "${IOB_CLI}" restore "${BACKUP_FILE}" --yes ) >&2 || restore_rc=$?
fi

if [[ "${restore_rc}" -ne 0 ]]; then
  die "iobroker restore failed (exit ${restore_rc}); refusing to start the container. The restore folder is left in place at ${IOB_RESTORE_DIR} so you can inspect it; check ${IOB_RESTORE_LOG} for details"
fi

log "restore completed successfully"

# --- 3. Consume the folder so we never restore twice ------------------------
# Removing the folder is what makes the restore a ONE-SHOT operation: a later
# `docker restart`/recreate must not re-apply this backup over live data. This is
# the LAST step so a failure above always leaves the folder for a retry.
if rm -rf -- "${IOB_RESTORE_DIR}" 2>/dev/null; then
  log "removed restore folder ${IOB_RESTORE_DIR}"
else
  # The restore already succeeded; failing to delete the trigger folder is a
  # real problem (the NEXT start would restore again over live data), so treat
  # it as fatal to force the operator to clear it before the container runs.
  die "restore succeeded but the restore folder ${IOB_RESTORE_DIR} could NOT be removed; refusing to start to avoid restoring this backup again on the next start. Remove the folder manually and recreate the container"
fi

exit 0

#!/usr/bin/env bash
# ensure-npmrc.sh - thin shell glue for the npm settings manager (design §8).
#
# Ensures the ioBroker `.npmrc` contains the settings the installer relies on
# (`audit=false`, `update-notifier=false`, `engine-strict=true`; Req 11.1-11.4)
# and, when the settings file is corrupt or inaccessible, BLOCKS the adapter
# install by exiting non-zero rather than letting npm fall back to its default
# behavior (Req 11.5).
#
# All decision logic lives in the pure module `lib/npmrc.js`. This script keeps
# filesystem side effects thin: it observes the file (accessible? exists? what
# content?), asks the module for a plan, and then acts on that plan (do nothing,
# write the canonical content, or abort). The entrypoint pipeline (task 11.1)
# calls this script at its "ensure .npmrc" step.
#
# Usage:
#   ensure-npmrc.sh [NPMRC_PATH]
# NPMRC_PATH defaults to /opt/iobroker/.npmrc (the module's DEFAULT_NPMRC_PATH).
#
# Exit codes:
#   0  .npmrc is present and correct, or was (re)written to the required content
#   1  the settings file is corrupt or inaccessible -> install blocked (Req 11.5)
set -euo pipefail

# Resolve this script's directory so we can locate the sibling lib/ module
# regardless of the working directory the entrypoint runs us from.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
NPMRC_MODULE="${REPO_ROOT}/lib/npmrc.js"

# Ask the pure module for the default path when the caller did not override it.
NPMRC_PATH="${1:-}"
if [[ -z "${NPMRC_PATH}" ]]; then
  NPMRC_PATH="$(node --input-type=module -e \
    "import { DEFAULT_NPMRC_PATH } from '${NPMRC_MODULE}'; process.stdout.write(DEFAULT_NPMRC_PATH);")"
fi

# Observe the file with thin, side-effect-free checks:
#   accessible - can we read it (or is it simply absent)?
#   exists     - is a regular file present at the path?
#   content    - the raw bytes, when present and readable.
accessible=true
exists=false
content=""

if [[ -e "${NPMRC_PATH}" ]]; then
  exists=true
  if [[ -r "${NPMRC_PATH}" ]] && content="$(cat -- "${NPMRC_PATH}" 2>/dev/null)"; then
    accessible=true
  else
    # The file exists but cannot be read -> inaccessible. Block (Req 11.5).
    accessible=false
  fi
fi

# Hand the observations to the pure module and get back an action. The module
# owns the required settings, the corruption/inaccessibility rules, and the
# canonical rendered content. We pass observations via environment variables to
# avoid any shell-quoting hazards with the file content.
plan="$(
  IOB_NPMRC_ACCESSIBLE="${accessible}" \
  IOB_NPMRC_EXISTS="${exists}" \
  IOB_NPMRC_CONTENT="${content}" \
  IOB_NPMRC_PATH="${NPMRC_PATH}" \
  node --input-type=module -e "
    import { ensureNpmrc } from '${NPMRC_MODULE}';
    const input = {
      accessible: process.env.IOB_NPMRC_ACCESSIBLE === 'true',
      exists: process.env.IOB_NPMRC_EXISTS === 'true',
      content: process.env.IOB_NPMRC_CONTENT ?? '',
    };
    const plan = ensureNpmrc(input, process.env.IOB_NPMRC_PATH);
    // Emit the action on line 1 and, for a write, the content on the rest.
    process.stdout.write(plan.action + '\n');
    if (plan.action === 'write') process.stdout.write(plan.content);
  "
)"

action="${plan%%$'\n'*}"

case "${action}" in
  ok)
    echo "ensure-npmrc: ${NPMRC_PATH} already has required npm settings" >&2
    exit 0
    ;;
  write)
    # Everything after the first newline is the canonical content to write.
    new_content="${plan#*$'\n'}"
    if ! printf '%s' "${new_content}" >"${NPMRC_PATH}"; then
      echo "ensure-npmrc: failed to write ${NPMRC_PATH}; blocking install" >&2
      exit 1
    fi
    echo "ensure-npmrc: wrote required npm settings to ${NPMRC_PATH}" >&2
    exit 0
    ;;
  block)
    echo "ensure-npmrc: ${NPMRC_PATH} is corrupt or inaccessible;" \
      "blocking adapter install (refusing default npm behavior)" >&2
    exit 1
    ;;
  *)
    echo "ensure-npmrc: unexpected plan from npm settings manager: '${action}'" >&2
    exit 1
    ;;
esac

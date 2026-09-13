#!/usr/bin/env bash
# install-source-classify.sh - classification smoke test for reconcile's
# install-source router `source_is_url` (design §5; Req 8.9/8.10).
#
# WHY THIS TEST EXISTS
# --------------------
# During reconciliation `reconcile.sh` decides, per adapter, HOW to (re)install
# its code from the source js-controller recorded in `common.installedFrom`:
#
#   * `source_is_url` returns FALSE  -> `iobroker install <name>` (repo, by name)
#   * `source_is_url` returns TRUE   -> `iobroker url <source>`   (npm install <source>)
#
# This mirrors js-controller's OWN boundary: its by-name installer resolves the
# name only in the ACTIVE repository and throws "Unknown packet name <name>.
# Please install ... using url" for anything not found there
# (js-controller setupInstall.ts). So a source that is NOT a bare, unversioned
# `iobroker.<name>` MUST go through `iobroker url`, or the repo-name lookup fails.
#
# The comparison against js-controller's restore/install path (setupBackup.ts
# `_restorePreservedAdapters` -> `tools.installNodeModule(installSource)`, and
# setupInstall.ts) surfaced ONE case worth pinning here: SCOPED / VENDOR npm
# packages. js-controller supports an adapter whose npm package name differs
# from `iobroker.<name>`, installed as `iobroker.<name>@npm:<realPackage>`
# (setupInstall.ts `source.packetName` -> `iobroker.<name>@npm:<pkg>`), and
# `installedFrom` for a url/scoped install is the raw npm spec.
#
# This test sources ONLY the pure `source_is_url` classifier out of
# reconcile.sh (no ioBroker, no container, no network) and asserts its verdict
# for every source shape reconcile must route, INCLUDING the scoped/@npm: shapes
# that were the open question from the js-controller comparison. It documents
# the intended contract and fails loudly if a future edit changes routing.
#
# It is placed under test/smoke/ because it drives a SHELL function rather than
# a `lib/*.js` module (the vitest suite covers the JS modules); it needs only
# bash and has no external prerequisites, so unlike the docker-based smoke
# tests it never skips.
#
# Exit codes:
#   0  all classification expectations held
#   1  at least one expectation failed (routing regression)
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"
RECONCILE_SH="${REPO_ROOT}/scripts/reconcile.sh"

PASS_PREFIX="install-source-classify: PASS:"
FAIL_PREFIX="install-source-classify: FAIL:"

if [[ ! -r "${RECONCILE_SH}" ]]; then
  echo "${FAIL_PREFIX} cannot read ${RECONCILE_SH}" >&2
  exit 1
fi

# Extract JUST the `source_is_url` function body from reconcile.sh and eval it
# in THIS shell. reconcile.sh runs a full observe->plan->act pipeline on load
# (it is not written to be `source`d), so we must not source the whole file.
# `sed` pulls the block from the `source_is_url() {` line through its closing
# `}` at column 0, which is exactly how the function is formatted in the script.
fn_src="$(sed -n '/^source_is_url() {/,/^}/p' "${RECONCILE_SH}")"
if [[ -z "${fn_src}" ]]; then
  echo "${FAIL_PREFIX} could not extract source_is_url() from ${RECONCILE_SH}" >&2
  exit 1
fi
# shellcheck disable=SC1090
eval "${fn_src}"
if ! declare -F source_is_url >/dev/null 2>&1; then
  echo "${FAIL_PREFIX} source_is_url() did not define after eval" >&2
  exit 1
fi

fail=""

# expect_url <source> <expect: url|name> <why>
# Asserts source_is_url's verdict for one recorded install source.
#   url  -> function returns 0 (route through `iobroker url`)
#   name -> function returns 1 (route through `iobroker install <name>`)
expect_url() {
  local src="$1" want="$2" why="$3" got
  if source_is_url "${src}"; then got="url"; else got="name"; fi
  if [[ "${got}" == "${want}" ]]; then
    printf '  ok   [%-4s] %-45s %s\n' "${got}" "${src:-<empty>}" "${why}"
  else
    printf '  FAIL want=%-4s got=%-4s  %-40s %s\n' "${want}" "${got}" "${src:-<empty>}" "${why}" >&2
    fail="${fail} [${src}]"
  fi
}

echo "=== install-source classification (source_is_url) ==="

# --- Repo adapters: install BY NAME (return 1 / name) ------------------------
# Empty source or a bare, unversioned iobroker.<name> is a normal repo adapter;
# `iobroker install <name>` lets the active repo pick the current version.
expect_url ""                     name "empty installedFrom -> repo by name"
expect_url "iobroker.admin"       name "bare repo spec -> by name"
expect_url "iobroker.zigbee"      name "bare repo spec -> by name"

# --- Pinned / beta / latest repo specs: use URL (return 0 / url) -------------
# js-controller records the installed version/tag in installedFrom; the active
# repo may no longer offer it, so `install <name>` would throw Unknown packet.
expect_url "iobroker.nut2@latest" url  "pinned/latest-repo spec -> url"
expect_url "iobroker.foo@1.2.3"   url  "pinned version spec -> url"

# --- Non-repo sources: use URL (return 0 / url) ------------------------------
expect_url "https://example.com/iobroker.foo.tgz" url "https tarball -> url"
expect_url "http://example.com/iobroker.foo.tgz"  url "http tarball -> url"
expect_url "git+https://github.com/o/iobroker.foo" url "git+ URL -> url"
expect_url "git://github.com/o/iobroker.foo.git"  url "git URL -> url"
expect_url "file:/tmp/iobroker.foo"               url "file: local -> url"
expect_url "/opt/pkgs/iobroker.foo"               url "absolute path -> url"
expect_url "owner/iobroker.foo"                   url "GitHub owner/repo -> url"
expect_url "owner/iobroker.foo#beta"              url "GitHub owner/repo#ref -> url"

# --- SCOPED / VENDOR npm packages (the js-controller comparison open case) ---
# (A) The `iobroker.<name>@npm:<realPackage>` shape js-controller itself uses
#     for a vendor/scoped adapter. It contains '@', so it already routes to url.
expect_url "iobroker.foo@npm:@scope/real-package" url \
  "vendor @npm: rename (has @) -> url [js-controller shape]"
expect_url "iobroker.foo@npm:real-package"        url \
  "vendor @npm: rename -> url"

# (B) THE GAP: a BARE scoped npm spec with NO version, e.g. installedFrom set to
#     a raw scoped package name. It is NOT an iobroker.<name>, has no '@version'
#     (the leading '@' is the scope, not a version separator), and contains a
#     '/', so today it is caught by the `*/*` (owner/repo) arm and routed to
#     url. That happens to be the SAFE outcome, but for the RIGHT-ISH reason
#     (matched as GitHub shorthand, not as a scoped npm package). We pin the
#     OBSERVED verdict so the behavior is explicit and any future reordering of
#     the case arms that would flip it to `name` (which WOULD break: `iobroker
#     install @scope/pkg` cannot resolve) fails this test loudly.
expect_url "@scope/iobroker-foo"                  url \
  "bare scoped npm pkg (with /) -> url [matched via owner/repo arm]"

# (C) The genuinely UNHANDLED corner: a scoped package with NO slash is not a
#     valid npm spec on its own, but if such a string ever reached the router it
#     would fall through to the default `name` arm. This asserts today's ACTUAL
#     behavior so the corner is documented rather than silently assumed. If you
#     decide bare '@'-prefixed sources should always be url, change the router
#     AND flip this expectation together.
expect_url "@scopeonly"                           name \
  "bare '@scope' with no slash -> name [default arm; documents current behavior]"

echo "---"
if [[ -n "${fail}" ]]; then
  echo "${FAIL_PREFIX} misrouted sources:${fail}" >&2
  echo "=== install-source classification FAILED ===" >&2
  exit 1
fi
echo "${PASS_PREFIX} all sources routed as expected"
echo "=== install-source classification PASSED ==="
exit 0

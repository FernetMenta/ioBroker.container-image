#!/usr/bin/env bash
# build-local.sh - first-class local build path that mirrors CI (design §"Local
# build path", task 16.2).
#
# This script builds the same image CI builds, from the same Dockerfile, with
# NODE_MAJOR and DEBIAN_CODENAME read from the maintainer-owned Build_Config in
# package.json (the `containerImage` key: `nodeMajor` + `debianCodename`) using
# the SAME pure derivation the rest of the code uses (lib/build-config.js +
# lib/node-major.js -> deriveNodeMajorFromPackageJson). The derivation is
# fail-fast: a missing/empty/whitespace/non-integer nodeMajor aborts the build
# before any `docker buildx` step, exactly like CI. It NEVER falls back to a
# system default. (Req 5.4, 5.5, 5.7)
#
# Equivalence with CI (Req 2 build correctness):
#   - same Dockerfile              (-f Dockerfile)
#   - same Build_Config read       (deriveNodeMajorFromPackageJson from lib/,
#                                    debianCodename from package.json)
#   - same build args             (--build-arg NODE_MAJOR / DEBIAN_CODENAME)
#   - same runtime-dependency gate (a separate `--target verify` build, run by
#                                    run_verify_gate, matching the gate CI runs)
# so a local build reproduces what CI builds.
#
# What gets built/loaded:
#   The loadable/validation build targets the SHIPPABLE `runtime` stage — the
#   rootless (USER 1000) image you actually run. The runtime-dependency
#   verification gate (the `verify` stage, which ends on `USER root` and only
#   asserts dependencies during the build) is run as a SEPARATE non-loaded build
#   so it fires locally without polluting the image store. Loading the `verify`
#   stage itself would place a root-running, gate-topped image in your store,
#   which is not what you want to run — hence the split.
#
# Modes:
#   single (default) - build the runtime stage for the local host platform and
#                      load it into the local docker image store (`--load`);
#                      the verify gate runs first (host platform).
#   multi            - build linux/amd64,linux/arm64. buildx cannot `--load` a
#                      multi-platform result into the docker store, so a multi
#                      build validates both architectures (runtime + the verify
#                      gate per arch) without producing a loadable local image
#                      and WITHOUT pushing.
#
# This script NEVER pushes. There is no push option here on purpose; publishing
# is CI's job (task 16.1). (design: "Local builds do not push by default.")
#
# Usage:
#   scripts/build-local.sh [single|multi]
#
# Environment overrides:
#   CONTAINER_ENGINE  Container engine to build with: `docker` (default) or
#                     `podman`. Both accept the same `buildx build` subcommand
#                     with `--build-arg` / `--target` / `--platform`. The one
#                     difference the script handles automatically: Docker needs
#                     `--load` to place a single-platform build into the local
#                     image store, while Podman has no `--load` flag (it builds
#                     directly into its store), so `--load` is added for Docker
#                     only.
#                     CAVEAT: this Dockerfile uses BuildKit heredoc `RUN <<EOF`
#                     blocks (install step + verify gate). Docker builds with
#                     BuildKit and parses them; Podman builds with buildah, which
#                     does NOT, and fails with `Unknown instruction: "SET"`.
#                     Podman does NOT use BuildKit and cannot be configured to
#                     (`podman buildx` is only a buildah alias), so there is
#                     nothing to enable inside Podman. Build with Docker and run
#                     with Podman, or use a separate BuildKit toolchain
#                     (buildkitd/buildctl, nerdctl). See docs/building.md
#                     ("Building with Podman").
#   BUILD_CONFIG_JSON  Path to the package.json holding the containerImage
#                      Build_Config. Defaults to the repo-root ./package.json.
#   IMAGE_TAG      Image reference/tag for the build (default: iobroker:local).
#   BUILD_TARGET   Dockerfile stage to build and load (default: `runtime`, the
#                  shippable rootless image). Override to build a specific stage;
#                  when overridden away from `runtime` the separate verify gate
#                  is skipped (you are targeting a stage on purpose).
#   RUN_VERIFY_GATE  When "true" (default), also run the `verify` gate as a
#                    separate non-loaded build so the dependency gate fires
#                    locally. Set "false" for a fast inner-loop rebuild.
#   VERIFY_TARGET  Name of the verification gate stage (default: `verify`).
#   PLATFORMS      Override the multi-arch platform list
#                  (default: linux/amd64,linux/arm64).
#   DEBIAN_CODENAME  Override the Debian codename from the Build_Config (e.g.
#                    bookworm). When unset, the value is read from package.json.
#
# Exit codes:
#   0  build succeeded
#   1  a build knob could not be read, or a prerequisite/build step failed
set -euo pipefail

# --- Locate ourselves, the repo root and the sibling lib/ modules -----------
# Resolve this script's directory so lib/ and package.json resolve regardless
# of the working directory the caller runs us from (same approach as the other
# scripts under scripts/).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

# --- Configuration (all overridable via the environment) --------------------
MODE="${1:-single}"
# Container engine: docker (default) or podman. Both expose a Docker-compatible
# `buildx build` CLI, so the assembled arguments are shared; the only engine
# difference (Docker's `--load` vs. Podman having no such flag) is handled where
# the per-mode arguments are added below.
CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"
IMAGE_TAG="${IMAGE_TAG:-iobroker:local}"
# Default target is the shippable `runtime` stage — the rootless (USER 1000)
# image you actually run. The runtime-dependency verification gate (`verify`
# stage) is still run on every build, but as a SEPARATE non-loaded build (see
# below), so a local build both loads a runnable image AND runs the same gate CI
# runs. Loading the `verify` stage itself is wrong: it ends on `USER root` and
# is a build-time assertion, not something you want in your image store.
# Override BUILD_TARGET to build a specific stage instead.
BUILD_TARGET="${BUILD_TARGET:-runtime}"
# The verification gate stage. Run before/alongside the loadable build so the
# dependency gate still fires locally. Set RUN_VERIFY_GATE=false to skip it
# (e.g. for a fast inner-loop rebuild). Ignored when BUILD_TARGET is overridden
# to something other than `runtime`, since the caller is then targeting a
# specific stage on purpose.
VERIFY_TARGET="${VERIFY_TARGET:-verify}"
RUN_VERIFY_GATE="${RUN_VERIFY_GATE:-true}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"

# Source of the build knobs: the maintainer-owned Build_Config in package.json
# (`containerImage`). NODE_MAJOR (from nodeMajor) and DEBIAN_CODENAME (from
# debianCodename) are read from here, the same way CI does.
BUILD_CONFIG_JSON="${BUILD_CONFIG_JSON:-${REPO_ROOT}/package.json}"

# --- Prerequisite checks ----------------------------------------------------
case "${CONTAINER_ENGINE}" in
  docker|podman) ;;
  *)
    echo "build-local: unknown CONTAINER_ENGINE '${CONTAINER_ENGINE}' (expected 'docker' or 'podman')." >&2
    exit 1
    ;;
esac
if ! command -v "${CONTAINER_ENGINE}" >/dev/null 2>&1; then
  echo "build-local: '${CONTAINER_ENGINE}' not found on PATH." >&2
  exit 1
fi
if ! "${CONTAINER_ENGINE}" buildx version >/dev/null 2>&1; then
  echo "build-local: '${CONTAINER_ENGINE} buildx' is not available; install/enable Buildx (Docker) or a recent Podman." >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "build-local: 'node' not found on PATH; required to read the Build_Config." >&2
  exit 1
fi

if [[ ! -f "${BUILD_CONFIG_JSON}" ]]; then
  echo "build-local: package.json not found at '${BUILD_CONFIG_JSON}'." >&2
  echo "  Local builds read NODE_MAJOR (nodeMajor) and DEBIAN_CODENAME" >&2
  echo "  (debianCodename) from the 'containerImage' key of package.json, the" >&2
  echo "  same way CI does. Run from the repo root or set BUILD_CONFIG_JSON." >&2
  exit 1
fi

# --- Read the build knobs using the SAME pure modules as the code -----------
# We reuse lib/build-config.js (readPackageJson/readDebianCodename) +
# lib/node-major.js (deriveNodeMajorFromPackageJson) so the local read is
# byte-for-byte the same logic CI uses. deriveNodeMajorFromPackageJson throws
# (non-zero exit) on any missing/empty/whitespace/non-integer nodeMajor —
# fail-fast, no fallback.
BUILD_CONFIG_MODULE="${REPO_ROOT}/lib/build-config.js"
NODE_MAJOR_MODULE="${REPO_ROOT}/lib/node-major.js"

if ! NODE_MAJOR="$(
  IOB_BUILD_CONFIG_PATH="${BUILD_CONFIG_JSON}" \
  node --input-type=module -e "
    import { readPackageJson } from '${BUILD_CONFIG_MODULE}';
    import { deriveNodeMajorFromPackageJson } from '${NODE_MAJOR_MODULE}';
    const pkg = readPackageJson(process.env.IOB_BUILD_CONFIG_PATH);
    process.stdout.write(String(deriveNodeMajorFromPackageJson(pkg)));
  " 2>/tmp/build-local-node-major.err
)"; then
  echo "build-local: failed to read NODE_MAJOR from '${BUILD_CONFIG_JSON}':" >&2
  cat /tmp/build-local-node-major.err >&2 || true
  rm -f /tmp/build-local-node-major.err
  exit 1
fi
rm -f /tmp/build-local-node-major.err

echo "build-local: read NODE_MAJOR=${NODE_MAJOR} from ${BUILD_CONFIG_JSON} (containerImage.nodeMajor)" >&2

# Debian codename: an explicit DEBIAN_CODENAME env override wins; otherwise read
# it from the Build_Config debianCodename field. Fail fast if it is missing or
# empty in the Build_Config and no override was given. (Req 5.7)
if [[ -z "${DEBIAN_CODENAME:-}" ]]; then
  if ! DEBIAN_CODENAME="$(
    IOB_BUILD_CONFIG_PATH="${BUILD_CONFIG_JSON}" \
    node --input-type=module -e "
      import { readPackageJson, readDebianCodename } from '${BUILD_CONFIG_MODULE}';
      const pkg = readPackageJson(process.env.IOB_BUILD_CONFIG_PATH);
      const c = readDebianCodename(pkg);
      if (typeof c !== 'string' || c.trim().length === 0) {
        console.error('Build_Config field \`debianCodename\` is missing or empty in package.json containerImage.');
        process.exit(1);
      }
      process.stdout.write(c.trim());
    " 2>/tmp/build-local-codename.err
  )"; then
    echo "build-local: failed to read DEBIAN_CODENAME from '${BUILD_CONFIG_JSON}':" >&2
    cat /tmp/build-local-codename.err >&2 || true
    rm -f /tmp/build-local-codename.err
    exit 1
  fi
  rm -f /tmp/build-local-codename.err
  echo "build-local: read DEBIAN_CODENAME=${DEBIAN_CODENAME} from ${BUILD_CONFIG_JSON} (containerImage.debianCodename)" >&2
else
  echo "build-local: using DEBIAN_CODENAME=${DEBIAN_CODENAME} from environment override" >&2
fi

# --- Resolve the build target stage -----------------------------------------
# The default target is the shippable `runtime` stage (the runnable rootless
# image). The verification gate runs separately (see run_verify_gate below). If
# the caller overrode BUILD_TARGET to a stage that does not exist in the
# Dockerfile, fall back to `runtime` with a warning so the build still produces
# a usable image rather than failing on an unknown stage.
if [[ -n "${BUILD_TARGET}" ]] \
  && ! grep -Eq "^[[:space:]]*FROM[[:space:]].+[[:space:]]+[Aa][Ss][[:space:]]+${BUILD_TARGET}([[:space:]]|$)" \
      "${REPO_ROOT}/Dockerfile"; then
  echo "build-local: WARNING target stage '${BUILD_TARGET}' not found in Dockerfile;" \
    "falling back to 'runtime'." >&2
  BUILD_TARGET="runtime"
fi

echo "build-local: engine=${CONTAINER_ENGINE}, mode=${MODE}, target=${BUILD_TARGET}, tag=${IMAGE_TAG}, debian=${DEBIAN_CODENAME}" >&2

# --- Run the runtime-dependency verification gate ---------------------------
# The loadable/validation build below targets the shippable stage (default
# `runtime`). The verification gate is a SEPARATE build of the `verify` stage
# that runs the dependency assertions during the build (its checks live in a
# `RUN`), so a local build fires the SAME gate CI runs. We do NOT `--load` it
# (it ends on `USER root` and is a build-time assertion, not a runnable image)
# and never `--push`. BuildKit reuses the `runtime` layers, so this is cheap.
#
# Skipped when: the caller opted out (RUN_VERIFY_GATE=false), the caller
# overrode BUILD_TARGET to something other than `runtime` (they are targeting a
# specific stage on purpose), or the Dockerfile has no `verify` stage.
run_verify_gate() {
  [[ "${RUN_VERIFY_GATE}" == "true" ]] || { echo "build-local: verification gate skipped (RUN_VERIFY_GATE=false)." >&2; return 0; }
  [[ "${BUILD_TARGET}" == "runtime" ]] || { echo "build-local: verification gate skipped (BUILD_TARGET overridden to '${BUILD_TARGET}')." >&2; return 0; }
  if ! grep -Eq "^[[:space:]]*FROM[[:space:]].+[[:space:]]+[Aa][Ss][[:space:]]+${VERIFY_TARGET}([[:space:]]|$)" \
      "${REPO_ROOT}/Dockerfile"; then
    echo "build-local: verification gate stage '${VERIFY_TARGET}' not found in Dockerfile; skipping gate." >&2
    return 0
  fi

  # Build the gate for the same platform(s) as the main build so the gate runs
  # per target architecture, matching CI. No --load, no --push.
  local gate_args=(
    buildx build
    -f "${REPO_ROOT}/Dockerfile"
    --build-arg "NODE_MAJOR=${NODE_MAJOR}"
    --build-arg "DEBIAN_CODENAME=${DEBIAN_CODENAME}"
    --target "${VERIFY_TARGET}"
  )
  if [[ "${MODE}" == "multi" ]]; then
    gate_args+=(--platform "${PLATFORMS}")
  fi
  gate_args+=("${REPO_ROOT}")

  echo "build-local: running verification gate: ${CONTAINER_ENGINE} ${gate_args[*]}" >&2
  "${CONTAINER_ENGINE}" "${gate_args[@]}"
}

run_verify_gate

# --- Assemble the buildx command --------------------------------------------
# Common arguments shared by both modes and both engines: same Dockerfile, same
# build args, same target stage as CI. No --push in either mode. Docker and
# Podman both accept this `buildx build` subcommand with these flags.
build_args=(
  buildx build
  -f "${REPO_ROOT}/Dockerfile"
  --build-arg "NODE_MAJOR=${NODE_MAJOR}"
  --build-arg "DEBIAN_CODENAME=${DEBIAN_CODENAME}"
  --target "${BUILD_TARGET}"
  -t "${IMAGE_TAG}"
)

case "${MODE}" in
  single)
    # Local host platform. No platform override: buildx builds for the host
    # platform by default. Docker needs `--load` to place the single-platform
    # result into the local image store; Podman has NO `--load` flag (it builds
    # directly into its store), so `--load` would be rejected as unknown — add
    # it for Docker only.
    if [[ "${CONTAINER_ENGINE}" == "docker" ]]; then
      build_args+=(--load)
    fi
    ;;
  multi)
    # Multi-arch validation build. buildx cannot --load a multi-platform image
    # into the docker store, so we neither --load nor --push: this validates
    # both architectures (and the gate on each) without producing a local image
    # and without publishing.
    build_args+=(--platform "${PLATFORMS}")
    ;;
  *)
    echo "build-local: unknown mode '${MODE}' (expected 'single' or 'multi')." >&2
    exit 1
    ;;
esac

# The build context is the repo root.
build_args+=("${REPO_ROOT}")

echo "build-local: running: ${CONTAINER_ENGINE} ${build_args[*]}" >&2
exec "${CONTAINER_ENGINE}" "${build_args[@]}"

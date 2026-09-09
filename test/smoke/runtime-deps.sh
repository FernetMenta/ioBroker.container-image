#!/usr/bin/env bash
# runtime-deps.sh - runtime-dependency and packaging smoke test (task 19.2).
#
# This is an INTEGRATION / SMOKE test that runs against a BUILT image via
# `docker run`. It mirrors the in-Dockerfile runtime-dependency verification
# gate (Dockerfile `verify` stage, task 15.1) but asserts against the SHIPPED
# `runtime` image rather than the build-time `verify` stage. Where the gate
# fails a per-arch build (blocking publish), this test validates the artifact
# an operator actually pulls and runs.
#
# Checks (each run INSIDE the container via `docker run --rm --entrypoint ...`):
#   (1) runtime OS packages + runtime shared-library packages PRESENT
#       (dpkg -s)                                          (Req 2.6, 5.2)
#   (2) build toolchain / -dev header packages ABSENT
#       (dpkg -s must fail)                                (Req 2.3, 5.3)
#   (3) ldd over every compiled native .node file under
#       /opt/iobroker/node_modules shows no "not found"    (Req 2.6)
#   (4) js-controller / `iobroker status` smoke start does not fail due to a
#       MISSING RUNTIME DEPENDENCY                          (Req 2.6)
#   (5) getcap on the resolved node binary reports NO file capabilities
#       (node is intentionally not setcap'd so it can exec fully rootless)
#                                                           (Req 7.1)
#
# Parameterization:
#   IMAGE           Image reference to test (default: iobroker:local).
#   DOCKER          Container CLI to use (default: docker; e.g. `podman`).
#
# Skip-with-clear-message behavior:
#   The test SKIPS (exit 0, non-fatal) when the container CLI is not available
#   or when the target IMAGE is not present locally. This keeps the test suite
#   green on machines that cannot build/pull the image, while still failing
#   loudly on a real runtime-dependency regression when the image IS present.
#
# Exit codes:
#   0  all checks passed OR the test was skipped (docker/image unavailable)
#   1  one or more runtime-dependency / packaging checks FAILED
set -u
set -o pipefail

# --- Configuration (overridable via the environment) ------------------------
IMAGE="${IMAGE:-iobroker:local}"
DOCKER="${DOCKER:-docker}"
IOB_DIR="${IOB_DIR:-/opt/iobroker}"

SKIP_PREFIX="runtime-deps: SKIP:"
FAIL_PREFIX="runtime-deps: FAIL:"

# --- Skip guards ------------------------------------------------------------
# No container CLI -> skip with a clear message (not a failure).
if ! command -v "${DOCKER}" >/dev/null 2>&1; then
  echo "${SKIP_PREFIX} '${DOCKER}' not found on PATH; cannot run the image. Skipping runtime-dependency smoke test." >&2
  exit 0
fi

# The daemon must be reachable; `docker info` fails fast if it is not.
if ! "${DOCKER}" info >/dev/null 2>&1; then
  echo "${SKIP_PREFIX} '${DOCKER}' is installed but the engine is not reachable (is the daemon running?). Skipping runtime-dependency smoke test." >&2
  exit 0
fi

# The target image must exist locally. We do NOT pull here: this test validates
# a locally BUILT image (scripts/build-local.sh) or one the caller already
# pulled. If it is absent, skip with guidance rather than fail.
if ! "${DOCKER}" image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "${SKIP_PREFIX} image '${IMAGE}' not found locally. Build it first (e.g. 'IMAGE_TAG=${IMAGE} scripts/build-local.sh single') or set IMAGE=<ref>. Skipping runtime-dependency smoke test." >&2
  exit 0
fi

echo "=== runtime-dependency & packaging smoke test (image: ${IMAGE}) ==="

# --- Helper: run a shell snippet inside the image ---------------------------
# We override the entrypoint (the image's ENTRYPOINT is tini + the ioBroker
# pipeline) with /bin/sh and pass the snippet via `-c`, so each check runs a
# plain shell inside a throwaway container. IOB_DIR is exported into the
# container environment so the in-container snippets can read it.
run_in_container() {
  # shellcheck disable=SC2086
  "${DOCKER}" run --rm \
    --entrypoint /bin/sh \
    -e "IOB_DIR=${IOB_DIR}" \
    "${IMAGE}" -c "$1"
}

overall_fail=""

# --- (1) Runtime packages that MUST be present (Req 2.6, 5.2) ---------------
# Runtime OS packages + the runtime shared-library packages installed in the
# runtime stage. Each must be queryable as installed via `dpkg -s`. The
# in-container script builds its own failure list and exits non-zero if any are
# missing, so a missing package surfaces as this check failing.
echo "--- [1/5] asserting runtime packages are PRESENT (dpkg -s) ---"
present_check='
set -u
missing=""
for pkg in \
    acl sudo libcap2-bin git curl unzip distro-info net-tools polkitd passwd \
    lsb-release ca-certificates libcairo2 libpango-1.0-0 librsvg2-2 libpixman-1-0 \
    libjpeg62-turbo libgif7 libudev1 libpam0g libavahi-compat-libdnssd1
do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo "  present: $pkg"
    else
        echo "  MISSING runtime package: $pkg" >&2
        missing="${missing} ${pkg}"
    fi
done
[ -z "$missing" ] || { echo "  runtime packages missing:${missing}" >&2; exit 1; }
'
if run_in_container "${present_check}"; then
  echo "  [1/5] PASS: all runtime packages present"
else
  echo "${FAIL_PREFIX} [1/5] one or more runtime packages missing (Req 2.6, 5.2)" >&2
  overall_fail="${overall_fail} runtime-packages-missing"
fi

# --- (2) Toolchain / -dev headers that MUST be ABSENT (Req 2.3, 5.3) ---------
# These live only in the Build_Stage and must never reach the runtime image.
# `dpkg -s` MUST fail for each; if it succeeds, the package leaked in and the
# in-container script exits non-zero listing the offenders.
echo "--- [2/5] asserting toolchain / -dev packages are ABSENT (dpkg -s must fail) ---"
absent_check='
set -u
leaked=""
for pkg in \
    build-essential gcc make cmake pkg-config \
    libavahi-compat-libdnssd-dev libudev-dev libpam0g-dev libcairo2-dev \
    libpango1.0-dev libjpeg-dev libgif-dev librsvg2-dev libpixman-1-dev
do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo "  LEAKED build-only package present in runtime image: $pkg" >&2
        leaked="${leaked} ${pkg}"
    else
        echo "  absent (ok): $pkg"
    fi
done
[ -z "$leaked" ] || { echo "  leaked build-only packages:${leaked}" >&2; exit 1; }
'
if run_in_container "${absent_check}"; then
  echo "  [2/5] PASS: no build toolchain / -dev packages present"
else
  echo "${FAIL_PREFIX} [2/5] build-only toolchain / -dev package(s) leaked into runtime image (Req 2.3, 5.3)" >&2
  overall_fail="${overall_fail} toolchain-leaked"
fi

# --- (3) ldd over compiled native .node files (Req 2.6) ----------------------
# Every native addon compiled in the Build_Stage must resolve all of its
# shared-object dependencies against the runtime image's libraries. Any
# "not found" line from `ldd` means a runtime shared lib is missing.
echo "--- [3/5] resolving shared libs of compiled native .node files (ldd) ---"
#
# False-positive guard (kept consistent with the Dockerfile verify gate, task
# 15.1): some npm packages (e.g. @serialport/bindings-cpp) ship PREBUILT .node
# binaries for many platform/libc combinations under a prebuilds/ directory,
# e.g. .../prebuilds/linux-x64/node.napi.musl.node (musl/Alpine) alongside
# .../prebuilds/linux-x64/node.napi.glibc.node. On this Debian/glibc image the
# musl variant links libc.musl-* which is CORRECTLY absent and NEVER loaded, and
# a prebuilds/ dir also carries OTHER-arch variants this build never loads.
# ldd-ing those non-matching prebuilds yields bogus "not found" lines. So we
# skip prebuilds/ variants that don't match this image's libc/arch and check
# everything else, keeping the check STRICT for genuinely missing glibc deps.
ldd_check='
set -u
fail=""
node_count=0
skipped_count=0

uname_m="$(uname -m)"
case "$uname_m" in
    x86_64)          prebuild_arch="x64" ;;
    aarch64|arm64)   prebuild_arch="arm64" ;;
    armv7l|armv6l)   prebuild_arch="arm" ;;
    i386|i486|i586|i686) prebuild_arch="ia32" ;;
    ppc64le)         prebuild_arch="ppc64" ;;
    s390x)           prebuild_arch="s390x" ;;
    riscv64)         prebuild_arch="riscv64" ;;
    *)               prebuild_arch="$uname_m" ;;
esac
echo "  image libc: glibc; image arch token: ${prebuild_arch} (uname -m: ${uname_m})"

for nodefile in $(find "${IOB_DIR}/node_modules" -type f -name "*.node" 2>/dev/null)
do
    [ -n "$nodefile" ] || continue

    # Only prebuilds/ files are eligible for skipping; compiled bindings are
    # always checked.
    case "$nodefile" in
        */prebuilds/*)
            # (a) Skip non-glibc (musl) prebuilds: never loaded on this glibc image.
            case "$nodefile" in
                *musl*)
                    echo "  skip (musl prebuild, not loaded on glibc image): $nodefile"
                    skipped_count=$((skipped_count + 1))
                    continue
                    ;;
            esac
            # (b) Skip prebuilds targeting a different CPU arch than this build.
            arch_seg="$(printf "%s\n" "$nodefile" | grep -Eo "linux-[A-Za-z0-9]+" | head -n1)"
            if [ -n "$arch_seg" ] && [ "$arch_seg" != "linux-${prebuild_arch}" ]; then
                echo "  skip (${arch_seg} prebuild, not this image arch linux-${prebuild_arch}): $nodefile"
                skipped_count=$((skipped_count + 1))
                continue
            fi
            ;;
    esac

    node_count=$((node_count + 1))
    missing="$(ldd "$nodefile" 2>/dev/null | grep "not found" || true)"
    if [ -n "$missing" ]; then
        echo "  UNRESOLVED shared libs in: $nodefile" >&2
        echo "$missing" | sed "s/^/    /" >&2
        fail="${fail} ${nodefile}"
    fi
done
echo "  scanned ${node_count} compiled .node file(s); skipped ${skipped_count} non-matching prebuild(s)"
[ -z "$fail" ] || { echo "  files with unresolved shared libs:${fail}" >&2; exit 1; }
'
if run_in_container "${ldd_check}"; then
  echo "  [3/5] PASS: all compiled .node files resolve their shared libraries"
else
  echo "${FAIL_PREFIX} [3/5] one or more native .node files have unresolved shared libraries (Req 2.6)" >&2
  overall_fail="${overall_fail} unresolved-shared-libs"
fi

# --- (4) js-controller / iobroker status smoke start (Req 2.6) ---------------
# Invoke the iobroker status command and confirm it does not fail due to a
# MISSING RUNTIME DEPENDENCY. `iobroker status` may legitimately report a
# non-zero exit here (no objects/states DB is running), so we do NOT treat a
# plain non-zero exit as a failure. We DO fail if the CLI is missing/not
# executable, or the attempt surfaces a missing shared library or a
# "cannot find module" native-binding error.
echo "--- [4/5] js-controller / iobroker status smoke start ---"
smoke_check='
set -u
IOB_CLI="${IOB_DIR}/iobroker"
if [ ! -x "$IOB_CLI" ] && command -v iobroker >/dev/null 2>&1; then
    IOB_CLI="$(command -v iobroker)"
fi
if [ ! -x "$IOB_CLI" ]; then
    echo "  MISSING runtime dependency: iobroker CLI not found/executable (looked at ${IOB_DIR}/iobroker and PATH)" >&2
    exit 1
fi
smoke_out="$( ( cd "${IOB_DIR}" && "$IOB_CLI" status ) 2>&1 || true )"
echo "$smoke_out" | sed "s/^/    /"
if echo "$smoke_out" | grep -Eqi "error while loading shared libraries|cannot open shared object file|Cannot find module|invalid ELF header|GLIBC_"; then
    offender="$(echo "$smoke_out" | grep -Eoi "error while loading shared libraries.*|cannot open shared object file.*|Cannot find module.*|GLIBC_.*" | head -n1)"
    echo "  SMOKE START failed due to missing runtime dependency: ${offender}" >&2
    exit 1
fi
echo "  smoke start resolved its runtime dependencies (status exit code is not gated here)"
'
if run_in_container "${smoke_check}"; then
  echo "  [4/5] PASS: iobroker status smoke start resolved its runtime dependencies"
else
  echo "${FAIL_PREFIX} [4/5] iobroker status smoke start failed due to a missing runtime dependency (Req 2.6)" >&2
  overall_fail="${overall_fail} smoke-start-missing-dependency"
fi

# --- (5) getcap on the resolved node binary (Req 7.1) ------------------------
# The Node binary must carry NO file capabilities. The image intentionally does
# NOT `setcap` node: a file capability with the effective bit (`+ep`) makes the
# kernel refuse to `exec` node in a fully-rootless container (e.g. rootless
# Podman with no allowed caps), which would prevent the container from starting.
# `which node` is typically a symlink, so resolve it with `readlink -f` before
# querying with getcap, and assert that NEITHER cap_net_bind_service NOR
# cap_net_raw (nor any other capability) is present. Privileged ports / raw
# sockets are handled at the runtime layer instead (see
# docs/rootless-capabilities.md).
echo "--- [5/5] getcap on the resolved node binary (must be empty) ---"
getcap_check='
set -u
NODE_BIN="$(readlink -f "$(command -v node)" 2>/dev/null || true)"
if [ -z "$NODE_BIN" ] || [ ! -e "$NODE_BIN" ]; then
    echo "  could not resolve the node binary" >&2
    exit 1
fi
caps="$(getcap "$NODE_BIN" 2>/dev/null || true)"
echo "  node binary: $NODE_BIN"
echo "  getcap: ${caps:-<none>}"
unexpected=""
echo "$caps" | grep -q "cap_net_bind_service" && unexpected="${unexpected} cap_net_bind_service"
echo "$caps" | grep -q "cap_net_raw"          && unexpected="${unexpected} cap_net_raw"
# Any non-empty getcap output at all means a file capability is set.
[ -z "$(printf "%s" "$caps" | tr -d "[:space:]")" ] || unexpected="${unexpected} (getcap-nonempty)"
[ -z "$unexpected" ] || { echo "  UNEXPECTED file capabilities on node binary:${unexpected}" >&2; exit 1; }
echo "  node binary carries no file capabilities (as required for rootless exec)"
'
if run_in_container "${getcap_check}"; then
  echo "  [5/5] PASS: node binary carries no file capabilities"
else
  echo "${FAIL_PREFIX} [5/5] node binary unexpectedly carries file capabilities (Req 7.1)" >&2
  overall_fail="${overall_fail} node-capabilities-present"
fi

# --- Verdict -----------------------------------------------------------------
if [ -n "${overall_fail}" ]; then
  echo "=== runtime-dependency smoke test FAILED ===" >&2
  echo "Failing checks:" >&2
  for item in ${overall_fail}; do echo "  - ${item}" >&2; done
  exit 1
fi
echo "=== runtime-dependency smoke test PASSED: all runtime dependencies resolved ==="
exit 0

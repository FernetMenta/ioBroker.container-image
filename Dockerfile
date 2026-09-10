# syntax=docker/dockerfile:1
#
# Rootless, multi-architecture ioBroker container image.
#
# Multi-stage build: Build_Stage -> Runtime_Image. The Runtime_Image is derived
# exclusively from the final stage so the compiler toolchain and -dev headers
# used only during the Build_Stage never reach the shipped image. (Req 2.2, 2.3)
#
# The Debian release is selected by the DEBIAN_CODENAME build arg (default
# trixie); both stages share it. NODE_MAJOR and DEBIAN_CODENAME are read from
# the maintainer-owned Build_Config in package.json (the `containerImage` key:
# `nodeMajor` + `debianCodename`; see lib/build-config.js + lib/node-major.js)
# and supplied by CI / the local build path as build args, with fail-fast
# behavior before any build begins. (Req 5.4, 5.5, 5.7)

# =============================================================================
# Build_Stage (task 14.1)
# =============================================================================
# Full (non-slim) Node.js base for the build stage: `node:${NODE_MAJOR}-
# ${DEBIAN_CODENAME}`. It ships the same Debian release and glibc as the slim
# runtime base below, so native modules compiled here stay binary-compatible
# when copied forward into the Runtime_Image. NODE_MAJOR and DEBIAN_CODENAME
# are the global build args declared above (default codename: trixie, the
# current Debian stable). (Req 2.1, 2.2)
# Global build args (declared before the first FROM so they can parameterize
# the base image tags). NODE_MAJOR and DEBIAN_CODENAME are read from the
# package.json `containerImage` Build_Config by CI / the local build path;
# DEBIAN_CODENAME selects the Debian release both stages
# share (build + runtime MUST use the same codename so the glibc/ABI matches
# and natively compiled modules stay binary-compatible). Default: trixie
# (current Debian stable). Override with --build-arg DEBIAN_CODENAME=bookworm
# to fall back to oldstable. (Req 2.1, 2.2)
ARG NODE_MAJOR
ARG DEBIAN_CODENAME=trixie

FROM node:${NODE_MAJOR}-${DEBIAN_CODENAME} AS build

# Node.js major version, read from the package.json `containerImage.nodeMajor`
# Build_Config and passed in by CI / the local build path. It selects the Node
# major used to compile the native node_modules so the compiled ABI matches the
# intended runtime. (Req 5.4)
ARG NODE_MAJOR

# ioBroker installs under /opt/iobroker inside the image. (Req 8.1)
ARG IOB_DIR=/opt/iobroker

# js-controller version to install. Defaults to the `stable` npm dist-tag (the
# normal, shipped behavior). Override with a concrete version (e.g.
# `--build-arg JS_CONTROLLER_VERSION=6.0.11`) or any npm range/dist-tag to build
# an image pinned to a specific js-controller — used for upgrade/downgrade
# testing (build an old-version image, start it with a persisted Data_Volume,
# then swap to a newer image and confirm the upgrade path on start).
ARG JS_CONTROLLER_VERSION=stable

# Promote the build args to ENV so they are visible to the shell inside the
# BuildKit heredoc install step below. Docker does NOT expand Dockerfile ARG
# references inside a single-quoted (`<<'EOF'`) heredoc body, so the install
# step reads them as normal environment variables at runtime instead. NODE_MAJOR
# is only set here if the build arg was supplied (the fail-fast guard below
# still rejects an empty/invalid value before any install). (Req 5.4)
ENV IOB_DIR=${IOB_DIR}
ENV NODE_MAJOR=${NODE_MAJOR}
ENV JS_CONTROLLER_VERSION=${JS_CONTROLLER_VERSION}

# Non-interactive apt for reproducible builds.
ENV DEBIAN_FRONTEND=noninteractive

# Fail fast if NODE_MAJOR was not supplied. The value must be an integer major
# version (validated upstream by lib/node-major.js against the package.json
# `containerImage.nodeMajor` Build_Config); this guard prevents an accidental
# build without it and never falls back to a system default. (Req 5.4, 5.5)
RUN set -eu; \
    if [ -z "${NODE_MAJOR:-}" ]; then \
        echo "ERROR: NODE_MAJOR build-arg is required (read from package.json containerImage.nodeMajor); refusing to build without it." >&2; \
        exit 1; \
    fi; \
    case "${NODE_MAJOR}" in \
        ''|*[!0-9]*) \
            echo "ERROR: NODE_MAJOR must be an integer major version, got '${NODE_MAJOR}'." >&2; \
            exit 1; \
            ;; \
    esac; \
    echo "Building ioBroker native modules against Node.js major ${NODE_MAJOR} (image node --version: $(node --version))."

# Build toolchain + development header packages required to compile ioBroker's
# native node_modules. Installed WITHOUT version pinning, with
# --no-install-recommends, and with the apt lists cleaned afterwards to keep the
# stage lean. These -dev/compiler packages live ONLY in the Build_Stage and are
# never copied into the Runtime_Image. (Req 5.1, 5.6, 2.3)
RUN set -eux; \
    apt-get update; \
    apt-get install --no-install-recommends -y \
        build-essential \
        gcc \
        make \
        cmake \
        pkg-config \
        libavahi-compat-libdnssd-dev \
        libudev-dev \
        libpam0g-dev \
        libcairo2-dev \
        libpango1.0-dev \
        libjpeg-dev \
        libgif-dev \
        librsvg2-dev \
        libpixman-1-dev; \
    rm -rf /var/lib/apt/lists/*

# Present a container indicator so ioBroker's container detection takes its
# containerized branch during this build (ioBroker detects containers via
# /.dockerenv). The Runtime_Image lays down its own /.dockerenv and
# /run/.containerenv in a later task; this build-stage copy only influences
# behavior here and is not part of the shipped image. (Req 6.2)
RUN touch /.dockerenv

WORKDIR ${IOB_DIR}

# Install ioBroker under /opt/iobroker in a container-appropriate way.
#
# We deliberately do NOT run the public https://iobroker.net/install.sh here.
# That installer is designed for full-host installs: it creates an `iobroker`
# OS user, writes /etc/sudoers.d entries, installs a systemd/init.d autostart
# service, symlinks CLIs into /usr/bin, adds Node.js apt repositories, and runs
# `iob fix`-style host tweaks — none of which belong in an image Build_Stage and
# several of which fail or are meaningless without systemd/apt-managed Node.
#
# The only part of that installer that matters for an image is its core install
# step: write a package.json pinning the js-controller + the default adapter set
# to the `stable` npm dist-tag and `npm install` it under /opt/iobroker, which
# compiles the native node_modules. We reproduce exactly that here.
#
# On the `unsafe-perm` question (the previous step used the now-removed
# `npm config set unsafe-perm true`, invalid on npm v9+/the npm 10/11 shipped by
# node:22): npm still drops privileges for lifecycle scripts ONLY when it runs
# as root/uid 0. This RUN executes as root, so native-module build scripts
# (node-gyp) would otherwise run as `nobody` and fail to write into the
# root-owned /opt/iobroker. We restore the root-build behavior with the
# still-supported `npm_config_unsafe_perm=true` environment variable (the
# supported replacement for the removed config key / the `--unsafe-perm` flag),
# scoped to this build step only.
#
# NODE_MAJOR is exported for parity with the intended Node major; the base image
# is node:${NODE_MAJOR}-${DEBIAN_CODENAME}, so the toolchain compiles native modules
# against that exact Node ABI. (Req 2.2, 5.4)
#
# The .npmrc written here mirrors the settings the ioBroker installer relies on
# (audit=false, update-notifier=false, engine-strict=true; the runtime
# ensure-npmrc.sh re-asserts these). (Req 5.1)
RUN <<'INSTALL'
set -eux
export NODE_MAJOR="${NODE_MAJOR}"
export npm_config_unsafe_perm=true

# npm settings the ioBroker install relies on (mirrors installer_library).
cat > "${IOB_DIR}/.npmrc" <<'NPMRC'
# ioBroker install-time npm settings (mirrors installer_library).
audit=false
update-notifier=false
engine-strict=true
NPMRC

# ioBroker's install manifest: pin ONLY the js-controller. Its version comes
# from JS_CONTROLLER_VERSION (default `stable`), promoted to an env var above so
# it is readable inside this single-quoted heredoc step. No adapters are bundled
# — the Data_Volume is the source of truth and reconciliation installs adapters
# from the registry at runtime, so bundling them here would be dead weight (see
# design: Bundled content policy). The version string is embedded via an
# UNQUOTED heredoc delimiter so ${JS_CONTROLLER_VERSION} expands; it is our own
# controlled build arg, not untrusted input.
: "${JS_CONTROLLER_VERSION:=stable}"
echo "Pinning iobroker.js-controller to '${JS_CONTROLLER_VERSION}'."
cat > "${IOB_DIR}/package.json" <<PKGJSON
{
  "name": "iobroker.inst",
  "version": "3.0.0",
  "private": true,
  "description": "Automate your Life",
  "engines": {
    "node": ">=18.0.0"
  },
  "dependencies": {
    "iobroker.js-controller": "${JS_CONTROLLER_VERSION}"
  }
}
PKGJSON

# Install + compile native node_modules against the base image's Node
# (node:${NODE_MAJOR}-${DEBIAN_CODENAME}). --omit=dev is the modern equivalent of the
# installer's `--production`; unsafe-perm (via the env var above) keeps
# node-gyp build scripts running as root so they can write into /opt/iobroker.
npm install --omit=dev --loglevel error

# Fail fast if the install did not lay down the expected artifacts: the
# controller entry point the entrypoint execs and the `iobroker` CLI the verify
# stage / healthcheck use.
test -f "${IOB_DIR}/node_modules/iobroker.js-controller/controller.js"
test -x "${IOB_DIR}/iobroker"

# Fail fast if the INSTALLED js-controller version does not match the version
# that was explicitly requested. This guards the release path: CI passes the
# `<version>` parsed from the git tag (e.g. `7.2.2`) as JS_CONTROLLER_VERSION,
# so an image tagged `7.2.2-r<n>` MUST actually contain js-controller 7.2.2. If
# npm resolved something else (a moved dist-tag, a typo'd tag, a yanked
# version), the build fails here instead of shipping a mislabeled image. The
# check is SKIPPED when the request is not an exact version — `stable`/`latest`
# dist-tags or an npm range (^/~/x/*, etc.) legitimately resolve to whatever npm
# picks (the normal non-release build path), so there is nothing to assert.
case "${JS_CONTROLLER_VERSION}" in
    *[!0-9.]* )
        echo "js-controller requested as '${JS_CONTROLLER_VERSION}' (dist-tag/range); skipping exact-version match check."
        ;;
    * )
        installed="$(node -p "require('${IOB_DIR}/node_modules/iobroker.js-controller/package.json').version")"
        if [ "${installed}" != "${JS_CONTROLLER_VERSION}" ]; then
            echo "ERROR: js-controller version mismatch: requested '${JS_CONTROLLER_VERSION}', installed '${installed}'. Refusing to build a mislabeled image." >&2
            exit 1
        fi
        echo "Verified installed js-controller version '${installed}' matches requested '${JS_CONTROLLER_VERSION}'."
        ;;
esac
INSTALL

# Ensure any native node_modules are (re)built against the selected Node major
# so the compiled ABI is correct before the artifacts are copied into the
# Runtime_Image. `npm rebuild` is a no-op when nothing needs rebuilding, keeping
# the step idempotent. (Req 2.2, 5.4)
RUN set -eux; \
    cd "${IOB_DIR}"; \
    if [ -f package.json ]; then \
        npm rebuild --build-from-source || npm rebuild; \
    fi

# Record the Node.js ABI the native node_modules were just compiled against, as
# a marker file INSIDE node_modules. The runtime reconciler
# (scripts/reconcile.sh -> abi_mismatch()) reads this file and compares it to
# the running Node's `process.versions.modules`; a difference (e.g. after an
# image upgrade that bumps the Node major, Node 22 -> 26) triggers an
# `npm rebuild` of the affected native modules. Writing it here — after the
# rebuild, inside node_modules — is what makes the marker (a) reflect the ABI
# the modules were actually built for, (b) travel forward via
# `COPY --from=build /opt/iobroker`, and (c) be seeded into a fresh named
# Modules_Volume alongside the modules it describes. Without this file the
# reconciler's abi_mismatch() short-circuits to "no mismatch" and the
# auto-rebuild never fires. (Req 8.12)
RUN set -eux; \
    cd "${IOB_DIR}"; \
    mkdir -p node_modules; \
    node -e 'process.stdout.write(String(process.versions.modules))' > node_modules/.node-abi; \
    test -s node_modules/.node-abi

# Drop the js-controller-initialized data directory before it is carried into
# the Runtime_Image. Installing `iobroker.js-controller` runs a lifecycle step
# that lays down a populated `iobroker-data/` (iobroker.json + objects.jsonl +
# states.jsonl). If that baked data reached the shipped image, runtime
# reconciliation would observe a NON-empty Data_Volume on first boot (even for a
# fresh named volume, which Docker seeds from the image directory) and SKIP the
# `iobroker setup first` + admin-adapter bootstrap. The result is a container
# with no admin instance and nothing listening on the Admin UI port. The
# Runtime_Image recreates an EMPTY iobroker-data with the correct 1000:0
# ownership/permissions, so removing it here is safe and is what makes the
# first-run bootstrap fire. (Req 8: empty Data_Volume => init default config +
# bootstrap admin)
RUN set -eux; \
    rm -rf "${IOB_DIR}/iobroker-data"

# The compiled ioBroker installation now lives at ${IOB_DIR} (/opt/iobroker) and
# is consumed by the Runtime_Image via `COPY --from=build`. (Req 2.2)

# =============================================================================
# Runtime_Image (task 14.2)
# =============================================================================
# Slim runtime base: `node:${NODE_MAJOR}-${DEBIAN_CODENAME}-slim`. This is the
# slim variant of the Build_Stage base (`node:${NODE_MAJOR}-${DEBIAN_CODENAME}`),
# using the SAME NODE_MAJOR and DEBIAN_CODENAME global build args, so both stages
# share the identical glibc/ABI and the native node_modules compiled in the
# Build_Stage stay binary-compatible when copied forward. (Req 2.1, 2.2)
FROM node:${NODE_MAJOR}-${DEBIAN_CODENAME}-slim AS runtime

# ioBroker install location; mirrors the Build_Stage so the COPY target matches.
# (Req 8.1)
ARG IOB_DIR=/opt/iobroker

# Re-declare the global build args inside the runtime stage so they are readable
# by the LABEL block below (ARGs declared before the first FROM parameterize the
# base image tag but are otherwise out of scope inside a stage). These record
# the Node major and Debian codename in OCI labels instead of the image tag, so
# the tag stays `<version>-r<n>` while node/os remain discoverable on the image.
ARG NODE_MAJOR
ARG DEBIAN_CODENAME=trixie

# Non-interactive apt for reproducible builds.
ENV DEBIAN_FRONTEND=noninteractive

# Runtime OS packages + runtime shared libraries only. Installed WITHOUT version
# pinning, with --no-install-recommends, and with apt lists cleaned afterwards to
# keep the image lean. This is the RUNTIME set: it deliberately EXCLUDES the
# compiler toolchain and every `-dev` header from the Build_Stage. Each shared
# library below is the runtime counterpart of a build-time `-dev` package, so
# the native modules compiled in the Build_Stage resolve their shared-object
# dependencies at runtime. (Req 2.3, 2.4, 5.2, 5.3, 5.6)
#
# Runtime OS packages:  acl, sudo, libcap2-bin, git, curl, ca-certificates,
#                       unzip, distro-info, net-tools, polkitd, passwd, lsb-release
# Runtime shared libs:  libcairo2 (libcairo2-dev), libpango-1.0-0 (libpango1.0-dev),
#                       librsvg2-2 (librsvg2-dev), libpixman-1-0 (libpixman-1-dev),
#                       libjpeg62-turbo (libjpeg-dev), libgif7 (libgif-dev),
#                       libudev1 (libudev-dev), libpam0g (libpam0g-dev),
#                       libavahi-compat-libdnssd1 (libavahi-compat-libdnssd-dev)
RUN set -eux; \
    apt-get update; \
    apt-get install --no-install-recommends -y \
        acl \
        sudo \
        libcap2-bin \
        git \
        curl \
        ca-certificates \
        unzip \
        distro-info \
        net-tools \
        polkitd \
        passwd \
        lsb-release \
        libcairo2 \
        libpango-1.0-0 \
        librsvg2-2 \
        libpixman-1-0 \
        libjpeg62-turbo \
        libgif7 \
        libudev1 \
        libpam0g \
        libavahi-compat-libdnssd1; \
    rm -rf /var/lib/apt/lists/*

# Bring the compiled ioBroker installation forward from the Build_Stage. Because
# the Runtime_Image derives ONLY from this stage, the Build_Stage toolchain and
# `-dev` headers never reach the shipped image. (Req 2.3, 2.4)
COPY --from=build /opt/iobroker ${IOB_DIR}

# Entrypoint pipeline scripts and their sibling `lib/` decision modules. The
# scripts resolve their modules via `${SCRIPT_DIR}/../lib`, so the scripts/ and
# lib/ directories MUST remain siblings. They are placed under /opt as
# /opt/scripts and /opt/lib to preserve that `../lib` relationship. (Req 6, 8)
COPY scripts/ /opt/scripts/
COPY lib/ /opt/lib/

# =============================================================================
# Runtime_Image capabilities / user model / metadata (task 14.3)
# =============================================================================

# Init_Process. tini is installed as the PID 1 init program that forwards
# signals to (and reaps zombies of) the Iobroker_Runtime. It is wired in via
# ENTRYPOINT below as `["/usr/bin/tini","--", ...]`. Installed without version
# pinning, --no-install-recommends, apt lists cleaned afterwards. (Req 14.1)
RUN set -eux; \
    apt-get update; \
    apt-get install --no-install-recommends -y tini; \
    rm -rf /var/lib/apt/lists/*; \
    test -x /usr/bin/tini

# Node binary file capabilities: intentionally NOT applied.
#
# Earlier revisions ran `setcap 'cap_net_bind_service,cap_net_raw+ep'` on the
# real node binary so that, when the runtime granted a matching capability,
# adapters binding privileged ports (<1024) or using raw sockets (ping) would
# work without extra in-container config. That is REMOVED because it is
# incompatible with the image's rootless-first goal:
#
#   A file capability with the EFFECTIVE bit set (`+ep`) makes the kernel REFUSE
#   to exec the binary when the capability is not in the process's permitted set
#   — which is exactly the fully-rootless case (e.g. rootless Podman with no
#   allowed caps). The result is `exec /usr/local/bin/node: operation not
#   permitted` and the container never starts. No setcap flag combination avoids
#   this: `+ep`/`+eip` (effective bit) breaks rootless exec, while `+ip` (no
#   effective bit) does not auto-effectivize since node does not raise ambient
#   caps itself. So a baked file capability either breaks rootless startup or
#   provides nothing.
#
# Consequence for privileged ports / raw sockets: because node carries NO file
# capability now, a runtime `--cap-add=NET_BIND_SERVICE` / `--cap-add=NET_RAW`
# alone is no longer sufficient to make the capability EFFECTIVE for node — the
# runtime must ALSO deliver it as an ambient capability (Docker/Podman
# `--cap-add` puts it in the bounding set; making it ambient additionally
# requires the container to raise it), or the operator can sidestep privileged
# ports entirely (unprivileged-port sysctl / port mapping / reverse proxy).
# ioBroker's own admin (8081) and web (8082) use high ports, so the default
# setup needs none of this. See docs/rootless-capabilities.md. (Req 7.1)

# Container-environment indicators. The ioBroker installer / runtime detects a
# container via these entries. `/proc/self/cgroup` (Req 6.1) is inherent to any
# container runtime and needs no action here. `/.dockerenv` (Req 6.2) and
# `/run/.containerenv` (Req 6.3) are laid down explicitly so detection works
# under all supported runtimes (Docker, Podman, k3s). (Req 6.2, 6.3)
RUN set -eux; \
    touch /.dockerenv; \
    mkdir -p /run; \
    touch /run/.containerenv

# Container_User + arbitrary-UID (OpenShift-style) group model.
#   - Establish the default non-root identity at uid/gid 1000 named `iobroker`.
#     (Req 3.1, 3.2, 4.4)
#
#     The `node:${NODE_MAJOR}-${DEBIAN_CODENAME}-slim` base image already ships a `node` user and
#     group at uid/gid 1000, so a plain `groupadd -g 1000` / `useradd -u 1000`
#     fails with "GID '1000' already exists". Rather than pick a different id
#     (which would break the "default UID/GID = 1000" contract) or create a
#     duplicate entry, we ADOPT the existing uid/gid 1000: rename the base
#     image's `node` group/user to `iobroker` in place via groupmod/usermod and
#     point the home directory at /home/iobroker. This keeps uid/gid exactly
#     1000 while giving the Container_User the intended name, and is idempotent
#     against the base image regardless of whether the id already exists. The
#     getent guards make the step robust if a future base image ever drops the
#     pre-created `node` account (then we create it fresh). (Req 3.1, 3.2, 4.4)
#   - Own the writable runtime directories as `1000:0` (owner = the default
#     Container_User uid 1000, group = GID 0) with the setgid bit (2775) and
#     group-writable (g+rwX). This makes the Data_Volume, Log_Volume and
#     node_modules writable by BOTH:
#       * the default user (uid 1000) via OWNER permissions — note uid 1000 is
#         NOT a member of GID 0, so it must be the owner to have write access; and
#       * an arbitrary UID not present in /etc/passwd (OpenShift-style), which
#         lands in GID 0 and writes via GROUP permissions.
#     The setgid bit makes newly created files inherit GID 0 so the arbitrary-UID
#     case keeps working for files the default user creates. The dirs are created
#     first if absent so the chown/chmod succeed even before volumes are mounted.
#     (Req 4.5, 4.6, 8.2, 8.3, 8.4)
#   - The .npmrc that carries the installer npm settings is made GID-0 readable
#     and group-writable (0664) for the same arbitrary-UID reason. It is created
#     empty if the installer did not leave one so the chmod/chgrp succeed;
#     scripts/ensure-npmrc.sh (re)writes its contents at startup. (Req 8.2-8.4)
# These ownership/permission changes require root and run BEFORE `USER 1000`.
#
# Program/read-only files under /opt/iobroker (the js-controller install, the
# `iobroker` launcher) and /opt/lib are additionally made world-readable and
# world-executable-where-appropriate via `chmod -R o+rX`. These are program
# CODE, not secrets: the default Container_User (uid/gid 1000) is NOT a member
# of GID 0, so it reaches these files through the "other" bits — exactly like
# binaries under /usr/bin. This keeps the default user OUT of the root group
# (no privilege, honoring rootless) while still letting it execute the CLI. The
# GID-0 group-writable + setgid model above stays scoped to the WRITABLE data
# dirs, which is what the arbitrary-UID (OpenShift, GID 0) case needs. `o+rX`
# (capital X) only adds execute to dirs and already-executable files, so data
# files do not become executable. (Req 3.1, 4.5, 4.6)
RUN set -eux; \
    if getent group 1000 >/dev/null; then \
        groupmod -n iobroker "$(getent group 1000 | cut -d: -f1)"; \
    else \
        groupadd -g 1000 iobroker; \
    fi; \
    if getent passwd 1000 >/dev/null; then \
        usermod -l iobroker -d /home/iobroker -m -s /bin/bash \
            "$(getent passwd 1000 | cut -d: -f1)"; \
        usermod -g 1000 iobroker; \
    else \
        useradd -u 1000 -g 1000 -m -d /home/iobroker -s /bin/bash iobroker; \
    fi; \
    mkdir -p \
        "${IOB_DIR}" \
        "${IOB_DIR}/iobroker-data" \
        "${IOB_DIR}/log" \
        "${IOB_DIR}/node_modules"; \
    chown -R 1000:0 \
        "${IOB_DIR}" \
        "${IOB_DIR}/iobroker-data" \
        "${IOB_DIR}/log" \
        "${IOB_DIR}/node_modules"; \
    chmod -R g+rwX \
        "${IOB_DIR}" \
        "${IOB_DIR}/iobroker-data" \
        "${IOB_DIR}/log" \
        "${IOB_DIR}/node_modules"; \
    chmod 2775 \
        "${IOB_DIR}" \
        "${IOB_DIR}/iobroker-data" \
        "${IOB_DIR}/log" \
        "${IOB_DIR}/node_modules"; \
    if [ ! -f "${IOB_DIR}/.npmrc" ]; then touch "${IOB_DIR}/.npmrc"; fi; \
    chown 1000:0 "${IOB_DIR}/.npmrc"; \
    chmod 0664 "${IOB_DIR}/.npmrc"; \
    chmod -R +x /opt/scripts; \
    ln -sf "${IOB_DIR}/iobroker" /usr/bin/iobroker; \
    chmod -R o+rX "${IOB_DIR}"; \
    chmod -R o+rX /opt/lib

# Persistence layout mount points. Declaring these as VOLUMEs exposes the
# Data_Volume, Log_Volume and (optional) Modules_Volume as mount points that can
# be backed by host or Kubernetes storage. (Req 8.2, 8.3, 8.4)
VOLUME ["/opt/iobroker/iobroker-data", "/opt/iobroker/log", "/opt/iobroker/node_modules"]

# Drop to the non-root Container_User for all normal operation. Everything that
# needs root (setcap, chgrp/chmod above) has already run. (Req 3.1)
USER 1000

# Upgrade-tolerant healthcheck. Exposed as a Docker-style HEALTHCHECK so Docker
# and Podman can use it; the same script is invokable by Kubernetes probes. The
# script owns the per-check 30s timeout and the grace/upgrade/reconcile tolerance
# logic; the HEALTHCHECK-level --timeout is a coarse outer bound. (Req 9.6)
#
# The script itself decides healthy/starting/unhealthy — during startup, an
# upgrade, or a live reconcile it returns exit 0 (starting) so it does not consume
# the retry budget. --start-period is therefore a coarse safety buffer, not the
# primary mechanism: it is kept generous (60s) so that even the very first probes
# during a normal cold start are not counted, while the reconcile heartbeat (not a
# fixed window) is what tolerates arbitrarily long first-boot reconciliation.
HEALTHCHECK --interval=30s --timeout=30s --start-period=60s --retries=3 \
    CMD ["/opt/scripts/healthcheck.sh"]

# PID 1 = tini, which execs the entrypoint pipeline. The scripts resolve their
# lib/ modules via `${SCRIPT_DIR}/../lib`, and the image keeps scripts/ and lib/
# as siblings under /opt (/opt/scripts, /opt/lib), so ENTRYPOINT points at the
# real copied location /opt/scripts/entrypoint.sh (rather than a /entrypoint.sh)
# to preserve that `../lib` resolution. (Req 14.1)
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/scripts/entrypoint.sh"]

# OCI image metadata. `org.opencontainers.image.source` points at the SOURCE
# repository `ioBroker.container-image`; the GHCR package is published under a
# different name (`iobroker`), and this label is what links the published
# package back to its source repository. (Req 1.3)
# The Node major and Debian codename are recorded as OCI labels (driven by the
# NODE_MAJOR / DEBIAN_CODENAME build args re-declared at the top of this stage),
# NOT baked into the image tag. This keeps the tag as `<version>-r<n>` (the
# js-controller version + image revision) while node/os stay discoverable via
# `docker inspect` / the registry. The description no longer hardcodes a Node
# major so it cannot drift from the actual base image. (Req 1.3)
LABEL org.opencontainers.image.title="ioBroker" \
      org.opencontainers.image.description="Rootless, multi-architecture ioBroker container image (slim multi-stage build)." \
      org.opencontainers.image.source="https://github.com/FernetMenta/ioBroker.container-image" \
      org.opencontainers.image.url="https://github.com/FernetMenta/ioBroker.container-image" \
      org.opencontainers.image.documentation="https://github.com/FernetMenta/ioBroker.container-image" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="node:${NODE_MAJOR}-${DEBIAN_CODENAME}-slim" \
      org.iobroker.node.major="${NODE_MAJOR}" \
      org.iobroker.debian.codename="${DEBIAN_CODENAME}"

# =============================================================================
# Runtime-dependency verification gate (task 15.1)
# =============================================================================
# A per-arch build gate that derives FROM the assembled `runtime` stage and runs
# a single RUN step asserting the Iobroker_Runtime resolves all of its package
# and shared-library dependencies. It runs as its own stage so CI can target it
# (`--target verify`) inside each architecture build: a missing runtime
# dependency fails THAT arch build and, because publish is all-or-nothing, blocks
# publication of the whole multi-arch manifest. This stage is a build gate only
# and is never shipped. (design §2; Req 2.6, 2.7, 2.9, 5.2, 5.3)
#
# The parent `runtime` stage ends on `USER 1000`; the checks below need root
# (dpkg queries are fine unprivileged, but the js-controller smoke start and any
# introspection are simplest as root, and this stage is never shipped), so we
# switch back to root at the top of the stage.
FROM runtime AS verify

# Re-declare IOB_DIR and promote it to an ENV so the verification script (run via
# a single-quoted BuildKit heredoc, where Dockerfile-level ARG expansion does not
# occur) can read it as a normal shell variable at runtime.
ARG IOB_DIR=/opt/iobroker
ENV IOB_DIR=${IOB_DIR}

USER root

# The verification script below uses `set -o pipefail`, which is a bash builtin
# option; the runtime base's default `/bin/sh` is dash, where `set -o pipefail`
# is an illegal option and aborts the step. Run the heredoc under bash (present
# in the image as the Container_User's login shell) so pipefail is honored. This
# SHELL override is scoped to this verify stage (never shipped). (task 15.1)
SHELL ["/bin/bash", "-c"]

# Single verification RUN, written as a BuildKit heredoc so the script can use
# real comments and normal shell control flow (the `dockerfile:1` syntax
# directive at the top of this file enables `RUN <<EOF` heredocs). Each check
# appends the name of any missing / offending dependency to a failure list; at
# the end, a non-empty list prints the offenders and exits non-zero so the build
# fails and publish is blocked. `set -u`/pipefail are used but NOT `set -e`,
# because several checks intentionally run commands expected to fail (e.g.
# `dpkg -s` on a toolchain package that MUST be absent) and we want to record the
# outcome rather than abort on the first non-zero exit.
RUN <<'VERIFY'
set -u
set -o pipefail
fail=""
echo "=== Runtime-dependency verification gate ==="

# --- (1) Runtime packages that MUST be present (Req 2.6, 5.2) ---------------
# Runtime OS packages + the runtime shared-library packages installed in the
# runtime stage. Each must be queryable as installed via `dpkg -s`.
echo "--- [1/4] asserting runtime packages are PRESENT (dpkg -s) ---"
for pkg in \
    acl sudo libcap2-bin git curl unzip distro-info net-tools polkitd passwd \
    lsb-release ca-certificates libcairo2 libpango-1.0-0 librsvg2-2 libpixman-1-0 \
    libjpeg62-turbo libgif7 libudev1 libpam0g libavahi-compat-libdnssd1
do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo "  present: $pkg"
    else
        echo "  MISSING runtime package: $pkg" >&2
        fail="${fail} missing-runtime-package:${pkg}"
    fi
done

# --- (2) Toolchain / -dev headers that MUST be ABSENT (Req 2.3, 5.3) ---------
# These live only in the Build_Stage and must never reach the runtime image.
# `dpkg -s` MUST fail for each; if it succeeds, the package leaked in.
echo "--- [2/4] asserting toolchain / -dev packages are ABSENT (dpkg -s must fail) ---"
for pkg in \
    build-essential gcc make cmake pkg-config \
    libavahi-compat-libdnssd-dev libudev-dev libpam0g-dev libcairo2-dev \
    libpango1.0-dev libjpeg-dev libgif-dev librsvg2-dev libpixman-1-dev
do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo "  LEAKED build-only package present in runtime image: $pkg" >&2
        fail="${fail} leaked-toolchain-package:${pkg}"
    else
        echo "  absent (ok): $pkg"
    fi
done

# --- (3) ldd over compiled native .node files (Req 2.6, 2.9) -----------------
# Every native addon compiled in the Build_Stage must resolve all of its
# shared-object dependencies against the runtime image's libraries. Any
# "not found" line from `ldd` means a runtime shared lib is missing.
#
# CAVEAT — prebuilt bindings for other libc/arch (false-positive guard):
# Some npm packages (e.g. @serialport/bindings-cpp) ship PREBUILT `.node`
# binaries for many platform/libc combinations under a `prebuilds/` directory,
# e.g. `.../prebuilds/linux-x64/node.napi.musl.node` (musl/Alpine) alongside
# `.../prebuilds/linux-x64/node.napi.glibc.node`. On this Debian/glibc image the
# musl variant links `libc.musl-*.so.1`, which is CORRECTLY absent and is NEVER
# loaded here (the glibc sibling resolves fine). Likewise a `prebuilds/`
# directory carries variants for OTHER CPU architectures that this per-arch
# build will never load. `ldd`-ing those non-matching prebuilds yields bogus
# "not found" lines and a false-positive gate failure on a perfectly good image.
#
# So we skip `prebuilds/` variants that DO NOT match this image's libc/arch, and
# ldd-check everything else. The gate stays STRICT for genuinely missing glibc
# deps: the actually-compiled bindings (outside `prebuilds/`) and the MATCHING
# glibc/this-arch prebuild are still checked, so a real missing libcairo etc.
# still fails the build.
echo "--- [3/4] resolving shared libs of compiled native .node files (ldd) ---"

# Map the image's machine arch (uname -m) to the prebuild "linux-<arch>" token
# convention used under prebuilds/ (node/prebuildify/prebuild-install style:
# x86_64 -> x64, aarch64 -> arm64, armv7l -> arm, i686 -> ia32).
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

node_count=0
skipped_count=0
while IFS= read -r nodefile; do
    [ -n "$nodefile" ] || continue

    # False-positive guard: only applies to files living under a prebuilds/
    # directory. Non-prebuild (freshly compiled) .node files are ALWAYS checked.
    case "$nodefile" in
        */prebuilds/*)
            # (a) Skip non-glibc prebuilds (musl). This image is glibc; the musl
            #     variant intentionally links libc.musl-* which is absent here
            #     and is never loaded.
            case "$nodefile" in
                *musl*)
                    echo "  skip (musl prebuild, not loaded on glibc image): $nodefile"
                    skipped_count=$((skipped_count + 1))
                    continue
                    ;;
            esac
            # (b) Skip prebuilds targeting a DIFFERENT CPU arch than this build.
            #     Prebuild dirs are named like `linux-x64`, `linux-arm64`,
            #     `linux-arm`, ... Extract the `linux-<arch>` segment and, if it
            #     names an arch that is not this image's arch, skip it. If the
            #     path carries no recognizable `linux-<arch>` segment we do NOT
            #     skip (fail safe: check it).
            arch_seg="$(printf '%s\n' "$nodefile" | grep -Eo 'linux-[A-Za-z0-9]+' | head -n1)"
            if [ -n "$arch_seg" ] && [ "$arch_seg" != "linux-${prebuild_arch}" ]; then
                echo "  skip (${arch_seg} prebuild, not this image's arch linux-${prebuild_arch}): $nodefile"
                skipped_count=$((skipped_count + 1))
                continue
            fi
            ;;
    esac

    node_count=$((node_count + 1))
    missing="$(ldd "$nodefile" 2>/dev/null | grep 'not found' || true)"
    if [ -n "$missing" ]; then
        echo "  UNRESOLVED shared libs in: $nodefile" >&2
        echo "$missing" | sed 's/^/    /' >&2
        libnames="$(echo "$missing" | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')"
        fail="${fail} unresolved-shared-lib:${nodefile}(${libnames})"
    fi
done <<NODEFILES
$(find "${IOB_DIR}/node_modules" -type f -name '*.node' 2>/dev/null)
NODEFILES
echo "  scanned ${node_count} compiled .node file(s); skipped ${skipped_count} non-matching prebuild(s)"

# --- (4) js-controller / iobroker status smoke start (Req 2.6) ---------------
# Invoke the js-controller status command and confirm it does not fail due to a
# MISSING RUNTIME DEPENDENCY. `iobroker status` may legitimately report a
# non-zero exit here (no objects/states DB is running during the build), so we
# do NOT treat a plain non-zero exit as a gate failure. We DO fail if the
# invocation cannot resolve its runtime dependencies -- i.e. the iobroker CLI is
# not present/executable, or the attempt surfaces a missing shared library or a
# "cannot find module" native-binding error.
echo "--- [4/4] js-controller / iobroker status smoke start ---"
IOB_CLI="${IOB_DIR}/iobroker"
if [ ! -x "$IOB_CLI" ] && command -v iobroker >/dev/null 2>&1; then
    IOB_CLI="$(command -v iobroker)"
fi
if [ ! -x "$IOB_CLI" ]; then
    echo "  MISSING runtime dependency: iobroker CLI not found/executable (looked at ${IOB_DIR}/iobroker and PATH)" >&2
    fail="${fail} missing-runtime-dependency:iobroker-cli"
else
    smoke_out="$( ( cd "${IOB_DIR}" && "$IOB_CLI" status ) 2>&1 || true )"
    echo "$smoke_out" | sed 's/^/    /'
    if echo "$smoke_out" | grep -Eqi 'error while loading shared libraries|cannot open shared object file|Cannot find module|invalid ELF header|GLIBC_'; then
        offender="$(echo "$smoke_out" | grep -Eoi 'error while loading shared libraries.*|cannot open shared object file.*|Cannot find module.*|GLIBC_.*' | head -n1)"
        echo "  SMOKE START failed due to missing runtime dependency: ${offender}" >&2
        fail="${fail} smoke-start-missing-dependency:${offender}"
    else
        echo "  smoke start resolved its runtime dependencies (status exit code is not gated here)"
    fi
fi

# --- Verdict -----------------------------------------------------------------
if [ -n "$fail" ]; then
    echo "=== VERIFICATION GATE FAILED ===" >&2
    echo "Missing / offending runtime dependencies:" >&2
    for item in $fail; do echo "  - ${item}" >&2; done
    echo "Build failed; publish blocked. (Req 2.7, 2.9)" >&2
    exit 1
fi
echo "=== VERIFICATION GATE PASSED: all runtime dependencies resolved ==="
VERIFY

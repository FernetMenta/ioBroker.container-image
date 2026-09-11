# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Startup reconciliation now installs each adapter from the source it was
  originally installed from (`common.installedFrom`): repository adapters via
  `iobroker install <name>`, and non-repository adapters (GitHub tarball, custom
  URL, npm spec, or a package not in the active repo) via `iobroker url
  <source>`. Previously every adapter was installed by name against the default
  repository, so a non-repository adapter failed with "Unknown packet name" and
  aborted the whole startup. A single adapter that still cannot be installed is
  now skipped with a warning instead of preventing the host from starting.
- Multihost role is applied by patching `iobroker.json`
  (`multihostService.enabled`) instead of running `iobroker multihost
  enable/disable` during early startup. That CLI connects to the objects/states
  database, which is not serving yet at that point (js-controller starts later),
  so `IOB_MULTIHOST=master` failed with `ECONNREFUSED` on the database port.

## [0.1.0] - Work in progress

Initial release of the rootless, multi-architecture ioBroker container image — a
revamp of [buanet/ioBroker.docker](https://github.com/buanet/ioBroker.docker).

### Added

- Slim, multi-stage container image built on the official Node.js 22 LTS base.
  The build toolchain and `-dev` headers used to compile ioBroker's native
  modules stay in the build stage and never reach the shipped runtime image.
- Rootless operation as a non-root user (uid/gid 1000), with arbitrary-UID
  (OpenShift-style) support via GID 0 group-writable data directories.
- Multi-architecture publishing as a single manifest for `linux/amd64` and
  `linux/arm64` to `ghcr.io/fernetmenta/iobroker`.
- Reconciliation-based startup: the Data_Volume is the source of truth for the
  installed adapter set; a fresh Data_Volume is initialized on first run and the
  admin adapter is bootstrapped so a new container comes up with a working setup
  UI. Offline start is supported when a persisted `node_modules` volume is
  present.
- Persistence layout with declared volumes for `iobroker-data`, `log`, and the
  optional `node_modules` (adapter code across upgrades).
- Objects/states database backend and multihost configuration via `IOB_*`
  environment variables (networked jsonl or Redis; multihost does not require
  Redis).
- Upgrade-tolerant `HEALTHCHECK` (also usable as Kubernetes liveness/readiness
  probes) with configurable startup grace and upgrade tolerance windows.
- `tini` as PID 1 for signal forwarding and zombie reaping.
- Local build path (`scripts/build-local.sh`) that mirrors CI, reading the Node
  major and Debian codename build knobs from `package.json`.
- Optional `CONTAINER_ENGINE` override for the local build script (`docker`
  default; `podman` selectable — see documentation for the buildah/heredoc
  limitation).
- Documentation: environment variable reference, rootless capabilities and
  limitations, volumes/persistence/multihost, and local build instructions.
- MIT license.

### Changed

- The Node binary is shipped with **no file capabilities**. The previous
  `setcap cap_net_bind_service,cap_net_raw+ep` was removed because its effective
  bit makes the kernel refuse to execute `node` in a fully-rootless container
  (for example rootless Podman with no allowed capabilities), which prevented
  startup. Privileged ports and raw sockets are now handled at the runtime layer
  (ambient capability, the `net.ipv4.ip_unprivileged_port_start` sysctl, or port
  mapping / reverse proxy).

### Removed

- The `SETUID`, `SETGID`, `IOB_UID`, and `IOB_GID` environment variables. The
  runtime user and group are selected exclusively by the container runtime
  (`--user` on Docker/Podman, `runAsUser` / `runAsGroup` / `fsGroup` on
  Kubernetes); a non-root entrypoint cannot change its own UID/GID.

[Unreleased]: https://github.com/FernetMenta/ioBroker.container-image/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/FernetMenta/ioBroker.container-image/releases/tag/v0.1.0

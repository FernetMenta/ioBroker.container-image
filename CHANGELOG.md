# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Multihost master keeps a running slave OUT during startup. Adapter installs run
  before js-controller, and on a master the objects/states jsonl DB binds
  `0.0.0.0`; a connected slave holds the transient install-time DB servers open,
  causing `Failed to lock DB file` errors that no retry can win (the start
  hangs). The entrypoint now temporarily binds the objects/states DB to
  `127.0.0.1` for the install phase and restores the original host before
  starting js-controller, so a slave cannot interfere during startup. The
  rewrite is restored even on failure or a mid-install kill, so a master is never
  left stuck on loopback. See
  [docs/environment-variables.md](docs/environment-variables.md#multihost-master-slave-isolation-during-startup).
- `IOB_INSTALL_TIMEOUT` (default `900`s) bounds a single adapter install attempt
  so a hung `iobroker install`/`iobroker url` is aborted and retried instead of
  freezing the whole start; `0` disables it.
- `IOB_LIST_TIMEOUT` (default `120`s) bounds the `iobroker list instances` query
  used by the install-failure policy, so a stuck database cannot hang the
  observation phase.
- Persistent reconcile log with an end-of-run summary. Startup reconciliation
  now mirrors its output to `reconcile.log` and appends a summary block naming
  the phase, outcome, elapsed time, the observation snapshot, each executed
  action's result, and the install tallies. The log lives in the Log_Volume
  (`/opt/iobroker/log`) next to ioBroker's other logs (override with
  `IOB_RECONCILE_LOG`). Both reconcile passes of a start (init and install) are
  written to the same file in order. Because reconciliation runs before
  js-controller and can hang or be killed mid-run, the log is written on
  success, on a fatal block, and on interruption (`outcome: incomplete`), making
  a stuck or failed start diagnosable after the fact. See
  [docs/environment-variables.md](docs/environment-variables.md#reconcile-log).
- `IOB_ADAPTER_INSTALL_FAILURE_POLICY` to control what happens when an adapter's
  code cannot be (re)installed during startup reconciliation: `strict` (any
  failure fatal), `tolerate-no-instance` (default — fatal only if the adapter
  has an enabled instance on this host), or `tolerate-all` (never fatal). A
  fatal failure does not exit the container (which the restart policy would turn
  into a crash loop); instead the container is held running in an unhealthy
  state with a clear `FATAL` log naming the offending adapter(s), so the
  healthcheck reports unhealthy while `SIGTERM` still stops it cleanly. See
  [docs/environment-variables.md](docs/environment-variables.md#adapter-install-failure-policy).

### Fixed

- Startup no longer hangs indefinitely when an adapter install stalls. Each
  install attempt is now bounded by `IOB_INSTALL_TIMEOUT`; a stalled attempt is
  aborted and retried (bounded by the existing lock-retry count) instead of
  freezing the start until a manual container restart. This addresses the case
  where a transient install-time DB server blocked forever waiting on a file
  lock held by a connected slave.
- The install-failure policy no longer silently tolerates a failure it cannot
  classify. `tolerate-no-instance` decides based on whether an adapter has an
  enabled instance on this host, read from `iobroker list instances`. If that
  query fails or times out, the enabled set is now treated as **indeterminate**
  and the failure is treated as fatal (fail safe) rather than tolerated — so a
  contended database can no longer mask a real problem (e.g. an adapter with a
  running instance whose install failed). Previously a failed query produced an
  empty set indistinguishable from "no enabled instances," wrongly tolerating
  such failures.
- Startup reconciliation retries an adapter install when it hits the jsonl
  "Failed to lock DB file" race. During the pre-controller install phase each
  `iobroker install`/`iobroker url` call briefly file-locks the objects/states
  database; on a multihost master (network-mode DB), a not-yet-released lock
  from the previous install could make the next one fail and abort startup —
  typically only after several adapters had already installed. The install now
  retries with a short backoff on that specific lock error (and only that
  error); genuine failures still surface immediately.
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
- Startup no longer hangs in the reconcile init phase. The init pass gathered
  every observation up front, including `iobroker list instances` (which needs
  the objects/states database) and `npm ping`, before running its only action
  (`iobroker setup first` on an empty volume). Because the database is not
  configured or served yet at that point, `iobroker list instances` could block
  indefinitely, hanging the whole start right after "running reconciliation
  (init phase)". The init pass now computes only the filesystem emptiness check
  it actually needs; the database/registry observations run only in the install
  pass, where they are used and the database is available.

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

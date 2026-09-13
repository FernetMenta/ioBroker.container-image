# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Startup now **self-heals the `node_modules` dependency tree**. Adapters depend
  on shared libraries npm hoists to the top of `node_modules` (e.g. `express`,
  `@iobroker/adapter-core`, `http-mitm-proxy`). A tree left incomplete by an
  earlier prune — the adapter directory present but a hoisted dependency gone —
  makes the adapter crash at runtime with `Cannot find module '<dep>'` even
  though reconciliation sees the adapter as installed and does nothing. After
  restoring `package.json` (and before the reconcile passes / js-controller
  start, where there is no concurrent writer), the entrypoint now runs one
  `npm install` against the complete manifest to materialize any missing
  dependency. It prunes nothing (the manifest is the full set) and is a fast
  no-op when the tree is already consistent; the first run after damage may take
  several minutes and logs that it is in progress. Disable with
  `IOB_HEAL_NODE_MODULES=false`; bound it with `IOB_HEAL_TIMEOUT` (default
  1800s). See `scripts/heal-node-modules.sh`, covered by
  `test/smoke/heal-node-modules.sh`.

### Fixed

- Container **recreate** no longer prunes the persisted adapters out of
  `node_modules`. `node_modules` is a persistent volume but `/opt/iobroker/
  package.json` is not — it lives in the container layer. js-controller and
  adapters (e.g. the javascript adapter installing script modules) grow
  `package.json`'s dependency list at runtime to match the installed adapters. A
  `docker restart` keeps the same layer, so that grown manifest survives and
  stays in sync with the volume. A `docker compose up`/recreate starts a FRESH
  layer, resetting `package.json` to the image baseline (only
  `iobroker.js-controller`) while the volume still holds every adapter — out of
  sync, so the next `npm install` (reconcile OR a runtime adapter install) treats
  every adapter as extraneous and PRUNES it, collapsing `node_modules` and
  forcing a full reinstall (the "broken admin / reinstall all adapters only after
  a recreate, never after a restart" symptom). An authoritative copy of
  `package.json` is now kept inside the persistent `node_modules` volume
  (`.iob-package.json`) and restored over the reset file on every start BEFORE
  any npm/reconcile runs, re-syncing it with the volume so nothing prunes; it is
  refreshed after the install phase to capture new installs. No extra volume is
  required. See `scripts/persist-package-json.sh`, covered by
  `test/smoke/persist-package-json.sh`.
- Reconciliation now detects and repairs a **present-but-incomplete** adapter
  install instead of trusting bare directory presence. An interrupted
  `npm install`, an npm prune that stripped a package's files, or a truncated
  copy can leave `node_modules/iobroker.<name>` in place while its contents are
  incomplete. The old "is the directory there?" check counted such a tree as
  installed, so reconciliation SKIPPED it and js-controller crashed at runtime
  on the missing files — most visibly `iobroker.admin` whose built UI directory
  `adminWww/` was gone, throwing
  `ENOENT ... scandir '.../iobroker.admin/adminWww'` on every request while
  reconcile reported "no actions". An adapter now counts as installed only when
  its package is COMPLETE (`package.json` readable AND the entry point its
  `main` field declares, default `main.js`, exists on disk); an incomplete tree
  is treated as missing so the planner reinstalls it. The install path also
  `rm -rf`s a present-but-incomplete directory before `iobroker install` /
  `iobroker url`, because npm would otherwise see the requested version as
  already satisfied and short-circuit to "up to date" WITHOUT re-extracting the
  tarball — so a reinstall now actually repairs the tree rather than leaving it
  broken. Covered by `test/smoke/installed-adapters-complete.sh`.
- Multihost master install phase no longer floods the log with `Objects DB is not
  allowed to start in the current Multihost environment` and
  `connect ECONNREFUSED 127.0.0.1:9001`. On a master, `multihostService.enabled`
  is `true`, and whenever two of the pre-controller install-time transient jsonl
  servers briefly overlapped, js-controller's multihost guard rejected the second
  one as an unhandled rejection and tore the connection down, spewing
  `ECONNREFUSED` until the attempt timed out (the install was retried and usually
  succeeded, but the start looked alarming and lost minutes). The install-phase
  DB isolation now also sets `multihostService.enabled` to `false` for the
  duration of the install phase (restored before js-controller starts, with the
  `multihostService.role` marker left intact), so each transient server is a
  plain standalone jsonl server: the guard never fires and servers tear down
  cleanly, which also shrinks the residual file-lock race window. Restored even
  on failure or a mid-install kill, so a master is never left with multihost
  disabled. See
  [docs/environment-variables.md](docs/environment-variables.md#multihost-master-slave-isolation-during-startup).

### Added

- The `ping` adapter's system `ping` binary now ships in the image
  (`iputils-ping` added to the runtime package set). The slim base image does
  not include it, so the adapter previously failed with a missing binary.
  Consistent with the rootless-first design, the image does **not**
  `setcap cap_net_raw+ep /bin/ping` (the effective bit would make the kernel
  refuse to exec `ping` in a fully-rootless container). ICMP therefore still
  requires the runtime to grant `NET_RAW` (ambient) or the host to enable the
  `net.ipv4.ping_group_range` sysctl. See
  [docs/rootless-capabilities.md](docs/rootless-capabilities.md#functions-that-require-explicitly-granted-runtime-capabilities-req-75).
- Multihost master keeps a running slave OUT during startup. Adapter installs run
  before js-controller, and on a master the objects/states jsonl DB is served on
  the network; a connected slave holds the transient install-time DB servers
  open, causing `Failed to lock DB file` errors that no retry can win (the start
  hangs). The entrypoint now temporarily binds the objects/states DB to
  `127.0.0.1` for the install phase and restores the original host before
  starting js-controller, so a slave cannot interfere during startup. Isolation
  is driven by the persisted multihost **role** (`multihostService.enabled`), not
  by inspecting the current host: it applies unconditionally on a master (even if
  the host already reads loopback) and is a no-op for a slave (whose DB points at
  the remote master) or a standalone. The rewrite is restored even on failure or
  a mid-install kill, so a master is never left stuck on loopback. See
  [docs/environment-variables.md](docs/environment-variables.md#multihost-master-slave-isolation-during-startup).
- `IOB_INSTALL_TIMEOUT` (default `900`s) bounds a single adapter install attempt
  so a hung `iobroker install`/`iobroker url` is aborted and retried instead of
  freezing the whole start; `0` disables it.
- `IOB_LIST_TIMEOUT` (default `120`s) bounds the `iobroker` observation queries
  (`list instances` and the per-adapter `object get` that reads `installedFrom`),
  so a stuck database cannot hang the observation phase.
- `IOB_INSTALL_SETTLE` (default `2`s) paces the pre-controller install phase:
  after each successful adapter install the next one waits briefly so the
  transient jsonl database server the previous call started can release its
  `objects.jsonl`/`states.jsonl` lock before the next call opens the file. `0`
  disables it.
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
- The pre-controller install phase no longer hangs on the jsonl "Failed to lock
  DB file" race. With js-controller not yet running, each `iobroker install`/
  `iobroker url` call runs its own transient jsonl database server that locks
  `objects.jsonl`/`states.jsonl` and releases the lock slightly **after** the
  process exits; running the next install immediately raced that lagging release
  and could fail to acquire the lock or hang the whole start (observed on a
  master's first migration start). Successful installs are now paced by
  `IOB_INSTALL_SETTLE` (default `2`s) so each server fully releases before the
  next call opens the file. The retry (now also covering transient connection
  drops seen on the jsonl backend when a sibling transient server is momentarily
  not listening: `Connection is closed` / `ECONNRESET` / `ECONNREFUSED` /
  `ETIMEDOUT`) remains as a residual safety net; genuine failures still surface
  immediately (a Redis backend was not tested, but its `NOAUTH`/`WRONGPASS` auth
  errors are deliberately excluded from the retry). The per-adapter `object get`
  that reads `installedFrom` is now bounded by `IOB_LIST_TIMEOUT` too, so a
  lock-stuck lookup can no longer hang the phase before the retry logic is even
  reached.
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

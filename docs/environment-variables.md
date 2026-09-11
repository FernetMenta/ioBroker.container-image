# Environment Variable Reference

This document lists every environment variable recognized by the rootless
ioBroker container image, along with its default value, accepted range/values,
and purpose. It also documents the variables that were **removed** relative to
older reference images.

## Naming convention

- **ioBroker-specific variables use the `IOB_` prefix.** Every setting that is
  particular to this image and to ioBroker is namespaced under `IOB_` (for
  example `IOB_ADMIN_PORT`, `IOB_OBJECTSDB_HOST`, `IOB_MULTIHOST`). This keeps ioBroker
  configuration clearly separated from unrelated environment variables and
  avoids collisions with other software in an orchestrated environment.
- **Conventional variables keep their standard names (unprefixed).** `TZ` and
  `LANG` are widely understood POSIX/system variables, so they are intentionally
  left unprefixed to match the ecosystem-wide convention. They are the only two
  unprefixed variables in the retained set.

Defaults are resolved from the environment snapshot captured at container start.
When a variable that has a defined default is unset at that moment, the default
is applied. Variables mutated during early startup — after the snapshot is
captured — are ignored for default resolution.

## Retained variables

| Variable | Default | Range / values | Purpose |
|---|---|---|---|
| `TZ` | `Etc/UTC` | valid timezone name | Container timezone. When set to a valid timezone, the container timezone is configured accordingly. |
| `LANG` | `en_US.UTF-8` | valid locale | Locale used by the runtime. |
| `IOB_ADMIN_PORT` | `8081` | `1`–`65535` | Admin UI port. |
| `IOB_WEB_PORT` | `8082` | `1`–`65535` | Web adapter port. |
| `IOB_MULTIHOST` | _(unset)_ | `master` \| `slave` | Multihost role. Unset = standalone. Validated. |
| `IOB_OBJECTSDB_TYPE` | _(unset)_ | `jsonl` \| `file` \| `redis` | Objects database type. Validated. |
| `IOB_OBJECTSDB_HOST` | _(unset)_ | hostname / IP | Objects database host (e.g. the multihost master). |
| `IOB_OBJECTSDB_PORT` | _(unset)_ | `1`–`65535` | Objects database port (jsonl default 9001). Validated. |
| `IOB_OBJECTSDB_NAME` / `IOB_OBJECTSDB_PASS` | _(unset)_ | string | Optional objects DB name / password. |
| `IOB_STATESDB_TYPE` | _(unset)_ | `jsonl` \| `file` \| `redis` | States database type. Validated. |
| `IOB_STATESDB_HOST` | _(unset)_ | hostname / IP | States database host. |
| `IOB_STATESDB_PORT` | _(unset)_ | `1`–`65535` | States database port (jsonl default 9000). Validated. |
| `IOB_STATESDB_NAME` / `IOB_STATESDB_PASS` | _(unset)_ | string | Optional states DB name / password. |
| `IOB_STARTUP_GRACE_PERIOD` | `300` | `0`–`3600` (seconds) | Healthcheck startup grace period. During this window after start, the healthcheck does not report unhealthy. |
| `IOB_UPGRADE_TOLERANCE_WINDOW` | `600` | `0`–`3600` (seconds) | Healthcheck upgrade tolerance window. While an upgrade is in progress, the healthcheck does not report unhealthy within this window. |
| `IOB_RECONCILE_STALL_TOLERANCE` | `120` | `0`–`3600` (seconds) | Healthcheck reconcile stall tolerance. While first-boot/post-upgrade reconciliation (adapter installs, native rebuilds) is in progress, the healthcheck tolerates a failing status check for **any** total duration as long as reconcile keeps advancing its heartbeat. This value bounds only how long the heartbeat may go **stale** before reconcile is treated as stuck and unhealthy is reported. Raise it if a single reconcile step (e.g. one large adapter install on a very slow link) can pause longer than the default. |
| `IOB_ADAPTER_INSTALL_FAILURE_POLICY` | `tolerate-no-instance` | `strict` \| `tolerate-no-instance` \| `tolerate-all` | What to do when an adapter's code cannot be (re)installed during startup reconciliation. See [Adapter install failure policy](#adapter-install-failure-policy) below. Validated. |

### Adapter install failure policy

On startup the container reconciles installed adapter **code** to match the
adapter set recorded in the Data_Volume, installing each adapter from the source
it was originally installed from (`common.installedFrom`: the repository, or a
GitHub / URL / npm spec). An install can fail — most often because a non-repository
source is currently unavailable, was renamed, made private, or removed.
`IOB_ADAPTER_INSTALL_FAILURE_POLICY` controls how such a failure is handled:

| Value | Behavior on a failed adapter install |
|---|---|
| `strict` | Any failed install is treated as fatal. |
| `tolerate-no-instance` _(default)_ | Tolerate a failed install **only** when the adapter has no **enabled** instance on this host; a failure for an adapter that **does** have an enabled instance here is fatal. The reasoning: an adapter whose instances are all disabled (or which has no instance on this host) is not actually running, so missing code is harmless; an adapter with a running instance but no code is a real problem you should notice. |
| `tolerate-all` | Never fatal. Every failed install is logged as a warning and startup continues. |

An adapter counts as having an "enabled instance on this host" when
`iobroker list instances` shows at least one of its instances assigned to this
host with an **enabled** status (a `disabled` instance does not count).

Tolerated failures are logged as a warning and startup continues; js-controller
then reports the missing adapters as failing instances until you fix them.

**What "fatal" does — it blocks, it does not crash-loop.** A fatal failure does
**not** exit the container. Exiting would let the runtime's restart policy
restart it straight back into the same failure (a crash loop that also
re-installs the working adapters every cycle). Instead the container is held
running in an **unhealthy** state: reconciliation stops, a clear `FATAL` message
naming the offending adapter(s) is logged, and the healthcheck reports unhealthy
(the reconcile liveness markers are cleared, so a Docker `HEALTHCHECK` /
Kubernetes probe fails once past the startup grace window). Signals still work
(tini forwards `SIGTERM`), so `docker stop` / pod deletion terminates it
cleanly. To recover, fix the adapter source (or remove the offending
adapter/instance) — or relax the policy — and recreate the container.

### Notes on UID/GID

- The runtime user and group are selected **exclusively by the container
  runtime**: `--user` on Docker/Podman, `runAsUser` / `runAsGroup` /
  `fsGroup` on Kubernetes. There is intentionally **no** `IOB_UID` / `IOB_GID`
  environment variable.
- Why: the entrypoint runs as a non-root user, and a non-root process cannot
  change its own UID/GID. An in-image UID/GID variable therefore could not be
  honored — only the container runtime can assign the UID/GID at start. The
  image supports arbitrary UIDs (OpenShift-style) via GID 0 group-writable data
  directories, so any `runAsUser` value works without extra configuration.

## Database backends and multihost

ioBroker stores **objects** and **states** in two separate databases, each with
its own type, host, and port. The type is `jsonl` (the ioBroker default, which
is network-capable), `file`, or `redis` — **multihost does not require Redis**.

- **Standalone (default):** set none of the `IOB_OBJECTSDB_*` / `IOB_STATESDB_*`
  / `IOB_MULTIHOST` variables. The container keeps the local `jsonl` databases
  created at first start; `iobroker.json` is left untouched.
- **Multihost over networked jsonl (no Redis):** on the master, run normally; on
  a slave, point its databases at the master, e.g.:

  ```
  IOB_MULTIHOST=slave
  IOB_OBJECTSDB_TYPE=jsonl
  IOB_OBJECTSDB_HOST=iob
  IOB_OBJECTSDB_PORT=9001
  IOB_STATESDB_TYPE=jsonl
  IOB_STATESDB_HOST=iob
  IOB_STATESDB_PORT=9000
  ```

- **Redis backend:** set `IOB_OBJECTSDB_TYPE=redis` / `IOB_STATESDB_TYPE=redis`
  with the appropriate host/port (and optional name/password).

Only the fields you set are applied; the container patches exactly those and
leaves everything else as ioBroker configured it. Invalid type/port/role values
stop startup with an error naming the value.

### Per-host adapter installation in a multihost cluster

In a multihost cluster the objects DB records adapter **instances** for every
host, and each instance is assigned to a specific host (visible in the host
column of `iobroker list instances`). Adapter **code** only needs to be present
on the host that actually runs an instance, so on startup this container
installs only the adapters whose instances are assigned to **this** host — not
the entire cluster's adapter set. A slave therefore stays slim, installing code
just for the instances it runs rather than everything the master runs.

This host's ioBroker name is its container hostname (for example, set
`hostname: iobroker-sml` in Compose). The reconciler matches that name against
the instance host assignments; you can override it with `IOB_HOSTNAME` if
needed. In a standalone install every instance is assigned to the single host,
so this filtering is a no-op.

## Removed variables

The following variables are **no longer part of the environment variable set**
and are ignored by the image:

| Removed variable | Replacement / how UID/GID is now controlled |
|---|---|
| `SETUID` | Removed. The runtime UID is controlled by the container runtime's `runAsUser` / `--user` override. |
| `SETGID` | Removed. The runtime GID is controlled by the container runtime's `runAsGroup` / `--user` override. |
| `IOB_UID` | Removed. A non-root entrypoint cannot set its own UID; use `runAsUser` / `--user`. |
| `IOB_GID` | Removed. A non-root entrypoint cannot set its own GID; use `runAsGroup` / `--user`. |

`SETUID` and `SETGID` were used by older reference images to select the runtime
UID/GID. In the rootless image, user/group selection is handled entirely by the
container runtime's native user-override mechanism (`runAsUser` / `runAsGroup`
on Kubernetes, `--user` on Docker/Podman), so `SETUID`, `SETGID`, `IOB_UID`, and
`IOB_GID` have all been dropped — a non-root entrypoint cannot set its own
UID/GID, so an in-image variable for it would be misleading.

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

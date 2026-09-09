# Smoke tests (operator / CI checks)

These are **integration / smoke checks** that run against a **built** ioBroker
container image. They are **not** part of the Node unit-test suite (`npm test` /
vitest) because they require a real Docker daemon and a built, multi-arch image.
They are intended to be run by operators or in a CI job **after** the image has
been built or published.

Every script here follows the same rule: if a prerequisite is missing (no
`docker`, no `buildx`, or the image is not reachable) it **skips with a clear
message and exits 0**, so it never hard-fails in a build-less environment.

## Scripts

| Script             | Purpose                                                                 | Requirements                                |
| ------------------ | ----------------------------------------------------------------------- | ------------------------------------------- |
| `manifest-size.sh` | Multi-arch manifest + image-size checks                                 | 1.3, 1.4, 1.5, 1.6, 1.7, 2.5                |
| `runtime-deps.sh`  | Runtime-dependency + packaging checks (dpkg, ldd, smoke start, getcap)  | 2.3, 2.6, 5.2, 5.3, 7.1                     |
| `rootless-uid.sh`  | Non-root default, arbitrary-UID volume access, container-env indicators | 3.3, 3.4, 3.5, 3.6, 4.5, 4.6, 6.1, 6.2, 6.3 |
| `pid1-signals.sh`  | PID 1 = tini, SIGTERM graceful shutdown + exit propagation, zombie reaping, empty Data_Volume init, dropped user startup scripts | 8.6, 13.1, 13.2, 13.3, 14.1, 14.4, 14.5, 14.6 |

## `manifest-size.sh`

Checks, against `IMAGE`:

1. **Both architectures under one tag** — `docker buildx imagetools inspect`
   lists `linux/amd64` **and** `linux/arm64` in a single manifest list.
   (Req 1.3, 1.6)
2. **Unsupported architecture rejected** — the manifest does **not** advertise a
   forbidden platform (default `linux/s390x`), so a pull on such a host fails
   with "no matching manifest". (Req 1.7)
3. **Image size well below ~1.6 GB** — per-architecture size is asserted below a
   configurable threshold (default ~1.4 GiB). (Req 2.5)

### Per-host resolution (Req 1.4, 1.5)

Serving the amd64 variant to an amd64 host and the arm64 variant to an arm64
host is **standard OCI manifest-list behavior** handled by the registry, not by
this image. It cannot be exercised from a single host/architecture, so it is
verified **indirectly**: check 1 confirms both variants exist under one manifest,
which is exactly what the registry uses to resolve the correct variant per host.

### Usage

```bash
# Default image: ghcr.io/<owner>/iobroker:latest
GITHUB_OWNER=my-org ./test/smoke/manifest-size.sh

# Explicit image (published or locally loaded multi-arch tag)
IMAGE=ghcr.io/my-org/iobroker:v1.2.3 ./test/smoke/manifest-size.sh

# A locally built/loaded tag also works
IMAGE=iobroker:local ./test/smoke/manifest-size.sh
```

### Configuration (environment variables)

| Variable               | Default                                            | Meaning                           |
| ---------------------- | -------------------------------------------------- | --------------------------------- |
| `IMAGE`                | `ghcr.io/${GITHUB_OWNER:-<owner>}/iobroker:latest` | Image reference to inspect        |
| `GITHUB_OWNER`         | `<owner>`                                          | Used to build the default `IMAGE` |
| `REQUIRED_ARCHES`      | `linux/amd64 linux/arm64`                          | Platforms that must be present    |
| `FORBIDDEN_ARCHES`     | `linux/s390x`                                      | Platforms that must be absent     |
| `SIZE_THRESHOLD_BYTES` | `1503238553` (~1.4 GiB)                            | Max allowed per-arch size         |

### Size determination

The size check tries two paths, in order:

1. **Local image** — if the image is available locally, it uses the
   authoritative uncompressed `Size` from `docker image inspect`.
2. **Registry manifest** — otherwise, if `jq` is installed, it sums the
   compressed layer sizes per architecture from the raw manifest (a lower
   bound, still sufficient to confirm the image is well under ~1.6 GB).

If neither path can determine a size (image not local and `jq` not installed),
the size assertion is skipped with an informational message; the manifest checks
still run.

### Exit codes

- `0` — all checks passed, **or** skipped because a prerequisite was unavailable.
- `1` — at least one check failed.

## `runtime-deps.sh`

Runs against a **built runtime image** via `docker run` and asserts the shipped
image resolves all of its package and shared-library dependencies. It mirrors
the in-Dockerfile runtime-dependency verification gate (the `verify` stage,
task 15.1) but validates the **shipped `runtime` image** an operator pulls,
rather than the build-time `verify` stage. Each check runs inside a throwaway
container via `docker run --rm --entrypoint /bin/sh ...`.

Checks, against `IMAGE`:

1. **Runtime packages present** — `dpkg -s` succeeds for the runtime OS packages
   (`acl`, `sudo`, `libcap2-bin`, `git`, `curl`, `unzip`, `distro-info`,
   `net-tools`, `polkitd`, `passwd`, `lsb-release`) and the runtime
   shared-library packages. (Req 2.6, 5.2)
2. **Toolchain / `-dev` packages absent** — `dpkg -s` **fails** for
   `build-essential`, `gcc`, `make`, `cmake`, `pkg-config` and the `-dev`
   header packages, proving the Build_Stage toolchain never leaked into the
   runtime image. (Req 2.3, 5.3)
3. **`ldd` over native `.node` files** — every compiled `*.node` file under
   `/opt/iobroker/node_modules` resolves its shared objects with no "not found"
   line. (Req 2.6)
4. **js-controller smoke start** — `iobroker status` does not fail due to a
   missing runtime dependency. A plain non-zero exit is **not** treated as a
   failure (no objects/states DB runs during the check); only a missing shared
   library or "cannot find module" native-binding error fails the check.
   (Req 2.6)
5. **`getcap` on the node binary** — the resolved (via `readlink -f`) node
   binary reports **no** file capabilities. The image intentionally does not
   `setcap` node, because a file capability with the effective bit prevents
   `node` from executing in a fully-rootless container. Privileged ports / raw
   sockets are handled at the runtime layer (see
   `docs/rootless-capabilities.md`). (Req 7.1)

### Usage

```bash
# Default image: iobroker:local (as produced by scripts/build-local.sh single)
./test/smoke/runtime-deps.sh

# Explicit image
IMAGE=ghcr.io/my-org/iobroker:v1.2.3 ./test/smoke/runtime-deps.sh

# Podman works too
DOCKER=podman IMAGE=iobroker:local ./test/smoke/runtime-deps.sh
```

### Configuration (environment variables)

| Variable  | Default          | Meaning                               |
| --------- | ---------------- | ------------------------------------- |
| `IMAGE`   | `iobroker:local` | Image reference to test               |
| `DOCKER`  | `docker`         | Container CLI (e.g. `podman`)         |
| `IOB_DIR` | `/opt/iobroker`  | ioBroker install dir inside the image |

### Exit codes

- `0` — all checks passed, **or** skipped because a prerequisite was unavailable
  (no container CLI, engine unreachable, or the image is not present locally).
- `1` — at least one runtime-dependency / packaging check failed.

## `rootless-uid.sh`

Checks, against a **built** image referenced by `IMAGE`, using `docker run`:

1. **Default run is non-root** — `docker run --rm --entrypoint id "$IMAGE" -u`
   returns a non-zero UID (the image declares `USER 1000`), so normal operation
   never starts as root. (Req 3.3)
2. **No sudo in the normal path** — the shipped entrypoint scripts under
   `/opt/scripts` contain no `sudo` invocation, and the container runs as the
   non-root user, so normal startup does not rely on privilege escalation.
   (Req 3.6)
3. **Arbitrary-UID read+write to the volumes** — run as `--user 12345:0` (a UID
   not present in `/etc/passwd`, in GID 0), the container can **create and read
   back** a temp file under both `/opt/iobroker/iobroker-data` (Data_Volume) and
   `/opt/iobroker/log` (Log_Volume), thanks to the GID-0 group-writable +
   setgid directories baked into the image. (Req 4.5, 4.6)
4. **Container-environment indicators present** — `/.dockerenv` exists and is
   readable (Req 6.2), `/run/.containerenv` exists and is readable (Req 6.3),
   and `/proc/self/cgroup` is readable as a container indicator (Req 6.1).

### Podman-rootless and k3s coverage (Req 3.4, 3.5)

The docker-based checks cover the **portable** assertions that hold identically
across Docker, Podman-rootless, and k3s, because they are properties of the
**image** — its non-zero default `USER` and its GID-0 group-writable /
setgid-enabled writable directories — not of the runtime. Under Podman-rootless
and k3s the same non-root default applies, and an arbitrary `runAsUser` lands in
GID 0 and gains the same read+write access to the Data_Volume and Log_Volume.
Those runtimes exercise the identical non-root behavior and are verified in
their own runtime environments (a Podman-rootless host and a k3s cluster with a
`securityContext.runAsUser`); `rootless-uid.sh` asserts the image-level
guarantees that make that behavior hold everywhere.

### Usage

```bash
# A locally built/loaded tag
IMAGE=iobroker:local ./test/smoke/rootless-uid.sh

# A published multi-arch tag
IMAGE=ghcr.io/my-org/iobroker:v1.2.3 ./test/smoke/rootless-uid.sh
```

### Configuration (environment variables)

| Variable  | Default          | Meaning                                              |
| --------- | ---------------- | ---------------------------------------------------- |
| `IMAGE`   | `iobroker:local` | Image reference to run                               |
| `IOB_DIR` | `/opt/iobroker`  | ioBroker install dir (Data_Volume/Log_Volume parent) |

### Exit codes

- `0` — all checks passed, **or** skipped because `docker` / the image was unavailable.
- `1` — at least one check failed.

## `pid1-signals.sh`

Runs against a **built** image referenced by `IMAGE`, using `docker run` (Podman
is CLI-compatible — set `CONTAINER_CLI=podman`). It validates PID 1 signal
handling, zombie reaping, empty-Data_Volume initialization, and the removal of
user startup scripts.

Because a full ioBroker start is heavy (minutes), the checks are split into a
**lightweight, default-on** group and a **heavy** group gated behind
`SMOKE_FULL=1`.

### Lightweight checks (default; no ioBroker start)

1. **PID 1 is tini** — `readlink -f /proc/1/exe` inside the container resolves
   to `/usr/bin/tini`, confirming the image's `ENTRYPOINT`
   (`["/usr/bin/tini","--", ...]`) wires tini in as the Init_Process. (Req 14.1)
2. **Mounted user startup script is ignored** — a marker script is mounted into
   several locations a legacy image (e.g. buanet) might have sourced from
   (`/etc/cont-init.d`, `/mnt/userhook`). The modernized entrypoint has no
   hook-sourcing step, so the script's sentinel must never appear. (Req 13.1,
   13.2, 13.3)
3. **Container-environment indicators present** — a cheap sanity check that
   `/.dockerenv` and `/run/.containerenv` exist in the image under test.

### Heavy checks (`SMOKE_FULL=1`; start a full ioBroker)

4. **SIGTERM graceful shutdown + exit propagation** — start the container, wait
   for `iobroker status` to succeed, then `<cli> stop -t N`. The container must
   stop within a bounded time (`SMOKE_STOP_TIMEOUT` + slack) and its
   `State.ExitCode` must be a well-defined propagated status (`0`, or a
   terminating-signal status such as `143` = 128+SIGTERM), proving tini forwards
   SIGTERM and propagates the child's exit status. (Req 14.4)
5. **No zombies** — after an orphaned child (reparented to PID 1) exits, an
   in-container process listing shows **zero** defunct (Z-state) processes,
   proving tini reaps orphans. (Req 14.5)
6. **Empty Data_Volume initializes defaults** — start with a fresh empty named
   volume mounted at `/opt/iobroker/iobroker-data`; after startup the volume
   contains the default ioBroker configuration/state (`iobroker.json` and/or the
   objects/states DB files). (Req 8.6)

### Podman / k3s coverage (Req 14.6)

PID 1 signal handling and zombie reaping are properties of the **image**
(tini wired in as PID 1 via `ENTRYPOINT`), so they hold identically under
Docker, Podman, and k3s. Set `CONTAINER_CLI=podman` to exercise the exact same
checks under Podman; k3s runs the same image entrypoint and therefore the same
PID 1 behavior, verified in a k3s environment.

### Usage

```bash
# Lightweight checks only (fast), against a locally built/loaded tag
IMAGE=iobroker:local ./test/smoke/pid1-signals.sh

# Include the heavy checks (starts a full ioBroker; takes minutes)
IMAGE=iobroker:local SMOKE_FULL=1 ./test/smoke/pid1-signals.sh

# Podman (exercises the same PID 1 behavior — Req 14.6)
CONTAINER_CLI=podman IMAGE=iobroker:local ./test/smoke/pid1-signals.sh
```

### Configuration (environment variables)

| Variable                | Default          | Meaning                                                              |
| ----------------------- | ---------------- | -------------------------------------------------------------------- |
| `IMAGE`                 | _(unset)_        | Image reference to test; when unset, all tests skip with a message   |
| `CONTAINER_CLI`         | `docker`         | Container CLI (e.g. `podman`)                                        |
| `SMOKE_FULL`            | `0`              | When `1`, also run the heavy tests that start a full ioBroker        |
| `SMOKE_STARTUP_TIMEOUT` | `300`            | Seconds to wait for `iobroker status` to succeed (heavy tests)       |
| `SMOKE_STOP_TIMEOUT`    | `30`             | Seconds passed to `<cli> stop -t` and the bounded-exit assertion     |

### Exit codes

- `0` — all run checks passed, **or** skipped because a prerequisite was
  unavailable (no container CLI, or the image is not present).
- `1` — at least one check failed.

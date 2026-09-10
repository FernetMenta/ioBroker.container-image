# ioBroker.container-image

A rootless, multi-architecture container image for
[ioBroker](https://www.iobroker.net/), built as a slim multi-stage image on the
official Node.js 22 LTS base.

> **Note:** This project is a revamp of
> [buanet/ioBroker.docker](https://github.com/buanet/ioBroker.docker). It builds
> on the ideas of that widely used ioBroker container image while
> re-architecting it around a rootless, multi-architecture, reconciliation-based
> design.

The published image is available from GitHub Container Registry as
`ghcr.io/fernetmenta/iobroker` (the package name intentionally differs from this
source repository, `ioBroker.container-image`).

## Highlights

- **Rootless by default.** Runs as a non-root user (uid/gid 1000) and supports
  arbitrary UIDs (OpenShift-style) via GID 0 group-writable data directories.
  The Node binary carries no file capabilities, so it executes cleanly under
  rootless Docker, Podman, and Kubernetes.
- **Slim multi-stage build.** The build toolchain and `-dev` headers used to
  compile ioBroker's native modules live only in the build stage and never reach
  the shipped runtime image.
- **Multi-architecture.** Published as a single multi-arch manifest for
  `linux/amd64` and `linux/arm64`.
- **Reconciliation-based startup.** The Data_Volume is the source of truth for
  which adapters are installed; on start the container reconciles installed
  adapter code to match, initializes a fresh Data_Volume on first run, and
  bootstraps the admin adapter so a new container comes up with a working setup
  UI.
- **Upgrade-tolerant healthcheck.** A Docker/Podman `HEALTHCHECK` (also usable
  as Kubernetes liveness/readiness probes) with configurable startup grace and
  upgrade tolerance windows.
- **tini as PID 1.** Proper signal forwarding and zombie reaping.

## Quick start

First boot on an empty data volume takes a short while as the container
initializes ioBroker and installs the admin adapter, after which the admin UI is
available on port 8081.

### Docker

```bash
docker volume create iobroker-data
docker run -d \
  --name iobroker \
  -p 8081:8081 \
  -p 8082:8082 \
  -v iobroker-data:/opt/iobroker/iobroker-data \
  -v iobroker-log:/opt/iobroker/log \
  ghcr.io/fernetmenta/iobroker
```

### Podman (rootless)

Podman uses the same syntax as Docker:

```bash
podman run -d \
  --name iobroker \
  -p 8081:8081 \
  -p 8082:8082 \
  -v iobroker-data:/opt/iobroker/iobroker-data \
  -v iobroker-log:/opt/iobroker/log \
  ghcr.io/fernetmenta/iobroker
```

Then open <http://localhost:8081> for the admin UI.

## Persistence

The image persists only the folders that hold configuration, state, logs, and
(optionally) installed adapter code — you never bind-mount the whole
`/opt/iobroker` installation:

| Mount point                   | Purpose                                           | Required    |
| ----------------------------- | ------------------------------------------------- | ----------- |
| `/opt/iobroker/iobroker-data` | ioBroker configuration + state (source of truth)  | Recommended |
| `/opt/iobroker/log`           | ioBroker logs                                     | Recommended |
| `/opt/iobroker/node_modules`  | Installed adapter code, persisted across upgrades | Optional    |

See [docs/volumes-and-multihost.md](docs/volumes-and-multihost.md) for
persistence behavior, startup reconciliation, multihost clusters (networked
jsonl or Redis), and Kubernetes probe examples.

## Configuration

ioBroker-specific settings use the `IOB_` prefix (for example `IOB_ADMIN_PORT`,
`IOB_WEB_PORT`, `IOB_MULTIHOST`, and the objects/states database variables). The
runtime user and group are selected exclusively by the container runtime
(`--user` / `runAsUser`), not by an in-image variable.

See [docs/environment-variables.md](docs/environment-variables.md) for the full
environment variable reference.

## Documentation

- [Environment variables](docs/environment-variables.md) — full reference.
- [Rootless capabilities and limitations](docs/rootless-capabilities.md) — how
  capabilities behave rootless, and how to handle privileged ports / raw
  sockets.
- [Volumes, persistence, and multihost](docs/volumes-and-multihost.md) —
  persistence layout, reconciliation, multihost/database backends, Kubernetes
  probes.
- [Building the image locally](docs/building.md) — the local build path that
  mirrors CI.
- [Changelog](CHANGELOG.md) — notable changes per release.

## Building

Local builds mirror CI (same `Dockerfile`, same build knobs read from
`package.json`, same runtime-dependency verification gate):

```bash
# single-arch build for your host platform: loads the shippable rootless
# runtime image into the local image store, and runs the verification gate:
scripts/build-local.sh single

# multi-arch validation build (linux/amd64,linux/arm64), no push:
scripts/build-local.sh multi
```

The loaded image is the shippable `runtime` stage (rootless, `USER 1000`); the
runtime-dependency gate (`verify` stage) runs as a separate build so it fires
without landing a root-running image in your store. See
[docs/building.md](docs/building.md#single-arch-vs-multi-arch) for details.

Docker with Buildx is the supported build engine. Building with Podman is not
currently supported — see
[docs/building.md](docs/building.md#building-with-podman) for details.

## License

[MIT](LICENSE) © FernetMenta

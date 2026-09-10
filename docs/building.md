# Building the image locally

This document describes the **local build path** for the rootless ioBroker
container image. It is a first-class path that **mirrors CI**: the same
`Dockerfile`, the same source for the build knobs (`NODE_MAJOR` and
`DEBIAN_CODENAME`), and the same runtime-dependency verification gate. A local
build therefore reproduces what CI builds. (Requirements 2.2, 5.4, 5.5, 5.7)

## TL;DR

```sh
# single-arch build for your local host platform (loads into docker):
npm run build:local
#   or: scripts/build-local.sh single

# multi-arch validation build (linux/amd64,linux/arm64), no push, no load:
npm run build:local:multi
#   or: scripts/build-local.sh multi
```

Neither command pushes anything. Publishing is CI's job.

## The build knobs and where they come from

The `Dockerfile` requires two build args:

- `NODE_MAJOR` — the Node.js major version to compile ioBroker's native modules
  against.
- `DEBIAN_CODENAME` — the Debian release codename for both the build and runtime
  base images (default `trixie`).

Both are **maintainer-owned build knobs** read from our own `package.json` under
the `containerImage` key:

```json
"containerImage": {
  "nodeMajor": 22,
  "debianCodename": "trixie"
}
```

These are **our** decisions as image maintainers, kept in a single place we own.
There is no fallback to a system default: if `nodeMajor` is missing, empty,
whitespace-only, or not an integer, the build **fails fast before any
`docker buildx` step**, exactly as CI does. `debianCodename` must likewise be a
non-empty string (or supplied via the `DEBIAN_CODENAME` environment override).

> Note: this project does **not** read ioBroker's `versions.json`. That file is
> ioBroker's, not the image maintainer's, and is misleading as a source of
> image build knobs. Nothing reads it at container runtime.

The read is not re-implemented for the local path. `scripts/build-local.sh` runs
the **same pure modules** the rest of the codebase and CI use:

- `lib/build-config.js` — reads/parses `package.json` and locates the
  `containerImage.nodeMajor` / `containerImage.debianCodename` fields.
- `lib/node-major.js` — `deriveNodeMajorFromPackageJson()` turns the `nodeMajor`
  value into an integer major version (or throws, no fallback).

The equivalent of a manual one-liner is:

```sh
node --input-type=module -e '
  import { readPackageJson, readDebianCodename } from "./lib/build-config.js";
  import { deriveNodeMajorFromPackageJson } from "./lib/node-major.js";
  const pkg = readPackageJson("./package.json");
  process.stdout.write(deriveNodeMajorFromPackageJson(pkg) + " " + readDebianCodename(pkg));
'
```

## Debian base release (`DEBIAN_CODENAME`)

The base image is `node:${NODE_MAJOR}-${DEBIAN_CODENAME}(-slim)`. The Debian
release is read from `containerImage.debianCodename` (default **`trixie`**,
current Debian stable). Both the build and runtime stages use the same value, so
the compiled native modules stay ABI-compatible with the runtime base.

To build on Debian `bookworm` (oldstable) instead, override the codename via the
environment (the override wins over the Build_Config value):

```sh
DEBIAN_CODENAME=bookworm npm run build:local
#   or: DEBIAN_CODENAME=bookworm scripts/build-local.sh single
#   or (raw): docker buildx build --build-arg NODE_MAJOR=<n> \
#             --build-arg DEBIAN_CODENAME=bookworm -f Dockerfile .
```

To make the change permanent, edit `containerImage.debianCodename` in
`package.json`.

## Single-arch vs multi-arch

`scripts/build-local.sh` takes one positional argument, the mode:

- `single` (default) — builds the shippable **`runtime`** stage for your **local
  host platform** and `--load`s it into your local docker image store so you can
  run and inspect the rootless (`USER 1000`) image you would actually ship. The
  verification gate runs too, as a separate non-loaded build (see below).
- `multi` — builds `linux/amd64,linux/arm64`. Buildx cannot `--load` a
  multi-platform result into the docker store, so this mode neither loads nor
  pushes: it **validates both architectures** (runtime plus the verify gate on
  each) without producing a local image and without publishing.

> **Why the loaded image is the `runtime` stage, not `verify`.** The `verify`
> stage exists only to assert runtime dependencies during the build; it derives
> `FROM runtime` and ends on `USER root`, so it is not something you want sitting
> in your image store as `iobroker:local`. The script therefore loads the
> `runtime` stage and runs the `verify` gate as a separate build (no `--load`,
> no `--push`). BuildKit reuses the `runtime` layers, so the gate build is cheap.
> Skip the gate for a fast inner loop with `RUN_VERIFY_GATE=false`.

## Equivalence with CI

The local path is deliberately kept equivalent to the CI build (task 16.1):

| Aspect                  | Local build                              | CI build                                 |
| ----------------------- | ---------------------------------------- | ---------------------------------------- |
| Dockerfile              | `-f Dockerfile`                          | same `Dockerfile`                        |
| Build knob source       | `package.json` `containerImage` (lib/)   | same `package.json` `containerImage`     |
| Build args              | `--build-arg NODE_MAJOR/DEBIAN_CODENAME` | `--build-arg NODE_MAJOR/DEBIAN_CODENAME` |
| Loaded/shipped stage    | `runtime` (rootless `USER 1000`)         | `runtime` (rootless `USER 1000`)         |
| Runtime-dependency gate | separate `--target verify` build         | same gate stage per architecture         |
| Architectures           | host (single) or amd64+arm64 (multi)     | `linux/amd64,linux/arm64`                |
| Debian base             | `debianCodename` (default `trixie`)      | same default (`trixie`)                  |
| Push                    | never                                    | only on `v*` tag pushes                  |

Because the build-knob source, the Dockerfile, and the gate stage are identical,
a successful local build reproduces what CI builds.

## Configuration (environment overrides)

`scripts/build-local.sh` honors these environment variables:

- `CONTAINER_ENGINE` — the container engine to build with: `docker` (default) or
  `podman`. Both expose a Docker-compatible `buildx build` CLI, and the script
  adds Docker's `--load` flag only for Docker (Podman builds directly into its
  own store and has no `--load` flag). **Caveat:** Podman builds with buildah,
  which cannot parse _this_ `Dockerfile`'s heredoc `RUN` blocks, and Podman has
  no BuildKit mode — see [Building with Podman](#building-with-podman) below.
- `BUILD_CONFIG_JSON` — path to the `package.json` holding the `containerImage`
  Build_Config. Defaults to the repo-root `./package.json`.
- `IMAGE_TAG` — image reference/tag for the build. Defaults to `iobroker:local`.
- `BUILD_TARGET` — the `Dockerfile` stage to build and load. Defaults to
  `runtime` (the shippable rootless image). Override to build a specific stage;
  when overridden away from `runtime`, the separate verify gate is skipped
  (you are targeting a stage on purpose). If the requested stage is not present
  in the `Dockerfile`, the script warns and falls back to `runtime`.
- `RUN_VERIFY_GATE` — when `true` (default), also run the `verify` gate as a
  separate non-loaded build so the dependency gate fires locally. Set to `false`
  for a fast inner-loop rebuild.
- `VERIFY_TARGET` — name of the verification gate stage (default `verify`).
- `PLATFORMS` — override the multi-arch platform list (default
  `linux/amd64,linux/arm64`).
- `DEBIAN_CODENAME` — override the Debian release from the Build_Config (default
  read from `containerImage.debianCodename`; set to `bookworm` for oldstable).
  Shared by both build stages.

Examples:

```sh
# skip the verification gate for a fast inner-loop rebuild, custom tag:
RUN_VERIFY_GATE=false IMAGE_TAG=iobroker:dev npm run build:local

# multi-arch validation on bookworm:
DEBIAN_CODENAME=bookworm npm run build:local:multi
```

## Building with Podman

**Building with Podman is currently not supported**, for the following reasons:

- The `Dockerfile` uses BuildKit **heredoc `RUN`** blocks (`RUN <<'EOF' … EOF`,
  enabled by the `# syntax=docker/dockerfile:1` directive at the top of the file)
  for the ioBroker install step and the runtime-dependency verification gate.
- Docker builds with **BuildKit**, which understands these heredocs. Podman
  builds with **buildah**, a separate engine that does **not** parse heredoc
  `RUN` blocks: it fails with `Unknown instruction: "SET"` (it mis-reads the
  `set -eux` inside the heredoc body).
- **Podman does not use BuildKit and cannot be configured to.** `podman buildx`
  is only a Docker-compatible alias over buildah; there is no setting to
  install or enable inside Podman that would make it parse these heredocs.

The script still accepts `CONTAINER_ENGINE=podman` (it invokes `podman buildx
build` with the same build args/`--target` and omits Docker's `--load` flag), but
on this `Dockerfile` that build will fail at the first heredoc `RUN` as described
above.

If you need to avoid Docker for building, the alternatives are:

- **Build with Docker, run with Podman.** Rootless Podman is a fully supported
  _runtime_ (see [rootless-capabilities.md](./rootless-capabilities.md)); only
  the _build_ needs Docker. Simplest, no extra tooling.
- **Build with a standalone BuildKit toolchain** that is _not_ Podman — e.g.
  `buildkitd` + `buildctl`, or `nerdctl` (BuildKit under containerd) — then load
  the resulting image into Podman's store. Separate toolchain; does not go
  through this script.
- **Remove the heredocs from the `Dockerfile`** so buildah can parse it, which
  would let `podman build` work directly. Not done here because the heredoc
  install/verify steps are the build's most critical steps.

## Prerequisites

- A container engine:
  - **Docker** with **Buildx** (`docker buildx version` must succeed) — the
    default and fully supported build engine; or
  - **Podman** — can be selected via `CONTAINER_ENGINE=podman`, but its buildah
    backend cannot parse this `Dockerfile`'s heredoc `RUN` blocks, and Podman has
    no BuildKit mode. See [Building with Podman](#building-with-podman) for the
    realistic options (build with Docker and run with Podman, or use a separate
    BuildKit toolchain).
- Node.js (used only to read the build knobs from `package.json`).
- For `multi` builds, a Buildx builder with QEMU emulation for cross-arch builds
  (e.g. `docker run --privileged --rm tonistiigi/binfmt --install all` and a
  `docker buildx create --use` builder), matching CI's
  `docker/setup-qemu-action` + `docker/setup-buildx-action`.

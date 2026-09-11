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

| Aspect                  | Local build                                | CI build                                                 |
| ----------------------- | ------------------------------------------ | -------------------------------------------------------- |
| Dockerfile              | `-f Dockerfile`                            | same `Dockerfile`                                        |
| Build knob source       | `package.json` `containerImage` (lib/)     | same `package.json` `containerImage`                     |
| Build args              | `--build-arg NODE_MAJOR/DEBIAN_CODENAME`   | `--build-arg NODE_MAJOR/DEBIAN_CODENAME`                 |
| Loaded/shipped stage    | `runtime` (rootless `USER 1000`)           | `runtime` (rootless `USER 1000`)                         |
| Runtime-dependency gate | separate `--target verify` build           | same gate stage per architecture                         |
| Architectures           | host (single) or amd64+arm64 (multi)       | `linux/amd64,linux/arm64`                                |
| Debian base             | `debianCodename` (default `trixie`)        | same default (`trixie`)                                  |
| js-controller version   | `JS_CONTROLLER_VERSION` (default `stable`) | pinned from the release tag on tag pushes, else `stable` |
| Push                    | never                                      | on `<version>-r<n>` and `<version>-dev-r<n>` tag pushes  |

Because the build-knob source, the Dockerfile, and the gate stage are identical,
a successful local build reproduces what CI builds.

## Versioning and release tags

The image version is driven entirely by the **git tag**. There are three tag
shapes, and each plays a distinct role:

| Git tag                           | Role               | Pushed by      | Builds & publishes?                      |
| --------------------------------- | ------------------ | -------------- | ---------------------------------------- |
| `<version>-dev-r<n>`              | dev/test build     | you (manually) | yes — immutable dev tag only             |
| `<version>-r<n>`                  | release build      | automation     | yes — immutable + `<version>` + `latest` |
| `<version>` / `<version>.<build>` | release **signal** | you (manually) | no — triggers promotion                  |

- `<version>` is the bundled **iobroker.js-controller** version, always **3
  numeric components** (`7.2.2`) — the thing users track.
- `-r<n>` is the **image revision**. It bumps on a rebuild of the _same_
  controller version (base-image security patch, `Dockerfile`/script change,
  dependency bump) and starts at `-r1` for each `<version>`.
- `-dev-r<n>` marks a **dev/test** build. It is the only tag you push by hand
  during development.

There is **no `v` prefix**, so the release git tag (`7.2.2-r3`) and the image tag
are byte-for-byte identical.

You **never hand-push `<version>-r<n>` release tags anymore** — automation
creates them (see [How to release](#how-to-release) and
[Automatic revision bumps](#automatic-revision-bumps-on-a-newer-base-image)).

### Dev/test builds

During development, push a `-dev-r<n>` tag to build and publish a throwaway
image to GHCR without touching the release pointers:

```sh
git tag 7.2.2-dev-r1 && git push origin 7.2.2-dev-r1
# -> ghcr.io/<owner>/iobroker:7.2.2-dev-r1   (NO `latest`, NO `7.2.2` alias)
```

A dev build pins js-controller to the tag's `<version>` (here `7.2.2`) exactly
like a release build, but it publishes **only** its immutable
`7.2.2-dev-r<n>` tag. It deliberately does **not** move the moving `7.2.2`
alias or `latest`, so consumers of the released image never accidentally pull a
dev build. Dev tags are also ignored by the base-refresh job.

### How to release

You do not create release revisions directly. Instead push a plain `<version>`
**release-signal** tag; the `release-promote.yml` workflow reacts to it:

```sh
# release js-controller 7.2.2 (or re-release after image/script changes):
git tag 7.2.2   && git push origin 7.2.2
# image-only re-release of an already-released version (4th component = a nudge):
git tag 7.2.2.1 && git push origin 7.2.2.1
```

On that signal, `release-promote.yml` (via `scripts/plan-release-tags.sh`):

1. Takes the **latest 2 distinct** 3-component `<version>`s across **all** tags
   (both `-dev-r<n>` and `-r<n>` reveal a version). Older versions stay frozen.
2. For each, creates the next release revision and pushes it:
   - `<version>-r<highest+1>` if a `<version>-r<n>` release tag already exists;
   - `<version>-r1` if only `<version>-dev-r<n>` tags exist (first release of
     that version).

Re-cutting the **previous** release too is intentional: image/script changes
made during the new version's dev cycle then flow to the prior release as well.

> **Example.** You are testing `7.2.2` (tags up to `7.2.2-dev-r7`) and the
> previous release is `7.1.3-r3`. Pushing `7.2.2` (or `7.2.2.1`) creates
> **`7.2.2-r1`** (first release of 7.2.2) **and** **`7.1.3-r4`** (the prior
> release picks up the shared changes). Each pushed release tag then triggers
> `build-publish.yml`.

The 4th numeric component in a `<version>.<build>` signal (e.g. the `.1` in
`7.2.2.1`) is just a way to push a fresh signal tag when `7.2.2` already exists;
it is **not** part of the js-controller `<version>` and never appears in an
image tag.

Before signalling a release, bump `containerImage` in `package.json` if the Node
major or Debian codename changed.

Node major and Debian codename are **not** in the tag. They are recorded as OCI
image labels (`org.iobroker.node.major`, `org.iobroker.debian.codename`,
`org.opencontainers.image.base.name`) so the tag stays focused on the two things
that matter while node/os stay discoverable via `docker inspect`.

### The tag pins the controller (no `stable` drift)

Pushing a release tag makes CI pass the parsed `<version>` to the build as
`JS_CONTROLLER_VERSION`, so an image tagged `7.2.2-r2` is built against **exactly**
js-controller `7.2.2` — never the drifting `stable` dist-tag. The `Dockerfile`
then asserts, after install, that the installed controller version equals the
requested one and **fails the build on mismatch** (a moved dist-tag, a typo'd
tag, a yanked version). That check runs in the per-arch `verify` gate too, so a
bad tag fails **before** anything is published.

On non-tag builds (PRs, pushes to `main`, `workflow_dispatch`) there is nothing
to pin, so `JS_CONTROLLER_VERSION` stays `stable` (the normal shipped default)
and the exact-version check is skipped.

### What CI publishes

On a **release** tag (`<version>-r<n>`):

| Image tag  | Kind      | Points at                                   |
| ---------- | --------- | ------------------------------------------- |
| `7.2.2-r3` | immutable | this exact build                            |
| `7.2.2`    | moving    | newest revision for that controller version |
| `latest`   | moving    | newest release overall                      |

On a **dev** tag (`<version>-dev-r<n>`) only the immutable tag is published;
`latest` and the `<version>` alias are left untouched:

| Image tag      | Kind      | Points at        |
| -------------- | --------- | ---------------- |
| `7.2.2-dev-r2` | immutable | this exact build |

### Automatic revision bumps on a newer base image

The base image (`node:<major>-<codename>-slim`) is rebuilt upstream for security
patches **without** the js-controller version changing. When that happens, a
published `<version>-r<n>` silently falls behind its own base. A scheduled
workflow (`.github/workflows/base-refresh.yml`) keeps the **latest 2**
js-controller versions current:

1. It collects the latest two distinct `<version>`s from the existing
   `<version>-r<n>` **release** tags (e.g. `7.2.2` and `7.1.3`). Dev-only
   versions (those with just `<version>-dev-r<n>` tags) and older versions are
   left frozen — a version is refreshed only after `release-promote.yml` has
   cut its first `-r1`.
2. For each, `scripts/check-base-refresh.sh` finds the highest revision (e.g.
   `7.2.2-r5`), reads the base image from that published image's own
   `org.opencontainers.image.base.name` label, and compares the base image's
   `created` timestamp against the published image's `created` timestamp.
3. If the base is **newer** than the published image, it creates and pushes the
   next revision (`7.2.2-r6`). That tag push triggers `build-publish.yml`, which
   does the actual multi-arch rebuild and publish.

The refresh workflow only **decides and tags** — it never builds or pushes
images itself. It reads everything from the registry (no image pull) via
`docker buildx imagetools inspect --format '{{json .Image}}'`, so it needs a
recent Buildx (provided on the runner) and `jq`.

Comparing `created` timestamps (rather than base digests) is deliberate: the
shipped image records the base image **name**, not the digest it was built
against, so there is no recorded base digest to diff. The `created` timestamp is
always present for both images and answers exactly the question asked — "is
there a base image newer than the one we shipped?" — with no extra state to
maintain.

> **`RELEASE_PAT` is required for automation-created tags to publish
> automatically.** This applies to **both** `release-promote.yml` and
> `base-refresh.yml`: a tag pushed with the default `GITHUB_TOKEN` does **not**
> trigger other workflows (GitHub prevents recursive workflow runs), so
> `build-publish` would not fire. Configure a `RELEASE_PAT` repository secret —
> a fine-grained PAT with `contents: write`, or a classic PAT with `repo` — and
> the job pushes the new tag as that identity so `build-publish` runs. Without
> it, the tag is still created (using `GITHUB_TOKEN`) but the job **warns** that
> publishing did not start; a maintainer must then re-push the tag or run
> `build-publish` manually.

Both `release-promote.yml` and `base-refresh.yml` also support
`workflow_dispatch` with a `dry_run` input to report what they _would_ tag
without creating anything.

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
- `JS_CONTROLLER_VERSION` — the `iobroker.js-controller` version to install
  (passed straight through as the `--build-arg` of the same name). Defaults to
  the `stable` npm dist-tag. Set an exact version (e.g. `7.2.2`) to pin — the
  `Dockerfile` then verifies the installed version matches and fails the build
  otherwise. Dist-tags (`stable`, `latest`) and npm ranges skip that check. This
  is what CI passes from the release tag; locally it is handy for building an
  old-version image to test the upgrade path.

Examples:

```sh
# skip the verification gate for a fast inner-loop rebuild, custom tag:
RUN_VERIFY_GATE=false IMAGE_TAG=iobroker:dev npm run build:local

# multi-arch validation on bookworm:
DEBIAN_CODENAME=bookworm npm run build:local:multi

# build an image pinned to an older controller (e.g. to test the upgrade path):
JS_CONTROLLER_VERSION=7.1.0 npm run build:local
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

# Implementation Plan: Rootless ioBroker Container Image

## Overview

This plan converts the design into incremental coding tasks. The strategy is to factor all pure
decision logic (validators, reconciliation planner, healthcheck state function, default resolver,
database-backend config planner) into small testable JavaScript/TypeScript
modules first, prove them with `fast-check` property tests and unit tests, then assemble the shell
entrypoint/healthcheck glue that calls into that logic, then build the multi-stage Dockerfile that
wires everything into the image, then the CI/CD pipeline, and finally the documentation and
integration/smoke tests that exercise the built image.

Implementation languages:
- **Pure decision logic + tests:** JavaScript/TypeScript with `fast-check` (per design Testing Strategy).
- **Entrypoint / healthcheck / configurator glue:** POSIX shell / bash scripts that call the logic modules.
- **Image assembly:** Dockerfile (multi-stage) + GitHub Actions YAML.

Each property test runs a minimum of 100 iterations (`fc.assert(..., { numRuns: 100 })`), one test per
property, tagged exactly:
`// Feature: rootless-iobroker-container-image, Property {number}: {property_text}`

## Tasks

- [x] 1. Set up project structure and tooling
  - [x] 1.1 Scaffold repository layout and test tooling
    - Create repository layout: `Dockerfile`, `scripts/` (entrypoint.sh, healthcheck.sh), `lib/` (JS/TS logic modules), `test/` (unit + property tests), `docs/`, `.github/workflows/`.
    - Initialize the Node.js project (`package.json`) with a test runner and `fast-check` (`@fast-check/jest` or equivalent), plus lint/format config.
    - Add a Build_Config reader utility (reads `nodeMajor`/`debianCodename` from `package.json` `containerImage`) and confirm where the Node major version is read from.
    - Set up the test framework so `numRuns: 100` property tests can run.
    - _Requirements: 2.2, 5.4, 8.1_

- [x] 2. Implement configuration validation logic (pure module)
  - [x] 2.1 UID/GID range validator — RETIRED
    - The `IOB_UID`/`IOB_GID` variables were removed: UID/GID selection is
      delegated entirely to the container runtime (`--user` / `runAsUser`),
      because a non-root entrypoint cannot change its own UID/GID. The
      `validateUidGid` validator, its `UID_GID_MIN`/`MAX` constants, and their
      tests were removed. (Req 4.7)

  - [x] 2.2 UID/GID validation property test (Property 1) — RETIRED
    - Removed together with `validateUidGid` (see 2.1). The DB port/type + role
      validators (Property 11, task 2.4) remain.

  - [x] 2.3 Implement DB port + type + multihost role validators
    - Extend `lib/validate` with validators: `validateDbPort` (integer in 1–65535), `validateDbType` (jsonl|file|redis), `validateRole` (master|slave); each returns a rejection naming the invalid value.
    - _Requirements: 12.9_

  - [x] 2.4 Write property test for DB port, type, and role validation
    - **Property 11: Database port, type, and multihost role validation**
    - Generators: `fc.integer({min:-10, max:70000})` for port; `fc.oneof` of `master`/`slave`/random strings for role; `fc.oneof` of `jsonl`/`file`/`redis`/random strings for type.
    - **Validates: Requirements 12.9**

  - [x] 2.5 Write unit tests for validator edge cases
    - Test exact boundary values (1, 65535 for DB port), off-by-one rejections, non-integer inputs, role acceptance (master/slave), and type acceptance (jsonl/file/redis).
    - _Requirements: 12.9_

- [x] 3. Implement Node major version derivation (pure module)
  - [x] 3.1 Implement nodeMajor derivation from Build_Config
    - Write `lib/node-major.{ts,js}` that returns the integer major version iff the Build_Config `nodeMajor` field is a valid integer, and fails with an error and no derived value when missing, empty, whitespace, or non-integer — never falling back to a system default.
    - _Requirements: 5.4, 5.5_

  - [x] 3.2 Write property test for Node major derivation
    - **Property 2: Node major version is derived only from a valid integer Build_Config `nodeMajor` field, never falling back**
    - Generators: `fc.oneof` of valid integer strings, empty string, whitespace, non-numeric strings, absent field.
    - **Validates: Requirements 5.4, 5.5**

  - [x] 3.3 Write unit test for happy-path derivation
    - `"22"` → 22; confirm no fallback path exists.
    - _Requirements: 5.4_

- [x] 4. Implement default resolver logic (pure module)
  - [x] 4.1 Implement initial-snapshot default resolver
    - Write `lib/defaults.{ts,js}` that, given an initial env snapshot and the default table, resolves each variable to its snapshot value when set, or its default when unset, ignoring any mutations applied after the snapshot. Encode the default table from the Data Model (TZ, LANG, IOB_ADMIN_PORT, IOB_WEB_PORT, IOB_STARTUP_GRACE_PERIOD, IOB_UPGRADE_TOLERANCE_WINDOW). UID/GID are set by the container runtime; multihost/database-backend variables (IOB_MULTIHOST, IOB_OBJECTSDB_*, IOB_STATESDB_*) are opt-in and NOT defaulted.
    - _Requirements: 10.3, 10.4_

  - [x] 4.2 Write property test for default resolution
    - **Property 9: Defaults are resolved from the initial captured state only**
    - Generators: `fc.dictionary` for env snapshots plus a separate mutation map applied after snapshot.
    - **Validates: Requirements 10.4**

  - [x] 4.3 Write unit test for env naming convention
    - Assert every ioBroker var is `IOB_`-prefixed, `TZ`/`LANG` are unprefixed, and `SETUID`/`SETGID` are absent from the set.
    - _Requirements: 10.1, 10.2, 10.6, 10.7_

- [x] 5. Implement healthcheck state function (pure module)
  - [x] 5.1 Implement healthcheck state computation
    - Write `lib/health-state.{ts,js}` computing state from: check result (success/fail incl. 30s timeout as fail), elapsed vs Startup_Grace_Period, upgrade-in-progress flag + elapsed vs Upgrade_Tolerance_Window. Windows independent. Return healthy/starting/unhealthy and map to exit codes (0 healthy/starting, 1 unhealthy).
    - _Requirements: 9.2, 9.3, 9.4, 9.5, 9.10, 9.11_

  - [x] 5.2 Write property test for tolerance-window suppression
    - **Property 7: Healthcheck never reports unhealthy while inside either tolerance window**
    - Generators: `fc.boolean()` for check success, `fc.nat({max:7200})` elapsed times, windows from `fc.nat({max:3600})`, `fc.boolean()` upgrade-in-progress.
    - **Validates: Requirements 9.3, 9.4, 9.11**

  - [x] 5.3 Write property test for unhealthy-iff-outside-both-windows
    - **Property 8: Healthcheck reports unhealthy exactly when a check fails outside both windows**
    - Same generators as 5.2.
    - **Validates: Requirements 9.2, 9.5, 9.10**

  - [x] 5.4 Write unit tests for 30s timeout edges
    - fast-ok → 0, non-zero → fail, hang > 30s → fail.
    - _Requirements: 9.1, 9.2_

- [x] 6. Implement reconciliation planner (pure module)
  - [x] 6.1 Implement reconciliation decision planner
    - Write `lib/reconcile-plan.{ts,js}` producing a plan from inputs: desired adapter set (Data_Volume source of truth), adapters present in `node_modules` (content, not mount state), registry reachability, empty-Data_Volume flag, ABI-mismatch flag, rebuild-resource reachability. Emit actions: init-default-config, install-missing, npm-rebuild, warn-and-start (content-based convergence; install-full-set/use-persisted retired since mount state is not reliably detectable across runtimes). Never fail startup when the registry is unreachable.
    - _Requirements: 8.5, 8.6, 8.9, 8.10, 8.11, 8.12, 8.13_

  - [x] 6.2 Write property test for convergence to Data_Volume set
    - **Property 3: Reconciliation converges the installed adapter set to the Data_Volume when the registry is reachable**
    - Generators: `fc.array(fc.string())` desired/present adapter sets (content-based; no mount-state input).
    - **Validates: Requirements 8.5, 8.9, 8.10**

  - [x] 6.3 Write property test for idempotency
    - **Property 4: Reconciliation is idempotent**
    - Run the planner twice against the in-memory model; assert equal installed set.
    - **Validates: Requirements 8.9, 8.10, 8.11**

  - [x] 6.4 Write property test for offline-usable start
    - **Property 5: Reconciliation always starts the runtime when modules are usable offline**
    - Generators: present `node_modules` content + unreachable registry combos.
    - **Validates: Requirements 8.11**

  - [x] 6.5 Write property test for ABI-mismatch always-start
    - **Property 6: ABI-mismatch handling always ends in a started runtime**
    - Generators: `fc.boolean()` ABI-mismatch × `fc.boolean()` rebuild-resource reachability.
    - **Validates: Requirements 8.12, 8.13**

  - [x] 6.6 Write unit test for empty Data_Volume initialization decision
    - Assert empty Data_Volume yields init-default-config action.
    - _Requirements: 8.6_

- [x] 7. Implement database-backend config planner (pure module)
  - [x] 7.1 Implement objects/states DB config planner
    - Write `lib/db-plan.{ts,js}` planning the objects and states databases independently (each type/host/port/name/pass) plus multihost role. Compare only operator-SPECIFIED fields against the current config: no-op when identical or nothing specified (leave local jsonl config untouched), patch only specified fields when they differ. Validate type/port/role before planning.
    - _Requirements: 12.1, 12.2, 12.3, 12.4, 12.5, 12.6, 12.7, 12.8, 12.9_

  - [x] 7.2 Write property test for DB config idempotency
    - **Property 10: Database/multihost configuration is re-applied if and only if the specified IOB_* values change**
    - Generators: `fc.record` pairs of previous/desired DB-section + role values.
    - **Validates: Requirements 12.3, 12.7, 12.8**

  - [x] 7.3 Write unit test for DB config mapping / no-op
    - Nothing specified → no-op (local config untouched); objects/states configured independently with own host/port; role wiring; invalid type/port/role rejected naming the value.
    - _Requirements: 12.1, 12.2, 12.3, 12.4, 12.5, 12.6, 12.9_

- [x] 8. Shutdown ordering — RETIRED
  - Forced-termination ordering is no longer implemented in-image. `tini` (PID 1)
    forwards SIGTERM to js-controller and reaps zombies; the eventual SIGKILL is
    delegated to the container runtime's stop timeout (Docker `--stop-timeout`,
    Kubernetes `terminationGracePeriodSeconds`). The former `lib/shutdown-model.js`
    pure module and its property test (Property 12) were removed. (Req 14.2, 14.3)

- [x] 9. Checkpoint - Ensure all logic-module tests pass
  - Ensure all property and unit tests for tasks 2–8 pass, ask the user if questions arise.

- [x] 10. Implement npm settings manager
  - [x] 10.1 Implement .npmrc writer/validator
    - Write logic (module + shell glue) that ensures `.npmrc` contains `audit=false`, `update-notifier=false`, `engine-strict=true` at the ioBroker install location, and blocks adapter installation when the settings file is corrupt or inaccessible rather than falling back to default npm behavior.
    - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5_

  - [x] 10.2 Write unit tests for .npmrc contents and block-on-corrupt
    - Assert file contains the three settings; corrupt/removed `.npmrc` blocks install.
    - _Requirements: 11.1, 11.2, 11.3, 11.5_

- [x] 11. Implement entrypoint script and configurator glue
  - [x] 11.1 Implement `scripts/entrypoint.sh` pipeline
    - Ordered sequence: capture initial env snapshot → resolve defaults (via `lib/defaults`) → apply TZ/LANG + timezone → handle arbitrary-UID access (runtime-assigned UID; when UID absent from `/etc/passwd`, rely on GID-0 group-writable data dirs) → ensure `.npmrc` → run reconciliation (via `lib/reconcile-plan`, incl. `iobroker setup first` on empty Data_Volume) → configure objects/states DB backends + multihost role (via `scripts/configure-db.sh` / `lib/db-plan`, patch only specified fields, idempotent) → `exec` js-controller. Database/type/port/role validation happens in the DB configurator, exiting non-zero naming an invalid value. Never source any user startup script; ignore any mounted startup script.
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 10.4, 10.5, 11.4, 12.9, 13.1, 13.2, 13.3_

  - [x] 11.2 Shutdown handling — RETIRED (delegated to tini + container runtime)
    - No `scripts/shutdown-supervisor.sh`. `tini` forwards SIGTERM to js-controller
      and propagates its exit code / terminating signal; the container runtime's
      stop timeout enforces the eventual SIGKILL. (Req 14.2, 14.3, 14.4)

  - [x] 11.3 Implement reconciliation shell glue
    - Wire `scripts/reconcile.sh` (invoked from the entrypoint): empty-Data_Volume init + fresh-install `admin` bootstrap, registry reachability probe via `npm ping`, content-based install-missing of recorded adapters not present in `node_modules`, ABI mismatch detection + `npm rebuild` with warn-and-still-start fallback, driving the plan from `lib/reconcile-plan`. Content-based (no mount detection).
    - _Requirements: 8.6, 8.9, 8.10, 8.11, 8.12, 8.13_

  - [x] 11.4 Implement database-backend configurator shell glue
    - `scripts/configure-db.sh`: read operator IOB_OBJECTSDB_* / IOB_STATESDB_* / IOB_MULTIHOST + current iobroker.json, ask `lib/db-plan` for the plan, and patch only the specified objects/states fields (type/host/port/name/pass) + multihost role via `iobroker.json` patching and the `iobroker` CLI, idempotently; no-op when nothing specified.
    - _Requirements: 12.1, 12.2, 12.3, 12.4, 12.5, 12.6, 12.7, 12.8_

- [x] 12. Implement healthcheck script
  - [x] 12.1 Implement `scripts/healthcheck.sh`
    - Run `iobroker status` with a 30s per-check timeout (success only on exit 0 within timeout); read Startup_Grace_Period / Upgrade_Tolerance_Window from env with defaults 300/600; detect upgrade-in-progress via sentinel marker and/or running upgrade process; compute final state via `lib/health-state` and return the mapped exit code.
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 9.7, 9.8, 9.9, 9.10, 9.11_

- [x] 13. Checkpoint - Ensure entrypoint/healthcheck scripts and tests pass
  - Ensure all tests pass and scripts lint/shellcheck cleanly, ask the user if questions arise.

- [x] 14. Author the multi-stage Dockerfile
  - [x] 14.1 Implement Build_Stage
    - `FROM node:${NODE_MAJOR}-${DEBIAN_CODENAME}` (global build args; `DEBIAN_CODENAME` default `trixie`) with `ARG NODE_MAJOR`; install build toolchain and `-dev` headers (build-essential, gcc, make, cmake, pkg-config, libavahi-compat-libdnssd-dev, libudev-dev, libpam0g-dev, libcairo2-dev, libpango1.0-dev, libjpeg-dev, libgif-dev, librsvg2-dev, libpixman-1-dev) without version pinning; install **only the ioBroker js-controller** (no bundled adapters — the Data_Volume is the source of truth and reconciliation installs adapters at runtime) under `/opt/iobroker`; compile its native `node_modules` using the derived NODE_MAJOR.
    - _Requirements: 2.2, 5.1, 5.4, 5.6_

  - [x] 14.2 Implement Runtime_Image stage
    - `FROM node:${NODE_MAJOR}-${DEBIAN_CODENAME}-slim` (same args as the Build_Stage); install runtime packages (acl, sudo, libcap2-bin, git, curl, unzip, distro-info, net-tools, polkitd, passwd, lsb-release) plus runtime shared libs (libcairo2, libpango-1.0-0, librsvg2-2, libpixman-1-0, libjpeg62-turbo, libgif7, libudev1, libpam0g, libavahi-compat-libdnssd1) without version pinning; `COPY --from=Build_Stage /opt/iobroker /opt/iobroker`; copy entrypoint/healthcheck scripts and lib modules; exclude toolchain/`-dev` headers.
    - _Requirements: 2.1, 2.3, 2.4, 2.8, 5.2, 5.3, 5.6_

  - [x] 14.3 Apply capabilities, container-env indicators, user model, and image metadata
    - Apply **no** file capabilities to the Node binary (the `setcap cap_net_bind_service,cap_net_raw+ep` is intentionally omitted so node can `exec` in a fully-rootless container); create `/.dockerenv` and `/run/.containerenv`; create Container_User uid/gid 1000, set GID 0 group ownership + `2775` setgid mode + `g+rwX` on `/opt/iobroker`, `iobroker-data`, `log`, `node_modules`, and `0664` GID-0 on `.npmrc`; set `USER 1000`; declare `VOLUME` mount points; set `HEALTHCHECK` and `ENTRYPOINT ["/usr/bin/tini","--","/entrypoint.sh"]`; install tini; add OCI labels including `org.opencontainers.image.source` pointing at the source repository `ioBroker.container-image`, so the GHCR package (published under a different name) links back to its repo.
    - _Requirements: 1.3, 3.1, 3.2, 4.4, 4.5, 4.6, 6.1, 6.2, 6.3, 7.1, 8.2, 8.3, 8.4, 9.6, 14.1_

- [x] 15. Implement runtime-dependency verification gate
  - [x] 15.1 Implement in-Dockerfile verification gate stage
    - Add a build stage `RUN` step that asserts runtime packages present (`dpkg -s`), toolchain/`-dev` headers absent (`dpkg -s` fails), `ldd` over compiled `.node` files resolves, and a js-controller/`iobroker status` smoke start succeeds; exit non-zero naming the missing dependency to fail the build and block publish.
    - _Requirements: 2.6, 2.7, 2.9, 5.2, 5.3_

- [x] 16. Implement GitHub Actions CI/CD pipeline
  - [x] 16.1 Implement multi-arch build-and-publish workflow
    - Add `.github/workflows/` using `docker/setup-qemu-action` + `docker/setup-buildx-action`; read `NODE_MAJOR` (from `nodeMajor`) and `DEBIAN_CODENAME` (from `debianCodename`) once from the `package.json` `containerImage` Build_Config and fail the workflow before any build if either is missing/empty/invalid (fail-fast in ALL trigger modes); `docker/build-push-action` with `--platform linux/amd64,linux/arm64`; set the published image name explicitly as `ghcr.io/fernetmenta/iobroker` (the `images:` value of the build-push/metadata step), NOT derived from `github.repository` (which would be `ghcr.io/fernetmenta/iobroker.container-image`) — note GHCR package names are lowercase (`ioBroker` → `iobroker`); run the runtime-dependency gate per arch; push a single multi-arch manifest to ghcr.io under that name with the shared immutable version tag + `latest` applied to the single manifest, only after both arch builds and gates succeed (all-or-nothing), reporting the failing architecture on failure.
    - **Trigger model and versioning:**
      - PUBLISH only on a pushed git tag matching `v*` (e.g. `v1.2.3`); the git tag is the source of the immutable image version tag applied to `ghcr.io/fernetmenta/iobroker` alongside `latest`. Compute the version/`latest` tags via `docker/metadata-action` semver from the git ref.
      - On pull requests and pushes to `main`, run BUILD-ONLY (no push) but still build BOTH architectures and run the runtime-dependency verification gate.
      - Support a manual `workflow_dispatch` dry-run build (no push).
      - Gate the push on the git ref (e.g. `push: ${{ startsWith(github.ref, 'refs/tags/v') }}`) so only tag pushes publish; only builds triggered by a `v*` tag push produce and push the immutable version tag + `latest`.
      - Set the `org.opencontainers.image.source` label to the source repo via `docker/metadata-action`.
    - _Requirements: 1.1, 1.2, 1.3, 1.6, 1.8, 2.6, 2.7, 5.4, 5.5, 5.7_

  - [x] 16.2 Provide and document a local build path
    - Provide a documented `docker buildx build` command (and/or a `Makefile`/npm script target) that builds the image locally, mirroring CI: read `NODE_MAJOR` and `DEBIAN_CODENAME` from the `package.json` `containerImage` Build_Config (same as CI) and pass them as `--build-arg NODE_MAJOR=...` and `--build-arg DEBIAN_CODENAME=...`.
    - Support both single-arch (local host platform) and multi-arch builds, and do NOT push by default.
    - Ensure the local build and the CI build are equivalent: same `Dockerfile`, same Build_Config read (NODE_MAJOR + DEBIAN_CODENAME), same runtime-dependency gate, so a local build reproduces what CI builds (Req 2 build correctness).
    - _Requirements: 2.2, 5.4, 5.5, 5.7_

- [x] 17. Author documentation deliverables
  - [x] 17.1 Write environment variable reference
    - Document the retained env variable set with each name and default value, and document the removed `SETUID`/`SETGID` variables.
    - _Requirements: 10.8_

  - [x] 17.2 Write rootless capability and limitations documentation
    - Document privileged-port behavior (capabilities present but not effective without added runtime caps), NET_ADMIN requirement, and the works-without-caps vs requires-caps function lists.
    - _Requirements: 7.2, 7.3, 7.4, 7.5_

  - [x] 17.3 Write volume/persistence and multihost usage documentation
    - Document Data_Volume/Log_Volume/Modules_Volume layout and persistence behavior, and multihost/Redis usage including k8s liveness/readiness probe examples.
    - _Requirements: 8.2, 8.3, 8.4, 9.7, 12.1, 12.2, 12.3, 12.4, 12.5, 12.6_

- [x] 18. Checkpoint - Ensure image builds and gate passes
  - Verify the documented local build path works: the multi-arch and single-arch image builds locally via the documented command (task 16.2), and the runtime-dependency gate passes. Ask the user if questions arise.

- [x] 19. Implement integration / smoke tests
  - [x] 19.1 Write manifest and image-size smoke tests
    - `docker buildx imagetools inspect` shows amd64 + arm64 under one tag; unsupported-arch pull rejected; image size meaningfully below ~1.6 GB.
    - _Requirements: 1.3, 1.4, 1.5, 1.6, 1.7, 2.5_

  - [x] 19.2 Write runtime-dependency and packaging smoke tests
    - `dpkg -s` runtime pkgs present / toolchain absent; `ldd` over native `.node` files; js-controller smoke start; `getcap` on node binary shows **no** file capabilities (node is intentionally not setcap'd for rootless exec).
    - _Requirements: 2.3, 2.6, 5.2, 5.3, 7.1_

  - [x] 19.3 Write rootless and arbitrary-UID smoke tests
    - Runs non-root (`id` ≠ 0, no sudo in normal path) on Docker/Podman rootless/k3s; arbitrary `runAsUser` reads/writes Data_Volume + Log_Volume via GID 0; `/.dockerenv`, `/run/.containerenv`, cgroup indicator present.
    - _Requirements: 3.3, 3.4, 3.5, 3.6, 4.5, 4.6, 6.1, 6.2, 6.3_

  - [x] 19.4 Write PID 1 signal/zombie and startup-script smoke tests
    - SIGTERM triggers graceful shutdown, exit code propagated, orphaned child reaped (no zombies) under Docker/Podman/k3s; empty Data_Volume initializes defaults; mounted user startup script ignored/not executed.
    - _Requirements: 8.6, 13.1, 13.2, 13.3, 14.1, 14.4, 14.5, 14.6_

- [x] 20. Final checkpoint - Ensure all tests pass
  - Ensure all property, unit, and integration/smoke tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP; they are test tasks (property, unit, integration/smoke).
- Each task references specific granular requirements for traceability.
- Checkpoints ensure incremental validation.
- Property tests validate the 12 universal correctness properties (one test per property, ≥100 iterations, tagged as specified in the design Testing Strategy).
- Unit tests validate concrete mappings and edge cases; integration/smoke tests validate infrastructure behavior after the image can be built.
- Pure logic modules (tasks 2–8) and their tests are built before/alongside the container assembly (tasks 11–15); integration/smoke tests (task 19) come after the image can be built (task 18).

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["2.1", "3.1", "4.1", "5.1", "6.1", "7.1", "8.1"] },
    { "id": 2, "tasks": ["2.2", "2.3", "3.2", "3.3", "4.2", "4.3", "5.2", "5.3", "5.4", "6.2", "6.3", "6.4", "6.5", "6.6", "7.2", "7.3", "8.2", "10.1"] },
    { "id": 3, "tasks": ["2.4", "2.5", "10.2", "11.1", "11.2", "11.3", "11.4", "12.1"] },
    { "id": 4, "tasks": ["14.1"] },
    { "id": 5, "tasks": ["14.2"] },
    { "id": 6, "tasks": ["14.3"] },
    { "id": 7, "tasks": ["15.1", "16.1", "16.2", "17.1", "17.2", "17.3"] },
    { "id": 8, "tasks": ["19.1", "19.2", "19.3", "19.4"] }
  ]
}
```

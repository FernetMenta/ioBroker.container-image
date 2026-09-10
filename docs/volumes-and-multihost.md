# Volumes, Persistence, and Multihost

This document describes the persistence layout of the rootless ioBroker
container image, how data survives restarts and image upgrades, how the startup
reconciliation behaves, how to run a multihost cluster (networked jsonl or Redis), and how
to wire the container's healthcheck into Kubernetes liveness/readiness probes.

It covers the persistence acceptance criteria of Requirement 8
(Req 8.2, 8.3, 8.4), the Kubernetes-probe criterion of Requirement 9
(Req 9.7), and the multihost/database-backend criteria of Requirement 12
(Req 12.1–12.9).

The image installs ioBroker under `/opt/iobroker`, ships its entrypoint and
helper scripts under `/opt/scripts` (with decision modules under `/opt/lib`),
and exposes the healthcheck at `/opt/scripts/healthcheck.sh`.

> **Upgrading?** js-controller and the runtime are upgraded by pulling a newer
> image and recreating the container — see the dedicated
> [Upgrade guide](./upgrading.md). This page focuses on the persistence layout
> those upgrades rely on.

## Persistence layout

The image persists only the folders that hold configuration, state, logs, and
(optionally) installed adapter code — you never need to bind-mount the whole
`/opt/iobroker` installation. Three mount points are declared as volumes:

| Mount point                   | Name           | Required    | What it holds                                                                                                       |
| ----------------------------- | -------------- | ----------- | ------------------------------------------------------------------------------------------------------------------- |
| `/opt/iobroker/iobroker-data` | Data_Volume    | Recommended | ioBroker configuration + state. **Source of truth** for the set of installed adapters and their versions. (Req 8.2) |
| `/opt/iobroker/log`           | Log_Volume     | Recommended | ioBroker logs. (Req 8.3)                                                                                            |
| `/opt/iobroker/node_modules`  | Modules_Volume | Optional    | Installed adapter code, persisted across container upgrades. (Req 8.4)                                              |

Key point: the **Data_Volume is authoritative**. It records which adapters (and
which versions) are installed. Installed adapter code in `node_modules` is
reconciled to match what the Data_Volume records — never the other way around.

### Persistence behavior

- **Across restarts.** When the container is restarted with the Data_Volume and
  Log_Volume persisted, ioBroker retains all configuration and state stored in
  the Data_Volume, and log history in the Log_Volume is preserved.
- **Across image upgrades.** When you pull a newer image version and start it
  with the Data_Volume persisted, configuration and state carry over unchanged.
  The new image brings updated runtime code; your data stays put.
- **First start with an empty Data_Volume.** The runtime initializes the
  Data_Volume with a default ioBroker configuration and state, then continues
  normally.

### Reconciliation at startup (usage view)

On each start, before ioBroker runs, the entrypoint reconciles the installed
adapter code against the adapters recorded in the Data_Volume. What happens
depends on two things: whether the Modules_Volume is mounted, and whether the
adapter registry is reachable.

| Modules_Volume mounted? | Registry reachable? | Behavior                                                                                                                              |
| ----------------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| No (default)            | Yes                 | Installs the full set of adapters recorded in the Data_Volume from the registry, so the installed set matches the Data_Volume.        |
| No (default)            | No                  | Starts with whatever is present and logs a warning; adapters recorded in the Data_Volume but not installed cannot be fetched offline. |
| Yes                     | Yes                 | Treats the persisted `node_modules` as authoritative and installs only the Data_Volume adapters that are **missing** from it.         |
| Yes                     | No                  | Starts using the persisted `node_modules` **without failing** — offline operation is supported.                                       |

Additionally, if the Node.js ABI of the running image differs from the ABI the
persisted native modules were built for (which can happen after an image
upgrade that changes the Node version), reconciliation attempts an `npm rebuild`
of the affected native modules. The image records the built-against ABI in a
`node_modules/.node-abi` marker that travels with the persisted Modules_Volume;
the reconciler compares it to the running Node's ABI to decide whether a rebuild
is needed, and refreshes it after a successful rebuild. If a rebuild is needed
but the registry or build resources are unreachable, it logs a warning naming
the affected modules and still starts the runtime. See
[Node.js major upgrades and the Modules_Volume](#nodejs-major-upgrades-and-the-modules_volume).

**Practical guidance:**

- For most single-host deployments, persist the **Data_Volume** and
  **Log_Volume**. Adapter code is re-fetched from the registry as needed, which
  keeps your persisted footprint small.
- Mount the **Modules_Volume** as well when you want adapter code (including
  natively compiled modules) to survive upgrades without a network round trip,
  or when you need the container to start adapters while the registry is
  unreachable (air-gapped or restricted environments).

### Named volumes vs. host bind mounts

How the mount is seeded on first start differs by mount type, and this matters
most for the Modules_Volume:

- **Named volumes** (e.g. `-v iobroker-modules:/opt/iobroker/node_modules`):
  Docker/Podman seed an _empty_ named volume from the image's directory content
  the first time it is mounted, so the volume starts pre-populated with what the
  image shipped. This is the documented, recommended form.
- **Host bind mounts** (e.g. `-v /data/on-host:/opt/iobroker/node_modules`):
  bind mounts are **never** seeded from the image. Whatever is on the host path
  is what the container sees, and it fully shadows the image content.

**Why this matters most for the Modules_Volume:** `/opt/iobroker/node_modules`
is not just adapter code — it is where **js-controller itself and its entire
dependency tree live**. The entrypoint execs
`/opt/iobroker/node_modules/iobroker.js-controller/controller.js` and refuses to
start if that file is missing. So:

- An **empty host bind mount** over `node_modules` shadows the image's
  js-controller with nothing. The container fails to start (`js-controller not
found`), and reconciliation **cannot** recover it: reconciliation only runs
  `iobroker install <adapter>` for adapters and `npm rebuild` for native modules —
  it never reconstructs js-controller or its dependencies, and the `iobroker`
  CLI it would need is itself missing. **Do not bind-mount an empty host
  directory over `node_modules`.**
- A **named volume** does not have this problem: Docker/Podman seed an empty
  named volume from the image on first mount, so js-controller and its
  dependencies are copied in before the first start. This is why every
  Modules_Volume example in this document uses a named volume.
- A **non-empty host bind mount** is only safe if its content is a complete,
  ABI-compatible `node_modules` for this image — for example one this exact
  image previously wrote. It stays fragile across image / Node.js upgrades (see
  below).

By contrast, an **empty** Data_Volume or Log_Volume bind mount **is** fine: the
Data_Volume is initialized by `iobroker setup first` on first start, and the log
directory is just written into. The "empty bind mount is a problem" caveat is
specific to `node_modules`, because that mount point contains the runtime
itself.

With a host bind mount you also own the directory's ownership and permissions.
The entrypoint makes a best-effort `chgrp 0` + group-writable adjustment for the
arbitrary-UID case, but a root-owned host directory may still need you to fix
ownership so uid 1000 (or GID 0) can write to it.

### Node.js major upgrades and the Modules_Volume

Natively compiled modules are built against a specific Node.js ABI. When you
move to an image built on a **new Node.js major** (for example Node 22 → Node
26), native modules persisted in the Modules_Volume were compiled for the old
ABI and may be incompatible with the new runtime. In that state js-controller or
individual adapters can fail to start.

**Automatic rebuild.** The image records the Node.js ABI its native modules were
built against in a marker file (`node_modules/.node-abi`) that travels with the
persisted Modules_Volume. On each start the reconciler compares that marker to
the running Node's ABI; on a mismatch it runs `npm rebuild` of the affected
native modules and then refreshes the marker, so the rebuild is a one-time cost
per Node major upgrade. This covers modules that ship prebuilt binaries for the
new ABI or are pure-JS.

**When you still need to intervene.** The default slim runtime ships **no
compiler toolchain**, so a native module that must be _compiled_ (no prebuilt
binary for your architecture and the new ABI) cannot be rebuilt in place — the
reconciler logs a warning naming it and starts anyway, which can leave that
adapter broken. For those cases, either clear/recreate the Modules_Volume so the
adapter is reinstalled fresh from the registry, or use a derived image with a
build toolchain (see
[Adapters with native code and no prebuilt binary](#adapters-with-native-code-and-no-prebuilt-binary)).

**What to do after a Node major upgrade if you persist the Modules_Volume:**

- If you do **not** persist the Modules_Volume (Data_Volume + Log_Volume only):
  nothing to do. `node_modules` is rebuilt from the registry against the new
  Node, so there is no stale native code to worry about.
- If you **do** persist the Modules_Volume and adapters misbehave or
  js-controller does not come up after the upgrade: **recreate the
  Modules_Volume from the new image** and start again. With the Data_Volume
  intact (it is the source of truth for which adapters are installed), the new
  image supplies the new js-controller and reconciliation reinstalls the
  recorded adapter set fresh against the new Node major (requires registry
  connectivity).

  The important detail is that the volume must be **re-seeded from the image**,
  which only happens for a **named volume**:

  ```bash
  # Docker: remove and recreate the modules NAMED volume, keep data + log.
  # A fresh empty named volume is re-seeded from the new image on next start,
  # so the new js-controller + its dependencies are copied back in.
  docker rm -f iobroker
  docker volume rm iobroker-modules
  docker volume create iobroker-modules
  # start the container again with the same -v flags
  ```

  For **Kubernetes**, delete and recreate the Modules_Volume PVC (leaving the
  Data_Volume and Log_Volume PVCs untouched); the fresh volume is populated from
  the new image the same way.

  > **Do not simply empty a host bind-mount directory.** Unlike a named volume,
  > a bind mount is never re-seeded from the image, so emptying it leaves
  > js-controller missing and the container will not start. If you use a host
  > bind mount for `node_modules`, either switch to a named volume, or
  > repopulate the directory from the new image yourself (for example, copy
  > `/opt/iobroker/node_modules` out of a throwaway container of the new image
  > into the host path) before starting.

- Adapters whose native code must be **compiled** (no prebuilt binary for your
  architecture) are the exception noted under "When you still need to intervene"
  above: the automatic rebuild cannot help them in the default slim image, so
  clear/recreate the Modules_Volume or use a derived image with a build
  toolchain (see
  [Adapters with native code and no prebuilt binary](#adapters-with-native-code-and-no-prebuilt-binary)).

## What ships in the image (no bundled adapters)

The image bundles **only the ioBroker `js-controller`** — it does **not** ship
any adapters (not even `admin`). This keeps the image about half the size of the
classic reference image. Adapters are installed at runtime by reconciliation
from the adapter registry, because the **Data_Volume is the source of truth** for
which adapters are installed.

What this means in practice:

- **First start (fresh Data_Volume, registry reachable):** reconciliation
  installs the recorded adapter set — including `admin` — from the registry. The
  admin UI becomes available once that first install completes.
- **First start with no internet:** js-controller starts, but there is no admin
  UI (or other adapters) until connectivity is restored and reconciliation can
  fetch them. Fresh installs are expected to have internet.
- **Updates:** unchanged from the persistence behavior above — persisted
  `node_modules` is reused; otherwise adapters are re-fetched from the registry.

### Adapters with native code and no prebuilt binary

The runtime image ships **no compiler toolchain** (that is what keeps it slim and
rootless). Almost all adapters are pure JavaScript or ship prebuilt native
binaries, so they install at runtime without a compiler. A small number of
adapters have native code with **no** prebuilt binary for your architecture; those
cannot be compiled inside the default image.

If you need such an adapter, build a **derived image** that adds a build
toolchain — a reproducible, build-time choice that keeps the default image slim
and avoids running `apt`/root at container startup:

```dockerfile
FROM ghcr.io/<owner>/iobroker:latest
USER root
RUN apt-get update \
    && apt-get install --no-install-recommends -y build-essential python3 pkg-config \
    && rm -rf /var/lib/apt/lists/*
USER 1000
```

Then use your derived image in place of the base one. (There is intentionally no
runtime environment variable to install a toolchain: that would require root and
network at every start and would undermine the rootless, reproducible design.)

## Volume mount examples

### Docker

```bash
docker run -d \
  --name iobroker \
  -p 8081:8081 \
  -p 8082:8082 \
  -v iobroker-data:/opt/iobroker/iobroker-data \
  -v iobroker-log:/opt/iobroker/log \
  ghcr.io/fernetmenta/iobroker
```

Add the optional Modules_Volume to persist adapter code across upgrades:

```bash
docker run -d \
  --name iobroker \
  -p 8081:8081 \
  -p 8082:8082 \
  -v iobroker-data:/opt/iobroker/iobroker-data \
  -v iobroker-log:/opt/iobroker/log \
  -v iobroker-modules:/opt/iobroker/node_modules \
  ghcr.io/fernetmenta/iobroker
```

### Podman

Podman uses the same volume syntax as Docker:

```bash
podman run -d \
  --name iobroker \
  -p 8081:8081 \
  -p 8082:8082 \
  -v iobroker-data:/opt/iobroker/iobroker-data \
  -v iobroker-log:/opt/iobroker/log \
  ghcr.io/fernetmenta/iobroker
```

### docker-compose

```yaml
services:
  iobroker:
    image: ghcr.io/fernetmenta/iobroker
    container_name: iobroker
    ports:
      - '8081:8081' # admin UI (IOB_ADMIN_PORT)
      - '8082:8082' # web adapter (IOB_WEB_PORT)
    volumes:
      - iobroker-data:/opt/iobroker/iobroker-data
      - iobroker-log:/opt/iobroker/log
      # Optional: persist adapter code across upgrades
      - iobroker-modules:/opt/iobroker/node_modules

volumes:
  iobroker-data:
  iobroker-log:
  iobroker-modules:
```

### Kubernetes (PVCs)

Declare a PersistentVolumeClaim per volume and mount them into the container.
The Data_Volume and Log_Volume are recommended; the Modules_Volume is optional.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: iobroker-data
spec:
  accessModes: ['ReadWriteOnce']
  resources:
    requests:
      storage: 2Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: iobroker-log
spec:
  accessModes: ['ReadWriteOnce']
  resources:
    requests:
      storage: 1Gi
---
# Optional
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: iobroker-modules
spec:
  accessModes: ['ReadWriteOnce']
  resources:
    requests:
      storage: 4Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: iobroker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: iobroker
  template:
    metadata:
      labels:
        app: iobroker
    spec:
      securityContext:
        runAsNonRoot: true
        # Arbitrary UID is supported; GID 0 makes the volumes writable.
        fsGroup: 0
      containers:
        - name: iobroker
          image: ghcr.io/fernetmenta/iobroker
          ports:
            - containerPort: 8081 # admin UI
            - containerPort: 8082 # web adapter
          volumeMounts:
            - name: iobroker-data
              mountPath: /opt/iobroker/iobroker-data
            - name: iobroker-log
              mountPath: /opt/iobroker/log
            # Optional Modules_Volume:
            - name: iobroker-modules
              mountPath: /opt/iobroker/node_modules
      volumes:
        - name: iobroker-data
          persistentVolumeClaim:
            claimName: iobroker-data
        - name: iobroker-log
          persistentVolumeClaim:
            claimName: iobroker-log
        - name: iobroker-modules
          persistentVolumeClaim:
            claimName: iobroker-modules
```

> The writable directories are group-owned by GID 0 and group-writable, so an
> arbitrary `runAsUser` combined with `fsGroup: 0` (or membership in GID 0) has
> read/write access to the Data_Volume and Log_Volume. See
> [environment-variables.md](./environment-variables.md) for `IOB_UID`/`IOB_GID`
> and the UID/GID override behavior.

## Multihost and database backends

ioBroker keeps **objects** and **states** in two separate databases, each with
its own **type** (`jsonl` — the network-capable default, `file`, or `redis`),
**host**, and **port**. Multihost does **not** require Redis: the common setup
uses networked `jsonl` where a slave points its objects/states databases at the
master.

### How it works

- The objects DB and the states DB are configured **independently** and may use
  **different ports** (for `jsonl` the defaults are objects `9001`, states
  `9000`). (Req 12.1)
- Supported types: `jsonl`, `file`, `redis`. (Req 12.2)
- **Standalone (default):** set none of the database/multihost variables. The
  container keeps the local `jsonl` databases created at first start and does
  not touch `iobroker.json`. (Req 12.3)
- **Configure a DB:** set `IOB_OBJECTSDB_{TYPE,HOST,PORT}` and/or
  `IOB_STATESDB_{TYPE,HOST,PORT}` (optional `_NAME` / `_PASS`). Only the fields
  you set are applied. (Req 12.4, 12.5)
- **Role:** `IOB_MULTIHOST=master` or `IOB_MULTIHOST=slave`; unset = standalone.
  (Req 12.6)
- Invalid type/port/role stops startup with an error naming the value. (Req 12.9)
- Idempotent: restarting with the same values changes nothing; changing a value
  re-applies just that field. (Req 12.7, 12.8)

### Variables

| Variable                                    | Values                       | Purpose                               |
| ------------------------------------------- | ---------------------------- | ------------------------------------- |
| `IOB_MULTIHOST`                             | `master` \| `slave`          | Multihost role (unset = standalone).  |
| `IOB_OBJECTSDB_TYPE`                        | `jsonl` \| `file` \| `redis` | Objects DB type.                      |
| `IOB_OBJECTSDB_HOST`                        | hostname / IP                | Objects DB host (e.g. the master).    |
| `IOB_OBJECTSDB_PORT`                        | `1`–`65535`                  | Objects DB port (jsonl default 9001). |
| `IOB_OBJECTSDB_NAME` / `IOB_OBJECTSDB_PASS` | string                       | Optional objects DB name / password.  |
| `IOB_STATESDB_TYPE`                         | `jsonl` \| `file` \| `redis` | States DB type.                       |
| `IOB_STATESDB_HOST`                         | hostname / IP                | States DB host.                       |
| `IOB_STATESDB_PORT`                         | `1`–`65535`                  | States DB port (jsonl default 9000).  |
| `IOB_STATESDB_NAME` / `IOB_STATESDB_PASS`   | string                       | Optional states DB name / password.   |

### Docker: master + slave over networked jsonl (no Redis)

The **master** runs normally (standalone-style) and serves its `jsonl`
databases on the network. A **slave** points its objects/states databases at the
master:

```bash
# Slave, connecting to the master host "iob"
docker run -d \
  --name iobroker-slave \
  -e IOB_MULTIHOST=slave \
  -e IOB_OBJECTSDB_TYPE=jsonl \
  -e IOB_OBJECTSDB_HOST=iob \
  -e IOB_OBJECTSDB_PORT=9001 \
  -e IOB_STATESDB_TYPE=jsonl \
  -e IOB_STATESDB_HOST=iob \
  -e IOB_STATESDB_PORT=9000 \
  -v iobroker-data-slave:/opt/iobroker/iobroker-data \
  -v iobroker-log-slave:/opt/iobroker/log \
  ghcr.io/fernetmenta/iobroker
```

### Docker: external Redis backend

To use Redis instead, set the DB types to `redis` and point at the Redis host:

```bash
docker run -d \
  --name iobroker \
  -e IOB_OBJECTSDB_TYPE=redis -e IOB_OBJECTSDB_HOST=redis.example.internal -e IOB_OBJECTSDB_PORT=6379 \
  -e IOB_STATESDB_TYPE=redis  -e IOB_STATESDB_HOST=redis.example.internal  -e IOB_STATESDB_PORT=6379 \
  -v iobroker-data:/opt/iobroker/iobroker-data \
  -v iobroker-log:/opt/iobroker/log \
  ghcr.io/fernetmenta/iobroker
```

### Kubernetes: slave pointing at the master's jsonl databases

```yaml
env:
  - name: IOB_MULTIHOST
    value: 'slave'
  - name: IOB_OBJECTSDB_TYPE
    value: 'jsonl'
  - name: IOB_OBJECTSDB_HOST
    value: 'iobroker-master' # in-cluster Service of the master
  - name: IOB_OBJECTSDB_PORT
    value: '9001'
  - name: IOB_STATESDB_TYPE
    value: 'jsonl'
  - name: IOB_STATESDB_HOST
    value: 'iobroker-master'
  - name: IOB_STATESDB_PORT
    value: '9000'
```

For a Redis-backed cluster, set the `*_TYPE` values to `redis` and point the
`*_HOST`/`*_PORT` at the Redis Service instead.

## Kubernetes liveness / readiness probes (Req 9.7)

The image ships a single upgrade-tolerant healthcheck script at
`/opt/scripts/healthcheck.sh`. The same script backs the Docker-style
`HEALTHCHECK` and is invokable directly by Kubernetes probes as an `exec`
command. The script owns the per-check 30-second timeout and the
startup-grace / upgrade-tolerance logic, so probe restarts are not triggered by
expected controller or adapter upgrade restarts.

```yaml
containers:
  - name: iobroker
    image: ghcr.io/fernetmenta/iobroker
    livenessProbe:
      exec:
        command: ['/opt/scripts/healthcheck.sh']
      periodSeconds: 30
      timeoutSeconds: 30
      failureThreshold: 3
    readinessProbe:
      exec:
        command: ['/opt/scripts/healthcheck.sh']
      periodSeconds: 30
      timeoutSeconds: 30
```

Notes:

- The `exec` form matches the Docker-style `HEALTHCHECK` in the image, which
  runs `CMD ["/opt/scripts/healthcheck.sh"]`.
- Tune the tolerance windows with `IOB_STARTUP_GRACE_PERIOD` (default `300`
  seconds) and `IOB_UPGRADE_TOLERANCE_WINDOW` (default `600` seconds). While the
  runtime is inside either window, the healthcheck does not report unhealthy, so
  you generally do not need a large `initialDelaySeconds` on the probes.
- First-boot and post-upgrade reconciliation (adapter installs, native module
  rebuilds) can run far longer than any fixed window on a slow connection or slow
  storage. This is handled separately by a **liveness heartbeat**, not a time
  window: while reconciliation keeps making progress the healthcheck tolerates the
  failing status check for any duration, and only reports unhealthy if the
  heartbeat goes stale for longer than `IOB_RECONCILE_STALL_TOLERANCE` (default
  `120` seconds). You therefore do not need to size a probe delay to your worst
  case reconcile time. See
  [environment-variables.md](./environment-variables.md) for all three variables.

## See also

- [Environment variable reference](./environment-variables.md) — all `IOB_`
  variables including the objects/states database backends and healthcheck tuning.
- [Rootless capabilities and limitations](./rootless-capabilities.md) — port
  binding, `NET_ADMIN`, and which functions need runtime-granted capabilities.

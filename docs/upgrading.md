# Upgrading ioBroker (js-controller and the runtime)

**Short version:** to upgrade js-controller and the ioBroker runtime, pull a
newer image and recreate the container against your existing volumes. Your
configuration and state are kept; the new container runs the new code.

```bash
docker compose pull && docker compose up -d
```

There is intentionally **no "upgrade js-controller" button in the admin UI** —
see [why](#why-there-is-no-in-admin-js-controller-upgrade-button) below. Adapter
upgrades from the admin UI work as usual; this only concerns js-controller
itself.

## Why the image is the unit of upgrade

The runtime code — js-controller and its dependencies — is baked into the
image. Your data (configuration, state, logs) lives in the volumes. Upgrading is
therefore: stop the old container, pull the new image, start a new container
using the same volumes.

This keeps the container **immutable and reproducible**: the running code is
exactly what shipped in the image, nothing rewrites the runtime in place, and
rolling back is just starting the previous image tag again. It also fits the
rootless design — no in-container package installs into a persisted volume, no
privileged maintenance mode.

## How to upgrade

Pick the variant that matches how you run the container. In all cases you keep
the same volumes, so your data carries over.

> **Docker and Podman.** The Docker commands below apply to **Podman** as well —
> Podman mirrors the Docker CLI, so `podman pull` / `podman run` / `podman rm`
> and `podman compose` (or `podman-compose`) work the same way. Substitute
> `podman` for `docker` in any command.

### Docker Compose

```bash
docker compose pull      # fetch the newer image
docker compose up -d     # recreate the container against the same volumes
```

If you pin a specific tag in your compose file (recommended over `latest` for
predictability), bump it first, then run the two commands above.

### Docker (plain `docker run`)

```bash
docker pull ghcr.io/fernetmenta/iobroker:<new-tag>
docker rm -f iobroker
docker run -d --name iobroker \
  -p 8081:8081 -p 8082:8082 \
  -v iobroker-data:/opt/iobroker/iobroker-data \
  -v iobroker-log:/opt/iobroker/log \
  ghcr.io/fernetmenta/iobroker:<new-tag>
```

Use the **same** `-v` volume flags you started with, so the new container
attaches to your existing data.

### Kubernetes

```bash
kubectl set image deployment/iobroker iobroker=ghcr.io/fernetmenta/iobroker:<new-tag>
```

The rollout starts a new pod against the existing PersistentVolumeClaims.

### Confirm the new version

```bash
docker exec iobroker iobroker version
# Podman:     podman exec iobroker iobroker version
# Kubernetes: kubectl exec deploy/iobroker -- iobroker version
```

## If you mounted the optional `node_modules` volume

Most setups persist only `iobroker-data` and `log`. If you also mounted the
optional `node_modules` volume (`/opt/iobroker/node_modules`), there is one
extra step at upgrade time.

That volume holds a copy of js-controller and the adapter code. Because it is
mounted over the image's own copy, the container keeps using the **old**
js-controller from the volume even after you pull a new image — so the upgrade
appears to do nothing to the controller version.

To pick up the new js-controller, **empty that volume's directory before
starting the new image**. With the volume empty, the container fills it from the
new image on startup (this needs internet so adapters can be reinstalled), and
your `iobroker-data` stays untouched:

```bash
docker compose down
# delete the contents of the host folder mapped to node_modules, e.g.:
rm -rf node_modules && mkdir node_modules
docker compose up -d
```

Notes:

- Your **configuration and state are safe** — this only clears the adapter/
  runtime code, which is reinstalled automatically. Do **not** delete the
  `iobroker-data` folder.
- If you do **not** mount a `node_modules` volume (the default), skip this
  entirely: the new image already contains the new js-controller.
- The same step applies when the new image moves to a newer **Node.js major**
  version. See
  [Node.js major upgrades and the Modules_Volume](./volumes-and-multihost.md#nodejs-major-upgrades-and-the-modules_volume)
  in the persistence guide for the full explanation.

## Back up before major upgrades

js-controller runs data migrations the first time it starts against an older
data directory, and major version jumps occasionally need attention. Before a
major upgrade:

- Take a backup. `iobroker backup` writes the archive into the data directory,
  so it is included in any snapshot you take of the `iobroker-data` volume.
- Keep the previous image tag. If something goes wrong, start the old tag again
  against the same volumes to roll back.

## Reclaim disk space: prune orphaned anonymous volumes

This applies to the **default** setup where you did **not** explicitly mount a
`node_modules` volume (no named volume and no host folder for it).

`/opt/iobroker/node_modules` is a declared volume in the image. If you don't
mount anything there, Docker/Podman automatically create an **anonymous volume**
for it each time a container is created. `node_modules` is large (js-controller
plus adapter code), so every upgrade that removes the old container and creates
a new one (`docker rm` + `docker run`, or a Compose recreate) can leave the old
container's anonymous volume behind. Over several upgrades these orphaned
volumes add up to a lot of disk space.

After confirming the upgrade is healthy, remove dangling volumes:

```bash
docker volume prune         # removes volumes not used by any container
# Podman: podman volume prune
```

Notes:

- `docker volume prune` only removes volumes **not attached to any container**,
  so your running ioBroker's volumes are not touched. Still, review the list it
  offers before confirming.
- `docker rm -v <old-container>` removes a specific stopped container together
  with its **anonymous** volumes — a safe, targeted way to clean up as you go,
  because it does not touch named volumes or host folders.
- `docker compose down -v` is a convenient one-shot cleanup, **but what `-v`
  does depends on how your data volumes are declared:**
  - If `iobroker-data` and `log` are **host-backed** volumes — either plain
    bind mounts, or `local` volumes with `driver_opts` `o: bind` /
    `device: <host path>` — then `-v` removes the Docker volume objects but the
    data stays in the host folders. The next `docker compose up` recreates the
    volumes pointing at the same folders with your data intact, while the
    dangling anonymous `node_modules` volume is cleaned up. In this setup
    `down -v` is exactly what you want.
  - If `iobroker-data`/`log` are **plain named volumes** (no `device:`, data
    lives inside the Docker volume), then `-v` **deletes that data**. The next
    `up` starts as a fresh install (data is not restored on recreation). Do not
    use `down -v` here unless you intend to wipe everything and have a backup.
- This does **not** apply if you mounted a **named** volume for `node_modules`
  (it is reused across upgrades, not orphaned) or a **host folder** (not a
  Docker volume at all). Your `iobroker-data` and `log` volumes are likewise
  unaffected as long as their container is running or they are named volumes you
  keep.

## Why there is no in-admin js-controller upgrade button

On a normal host install, admin can upgrade js-controller from the UI. On the
**official** ioBroker container image, admin enables that button only when it
detects the official image (via a version marker file) and drives the upgrade
through an image-specific "maintenance mode": a long-lived process keeps the
container alive while the controller is stopped, reinstalled, and restarted.

This image is a rootless, immutable design and deliberately does **not**
advertise itself as that official image, and does **not** implement that
maintenance mode. So admin shows the manual CLI instructions instead of an in-UI
upgrade button for js-controller — and upgrading via a new image (as described
above) is the supported path.

Do not try to force the button to appear (for example by faking the
official-image marker file). Admin would then attempt the maintenance-mode
upgrade this image does not support; it fails partway through and can stop the
container. Upgrade by pulling a new image instead.

## See also

- [Volumes, persistence, and multihost](./volumes-and-multihost.md) — the volume
  layout upgrades rely on, and the details of Node.js major upgrades.
- [Building the image](./building.md) — building locally, including pinning a
  specific js-controller version for testing.

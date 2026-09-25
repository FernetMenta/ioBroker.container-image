# Restoring an ioBroker backup

**Short version:** drop a single ioBroker backup file into a `restore/` folder
inside your `iobroker-data` volume, then **restart** the container. The restore
runs on every container start, so a plain restart is enough — you do not need to
recreate it. On the next start the container restores that backup before
ioBroker starts, writes a `restore.log`, deletes the `restore/` folder, and
continues booting. If the restore fails, the container refuses to start so you
notice.

This works on a **brand-new container with no prior data**, so you can migrate
an existing ioBroker installation onto a fresh container (or a new host) just by
restoring its backup.

## Why restore happens at startup

The `iobroker restore <backup>` CLI has to run while **js-controller is
stopped** — it rewrites the objects and states databases and `iobroker.json`
from the archive. In this image js-controller is the container's main process,
so "stop ioBroker, restore, start ioBroker" is not possible: stopping the
controller terminates the container.

The container solves this by restoring **during startup**, before it launches
js-controller. You stage the backup and restart the container, and the restore
runs at exactly the point where the controller is guaranteed to be stopped. The
startup pipeline runs on every start, so a restart (`docker restart`, or `stop`
then `start`) is sufficient — a full recreate is not required, though it works
too since it also starts the container.

## How to restore

1. Get a backup archive. `iobroker backup` produces a
   `*_backupIoBroker.tar.gz` file in the data directory. Any ioBroker backup
   archive works, including one taken on a completely different host.

2. Put **exactly one** backup file into a `restore/` folder in the
   `iobroker-data` volume, so the container sees it at
   `/opt/iobroker/iobroker-data/restore/<backup>.tar.gz`.

   **Ownership matters.** The container runs rootless as **UID 1000**, and it
   reaches its data through the file _owner_ (uid 1000 is not in the root
   group). The backup file and the `restore/` folder must therefore be owned by
   `1000:0` (or at least be readable by uid 1000, and the folder deletable by
   it). Stage the file so it ends up owned by 1000 — the methods below all do
   that. This is also why a plain `docker cp` is **not** enough on its own:
   `docker cp` creates files inside the container as `root`, which uid 1000
   cannot read or delete (see the `docker cp` note below to fix that).

   With a host-backed `iobroker-data` folder, copy it in and make sure it is
   owned by 1000:0:

   ```bash
   mkdir -p ./iobroker-data/restore
   cp 2025_01_31-02_00_00_backupIoBroker.tar.gz ./iobroker-data/restore/
   sudo chown -R 1000:0 ./iobroker-data/restore   # if your host user is not uid 1000
   ```

   > **Rootless Podman with a host bind mount:** the ownership rule is
   > different. There the container runs as uid 0, which maps to your own host
   > user, so the container reaches the file through *your* host ownership — no
   > `chown` to 1000:0 is needed (and it would be wrong). Just stage the file as
   > your host user and start the container with `--user 0:0`:
   >
   > ```bash
   > mkdir -p ./iobroker-data/restore
   > cp 2025_01_31-02_00_00_backupIoBroker.tar.gz ./iobroker-data/restore/
   > ```

   For a named volume, run a throwaway helper **as uid 1000:0** so the copy is
   owned correctly:

   ```bash
   docker run --rm --user 1000:0 \
     -v iobroker-data:/data \
     -v "$PWD":/src:ro \
     busybox sh -c 'mkdir -p /data/restore && cp /src/2025_01_31-02_00_00_backupIoBroker.tar.gz /data/restore/'
   ```

   If you prefer `docker cp` (which always copies in as `root`), fix the
   ownership afterwards with a one-off root exec:

   ```bash
   docker exec -u 0 iobroker mkdir -p /opt/iobroker/iobroker-data/restore
   docker cp 2025_01_31-02_00_00_backupIoBroker.tar.gz \
     iobroker:/opt/iobroker/iobroker-data/restore/
   docker exec -u 0 iobroker chown -R 1000:0 /opt/iobroker/iobroker-data/restore
   ```

3. **Restart** the container so the startup pipeline runs and picks up the
   backup:

   ```bash
   docker restart iobroker      # or: docker stop iobroker && docker start iobroker
   # Compose:    docker compose restart
   ```

   A full recreate (`docker compose up -d` after a pull, or `docker rm -f` +
   `docker run` with the same volumes) also works, but is only needed when you
   are changing the image or run configuration — not for a restore.

4. Watch the logs. The startup banner shows a **"Restoring backup"** step, and
   the full CLI transcript is written to `log/restore.log` in the Log_Volume:

   ```bash
   docker logs -f iobroker
   docker exec iobroker cat /opt/iobroker/log/restore.log
   ```

On success the container removes the `restore/` folder and continues its normal
startup (database configuration, adapter reconciliation, then js-controller). On
a fresh container the adapters recorded in the backup are installed by the
normal reconciliation step after the restore.

## Restoring onto a fresh system

To bring an existing installation up on a new container or host:

1. On the old system, run `iobroker backup` and grab the archive from the data
   directory.
2. Start with **empty** `iobroker-data` and `log` volumes (a fresh install).
3. Stage the archive under `iobroker-data/restore/` as above and create the
   container.

The container initializes a minimal configuration, restores your backup over
it, and then reinstalls the adapters your configuration expects (this needs
internet access for the adapter downloads).

## Rules and behavior

- **Exactly one backup file.** If the `restore/` folder holds more than one
  backup archive (`*.tar.gz` / `*.tgz`), the container will not guess — it logs
  the candidates, leaves the folder untouched, and refuses to start. Remove the
  extras and recreate.
- **One-shot.** On a successful restore the `restore/` folder is deleted, so a
  later restart or recreate does **not** restore again over your live data. The
  restore only re-runs if you stage a new backup folder.
- **Fail-safe.** If the restore command fails, the container **exits instead of
  starting** (a half-restored database is worse than a clear failure) and leaves
  the `restore/` folder in place so you can inspect it. Check `log/restore.log`.
- **Empty folder.** An empty `restore/` folder (or one with no backup archive)
  is a no-op: it is removed and startup continues normally.
- **Logging.** The full CLI output goes to `log/restore.log`. When the
  Log_Volume is not writable the restore still runs and logs to the container
  log (`docker logs`).
- **Ownership.** The backup file and the `restore/` folder must be owned by
  `1000:0` (or otherwise readable by uid 1000 and the folder deletable by it),
  because the container runs as uid 1000. A file left owned by `root` (the
  default result of `docker cp`) makes the restore fail to read the archive or
  to remove the folder afterward — see the staging step above.

## See also

- [Upgrading ioBroker](./upgrading.md) — backups before upgrades, rollback, and
  why the image is the unit of upgrade.
- [Volumes, persistence, and multihost](./volumes-and-multihost.md) — the volume
  layout the restore reads and writes.

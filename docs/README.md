# Documentation

> **Note:** This project is a revamp of
> [buanet/ioBroker.docker](https://github.com/buanet/ioBroker.docker). It builds
> on the ideas of that widely used ioBroker container image while re-architecting
> it around a rootless, multi-architecture, reconciliation-based design.

Documentation deliverables for the rootless ioBroker container image live here.
Content is authored in task 17:

- Environment variable reference (retained set + removed `SETUID`/`SETGID`) — task 17.1
- Rootless capability and limitations documentation — task 17.2 — see [rootless-capabilities.md](./rootless-capabilities.md)
- Volume/persistence layout and multihost/database-backend usage (with k8s probe examples) — task 17.3 — see [volumes-and-multihost.md](./volumes-and-multihost.md)

Available now:

- [Upgrading ioBroker](upgrading.md) - how to upgrade js-controller and the runtime by pulling a new image, backups, rollback, the optional `node_modules` volume step, and why there is no in-admin controller-upgrade button.
- [Building the image locally](building.md) - the local build path that mirrors CI (task 16.2).
- [Volumes, persistence, and multihost](volumes-and-multihost.md) - persistence layout (Data/Log/Modules volumes), reconciliation behavior, Docker/Podman/k8s mount examples, multihost/database-backend usage, and Kubernetes liveness/readiness probe examples (task 17.3).

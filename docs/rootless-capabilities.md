# Rootless Capabilities and Limitations

This document explains how Linux capabilities behave for the rootless ioBroker
container image, why binding to privileged ports can fail without extra runtime
configuration, and which ioBroker functions work out of the box versus which
ones require the runtime to explicitly grant a capability.

It covers the capability-related acceptance criteria of Requirement 7
(Req 7.2, 7.3, 7.4, 7.5).

## Background: file capabilities vs. effective privileges

The image ships the Node.js binary with **no file capabilities**. Earlier
revisions applied `setcap 'cap_net_bind_service,cap_net_raw+ep'` to the `node`
binary at build time; that has been **removed** because it is incompatible with
running the image fully rootless (Req 7.1).

- `cap_net_bind_service` — allows binding to privileged TCP/UDP ports below 1024.
- `cap_net_raw` — allows opening raw sockets (for example, ICMP `ping`).

### Why the file capabilities were removed

A file capability with the **effective** bit set (`+ep`) tells the kernel to
raise that capability into the process's effective set the moment the binary is
`exec`'d. If the capability is **not** in the process's permitted set at that
moment — which is exactly the fully-rootless case (rootless Podman with no
allowed capabilities, a Kubernetes pod that has not added it, and so on) — the
kernel **refuses the exec** with `Operation not permitted`. In practice the
container fails to start at all:

```
exec /usr/local/bin/node: operation not permitted
```

No `setcap` flag combination avoids this while still being useful:

- `+ep` / `+eip` — the effective bit breaks rootless `exec` as described above.
- `+ip` (permitted + inheritable, no effective bit) — `exec` succeeds, but the
  capability is **not** effective automatically, and `node` does not raise
  ambient capabilities on its own, so nothing gains the privilege.

So a baked file capability either **breaks rootless startup** or **provides
nothing**. The image therefore ships `node` with no file capabilities, and
privileged operations are handled entirely at the runtime layer (see below).

### Practical consequences

- When the container runs **fully rootless with no added capabilities** (the
  default and recommended mode), `node` starts normally and all standard
  ioBroker functionality on high ports works. (Req 7.4)
- Operations that need a capability — most notably **binding to privileged
  ports below 1024** and **raw sockets / ICMP** — require the runtime to grant
  the capability **and** make it effective for `node`. Because `node` no longer
  carries a file capability, a bare `--cap-add` is **not sufficient** on its
  own; see [Granting capabilities](#granting-capabilities-docker--podman--kubernetes)
  for the full recipe. (Req 7.2, 7.5)

## Privileged ports below 1024 (Req 7.2)

In a fully rootless, no-added-capability scenario, `cap_net_bind_service` on the
`node` binary is not effective, so an ioBroker adapter that tries to listen on a
port below 1024 (for example, binding a web UI directly on port 80 or 443) may
fail to bind.

Recommended options, in order of preference:

1. **Use unprivileged ports (default).** ioBroker's own services default to
   high ports (admin `8081`, web `8082`), so no privileged port is required for
   normal operation. Prefer high ports and let a reverse proxy or the runtime
   handle public port `80`/`443`.
2. **Publish/redirect at the runtime layer.** Map a privileged host port to an
   unprivileged container port (for example, Docker `-p 80:8082`, or a
   Kubernetes `Service` exposing `80` → `8082`). The container itself never
   binds below 1024.
3. **Grant the capability to the runtime (and make it effective).** If an
   adapter genuinely must bind `<1024` inside the container, granting
   `NET_BIND_SERVICE` via `--cap-add` is **necessary but not sufficient** now
   that `node` carries no file capability: the capability must also be
   **ambient** (or the process must run with a privileged UID) for `node` to
   pick it up. See [Granting capabilities](#granting-capabilities-docker--podman--kubernetes)
   for the exact flags. The simpler and preferred alternative on rootless hosts
   is to lower the unprivileged-port threshold with the
   `net.ipv4.ip_unprivileged_port_start` sysctl, or to map the port at the
   runtime layer.

## `cap_net_admin` / `NET_ADMIN` (Req 7.3)

`NET_ADMIN` is **not** applied as a file capability on the `node` binary and is
**not** available in a default rootless run. Some adapters that manage network
interfaces, VPNs, routing, or perform low-level network administration require
`cap_net_admin`.

If an adapter requires `cap_net_admin`, the container **must be started with an
explicitly granted `NET_ADMIN` capability** by the runtime, for example
`docker run --cap-add=NET_ADMIN ...` or a Kubernetes
`securityContext.capabilities.add: ["NET_ADMIN"]`. Without an explicit runtime
grant, `NET_ADMIN`-dependent functionality will not work. (Req 7.3)

## Functions that work WITHOUT added runtime capabilities (Req 7.4)

In a fully rootless context with **no** added runtime capabilities, the
following ioBroker functions operate normally:

- The **js-controller** and normal adapter processes (all standard,
  non-privileged adapter logic).
- The **admin UI** on its default unprivileged port (`IOB_ADMIN_PORT`, default
  `8081`).
- The **web adapter** and other web-based adapters on their default
  unprivileged ports (`IOB_WEB_PORT`, default `8082`), and any adapter that
  listens on a port **≥ 1024**.
- Outbound network connections (HTTP/HTTPS/MQTT/WebSocket clients, cloud
  connectors, REST calls to devices and services).
- Local **file/state persistence** to the `Data_Volume` and `Log_Volume`, and
  adapter installation/reconciliation against the adapter registry.
- **Multihost / database-backend** connectivity to a networked objects/states
  database (jsonl or Redis) on its configured port (typically ≥ 1024).
- Serial / USB device adapters, **provided** the device is passed into the
  container and its permissions allow the runtime UID/GID (device access is a
  device-permission concern, not a capability concern).

None of the above requires `cap_net_bind_service`, `cap_net_raw`, or
`cap_net_admin` to be effective.

## Functions that REQUIRE explicitly granted runtime capabilities (Req 7.5)

The following functions only work when the container runtime **explicitly
grants** the corresponding capability. Because `node` no longer carries a file
capability, granting a capability with `--cap-add` alone is **not sufficient**
for the port-binding / raw-socket cases: the capability must also be made
**ambient** (or the alternative below used) so the unprivileged `node` process
actually holds it.

| Function / need | Required capability | How to enable |
|---|---|---|
| Binding a listener to a **privileged port < 1024** (e.g. an adapter serving directly on `80`/`443`) | `NET_BIND_SERVICE` (ambient) | Preferred: avoid the privileged port (reverse proxy / port mapping) or lower the threshold with the `net.ipv4.ip_unprivileged_port_start` sysctl. Otherwise: add `NET_BIND_SERVICE` **and** make it ambient (see examples). |
| **Raw sockets / ICMP ping** (e.g. the `ping` adapter or any adapter using raw sockets) | `NET_RAW` (ambient) | Add `NET_RAW` **and** make it ambient. On many hosts ICMP also works via the `net.ipv4.ping_group_range` sysctl without any capability. |
| **Low-level network administration** (managing interfaces, routing, VPN/tunnel adapters, and similar) | `NET_ADMIN` | Add `NET_ADMIN`. Adapters using it typically invoke helper tools that raise the capability themselves, so ambient is usually not required. |

## Granting capabilities (Docker / Podman / Kubernetes)

The examples below show how to grant the capabilities from the table above. Grant
only the capability an adapter actually needs — do not add capabilities
speculatively.

> **Important since file capabilities were removed:** for `node` to actually
> bind a privileged port or open a raw socket, the capability must be present in
> its **ambient** set, not merely added to the container's bounding set. A bare
> `--cap-add=NET_BIND_SERVICE` no longer makes `node` able to bind `<1024` on its
> own. Prefer the sysctl / port-mapping alternatives where possible.

### Docker / Podman

Podman is CLI-compatible with Docker, so the commands are identical — swap
`docker` for `podman` (the differences between the two are noted after the
examples). Prefer the sysctl / port-mapping options; they need no capability at
all and work the same rootful or rootless.

```bash
# Preferred: no capability needed — lower the unprivileged-port threshold so
# ports below 1024 are bindable by the unprivileged process.
docker run --sysctl net.ipv4.ip_unprivileged_port_start=0 \
  -p 80:80 ghcr.io/fernetmenta/iobroker

# Preferred: no capability needed — map a privileged HOST port onto an
# unprivileged CONTAINER port (ioBroker keeps listening on high ports).
docker run -p 80:8082 ghcr.io/fernetmenta/iobroker

# ICMP ping without any capability — allow the container's GID range to use
# unprivileged ICMP sockets.
docker run --sysctl 'net.ipv4.ping_group_range=0 2147483647' \
  ghcr.io/fernetmenta/iobroker

# Low-level network administration (e.g. a VPN/tunnel adapter):
docker run --cap-add=NET_ADMIN ghcr.io/fernetmenta/iobroker
```

**Docker vs. Podman differences**

- **Binding a privileged port via the capability (not the sysctl/port-map).**
  Since `node` carries no file capability, a bare `--cap-add=NET_BIND_SERVICE`
  is not enough on either runtime — the capability must reach `node`'s
  **ambient** set. Neither `docker run` nor rootless `podman run` does this with
  a plain `--cap-add`, so use the sysctl or port-mapping option above instead.
- **Rootless Podman allowed set.** In rootless Podman, a requested capability
  must also lie within the user's allowed set (configured via `/etc/subuid`,
  `/etc/subgid`, and the user namespace) or the `--cap-add` is silently
  ineffective. Rootful Docker has no such restriction.
- **`NET_ADMIN`.** Behaves the same on both: adapters that need it typically run
  helper tools that raise the capability themselves, so a plain `--cap-add`
  works without ambient handling.

### Kubernetes

Add the capability through the container `securityContext`. This keeps the
container otherwise non-root; only the named capability is added.

```yaml
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
      containers:
        - name: iobroker
          image: ghcr.io/fernetmenta/iobroker
          securityContext:
            runAsNonRoot: true
            capabilities:
              # Add only what an adapter actually needs:
              add:
                - NET_BIND_SERVICE   # bind privileged ports < 1024
                - NET_RAW            # raw sockets / ICMP ping
                - NET_ADMIN          # low-level network administration
              # Best practice: drop everything else.
              drop:
                - ALL
```

If an adapter only needs one capability, add just that one (for example, only
`NET_ADMIN` for a VPN adapter) and keep `drop: ["ALL"]` for the rest.

> For an adapter that must bind a privileged port `<1024` via
> `NET_BIND_SERVICE`, adding it under `capabilities.add` is not enough on its
> own — the container must also hold it as an **ambient** capability. The
> simpler, portable alternative is to keep ioBroker on its high ports and expose
> `80`/`443` through a `Service` / `Ingress`, or set the
> `net.ipv4.ip_unprivileged_port_start` sysctl on the pod.

## Summary

- The image ships `node` with **no file capabilities**; the previous
  `setcap cap_net_bind_service,cap_net_raw+ep` was removed because its effective
  bit makes the kernel refuse to `exec` `node` in a fully-rootless container
  (rootless Podman, capability-less Kubernetes pod), preventing startup.
  (Req 7.1)
- In a fully rootless, **no-added-capability** run `node` starts normally and
  all standard functionality on high ports works; binding to ports **< 1024**
  requires runtime configuration. (Req 7.2)
- Because `node` carries no file capability, a bare `--cap-add=NET_BIND_SERVICE`
  / `--cap-add=NET_RAW` is **not sufficient** — the capability must be made
  **ambient**, or (preferred) the operator uses the
  `net.ipv4.ip_unprivileged_port_start` sysctl, a port mapping, or a reverse
  proxy. (Req 7.5)
- `cap_net_admin` was never a file capability; adapters that need it still
  require an explicit runtime grant of **`NET_ADMIN`**. (Req 7.3)
- Standard adapters, the admin/web UIs on high ports, outbound connections, and
  Redis/multihost work **without** added capabilities. (Req 7.4)

# Networking: multicast, broadcast, and LAN discovery

Many ioBroker adapters find devices on the local network with protocols that
rely on **multicast** or **broadcast** instead of a known IP address. This
document explains why that breaks on a default container network, and how to
run the container so discovery works: on the **host network** or on a
**macvlan** network.

## Why the default container network is not enough

A default Docker or Podman bridge network sits behind NAT. Published ports
(`-p 8081:8081`) forward unicast TCP/UDP traffic into the container, but
multicast and broadcast packets from your LAN are **not** forwarded across the
bridge, and the container's own multicast/broadcast packets do not reach the
LAN. The container is on a different layer-2 segment than your devices.

Typical protocols and adapters affected:

| Protocol / mechanism                            | Transport                               | Typical use                                                     |
| ----------------------------------------------- | --------------------------------------- | --------------------------------------------------------------- |
| mDNS / Bonjour / Zeroconf (DNS-SD)              | UDP `5353`, multicast `224.0.0.251`     | Device discovery for Apple, Chromecast, many IoT devices, EEBus |
| SSDP / UPnP                                     | UDP `1900`, multicast `239.255.255.250` | Routers, media players, smart TVs, Hue bridge discovery         |
| Vendor UDP discovery (broadcast to `x.x.x.255`) | UDP, adapter-specific port              | Inverters, wallboxes, heating controllers, smart-home gateways  |

Symptoms are usually "no devices found" in an adapter's discovery or scan
dialog while entering the device IP by hand still works. If an adapter's
documentation says it uses mDNS, SSDP, or UDP discovery/broadcast, use one of
the two setups below.

> Plain unicast access to a device with a known IP (HTTP, MQTT, Modbus TCP,
> WebSocket, and so on) works fine on the default bridge network. You only need
> this document when an adapter must **discover** devices or **receive**
> multicast/broadcast traffic.

## Choosing a network mode

| Mode             | Container gets its own LAN IP | Works rootless                       | Host can reach container | Notes                                                                                 |
| ---------------- | ----------------------------- | ------------------------------------ | ------------------------ | ------------------------------------------------------------------------------------- |
| Bridge (default) | No                            | Yes                                  | Via published ports      | No multicast/broadcast from the LAN.                                                  |
| Host network     | No (shares the host IP)       | Docker: yes (see below). Podman: yes | Yes                      | Simplest. Container shares the host's ports and interfaces.                           |
| macvlan          | Yes                           | **No** (needs root)                  | Not by default           | Container is a first-class device on the LAN. Best isolation while keeping multicast. |

Rule of thumb: use **host network** when you want the simplest setup on a
dedicated machine. Use **macvlan** when you want the container to have its own
IP address, avoid port conflicts with the host, or run several containers that
all need the same well-known ports (for example more than one multihost node on
a single machine).

## Option 1: Host network

With host networking the container uses the host's network stack directly, so
it sees the same interfaces, multicast groups, and broadcast domain as the host.

### Docker

```bash
docker run -d \
  --name iobroker \
  --network host \
  --user $(id -u):$(id -g) \
  -v iobroker-data:/opt/iobroker/iobroker-data \
  -v iobroker-log:/opt/iobroker/log \
  ghcr.io/fernetmenta/iobroker
```

Or with Compose:

```yaml
services:
  iobroker:
    image: ghcr.io/fernetmenta/iobroker
    container_name: iobroker
    network_mode: host
    user: '1000:1000'
    volumes:
      - iobroker-data:/opt/iobroker/iobroker-data
      - iobroker-log:/opt/iobroker/log

volumes:
  iobroker-data:
  iobroker-log:
```

### Podman

```bash
podman run -d \
  --name iobroker \
  --network host \
  -v iobroker-data:/opt/iobroker/iobroker-data \
  -v iobroker-log:/opt/iobroker/log \
  ghcr.io/fernetmenta/iobroker
```

For `podman kube play`, set `hostNetwork: true` in the Pod spec.

### Kubernetes

Set `hostNetwork: true` on the pod. Also set `dnsPolicy: ClusterFirstWithHostNet`
so in-cluster DNS keeps working:

```yaml
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  containers:
    - name: iobroker
      image: ghcr.io/fernetmenta/iobroker
```

### Things to know about host networking

- **`ports:` / `-p` is ignored.** The container listens directly on the host, so
  the admin UI is on `http://<host>:8081` as long as `IOB_ADMIN_PORT` is
  unchanged. Use `IOB_ADMIN_PORT` and `IOB_WEB_PORT` to move them if the host
  already uses those ports. See
  [environment-variables.md](./environment-variables.md).
- **Port conflicts with the host.** Everything an adapter opens is a host port.
  If the host already runs mDNS (Avahi, `systemd-resolved`) on UDP `5353`,
  sharing the port needs `SO_REUSEADDR`/`SO_REUSEPORT`, which most mDNS libraries
  set. If an adapter still fails to bind, check what else owns the port on the
  host.
- **Less isolation.** The container can reach every service bound to the host's
  loopback interface. Prefer macvlan if that matters to you.
- **Multihost.** Master and slave on the same machine would fight over the jsonl
  database ports `9000`/`9001`. Host networking suits one ioBroker per host.
- **Docker Desktop (macOS/Windows).** Host networking refers to the Docker VM,
  not your laptop, so it does not help with LAN discovery there. Run on a Linux
  host.

## Option 2: macvlan

A macvlan network attaches the container to your physical network interface with
its **own MAC and IP address**. Other devices on the LAN see it as a separate
machine, so broadcast and multicast traffic flows both ways, just as it would for
a real device.

> **macvlan needs root and a real interface.** The container runtime must be
> allowed to create a macvlan device on a host interface. That works with
> **rootful** Docker and **rootful** Podman (`sudo podman`). It does **not** work
> with rootless Podman or rootless Docker. The container itself still runs as
> the non-root user (`user: "1000:1000"`); only the network setup needs the
> privileged daemon.

### Example Compose file

[`examples/docker-compose-master.yml`](./examples/docker-compose-master.yml)
is a complete, working example. It attaches the container to **two** networks:
a normal bridge for container-to-container traffic and a macvlan network that
gives the container a static address on the LAN. The relevant parts:

```yaml
services:
  iobroker:
    image: ghcr.io/fernetmenta/iobroker:7.2.2
    user: '1000:1000'
    networks:
      bridge-net:
      macvlan-net:
        ipv4_address: 192.168.170.221

networks:
  bridge-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.30.0.0/24
          gateway: 172.30.0.1
  macvlan-net:
    driver: macvlan
    driver_opts:
      parent: eth0 # the host's real LAN interface
    ipam:
      config:
        - subnet: 192.168.170.0/24
          gateway: 192.168.170.1
          ip_range: 192.168.170.216/29 # addresses Docker may hand out
```

Adjust these values to your LAN:

| Setting              | What to put there                                                                                                |
| -------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `parent`             | The host's physical interface that is connected to the LAN (`ip -br link`). For VLANs use e.g. `eth0.20`.        |
| `subnet` / `gateway` | Your LAN's subnet and router address.                                                                            |
| `ip_range`           | A small block of addresses **outside your DHCP pool**, reserved for containers, so nothing else takes them.      |
| `ipv4_address`       | A static address inside `ip_range` (or at least unused on the LAN). Keeps the container reachable at a fixed IP. |

Start it from the folder containing the file:

```bash
docker compose up -d
```

Then open the admin UI at `http://192.168.170.221:8081`. With macvlan there is
no need for a `ports:` section: every port the container opens is reachable
directly on its own LAN IP.

### Same setup with plain `docker` commands

```bash
docker network create -d macvlan \
  --subnet=192.168.170.0/24 \
  --gateway=192.168.170.1 \
  --ip-range=192.168.170.216/29 \
  -o parent=eth0 \
  iobroker-macvlan

docker run -d \
  --name iobroker \
  --user 1000:1000 \
  --network iobroker-macvlan \
  --ip 192.168.170.221 \
  -v iobroker-data:/opt/iobroker/iobroker-data \
  -v iobroker-log:/opt/iobroker/log \
  ghcr.io/fernetmenta/iobroker
```

For Podman, the equivalent is `sudo podman network create -d macvlan ...` and
running the container with `sudo podman run --network ...`. The Podman kube
example [`examples/iobroker-podman-kube.yaml`](./examples/iobroker-podman-kube.yaml)
is written for rootful Podman for the same reason.

### Why the example also keeps a bridge network

A container on macvlan only is invisible to its own Docker host and to other
containers on that host's bridge networks. Keeping the second `bridge-net`
network lets sibling containers (for example a database or a multihost slave on
the same machine) talk to ioBroker over the bridge, while discovery traffic goes
out over macvlan. If you do not need container-to-container traffic, you can
remove `bridge-net` and use macvlan alone.

### Known macvlan limitations

- **The Docker host cannot reach the container's macvlan IP.** This is a Linux
  kernel behavior: traffic between a parent interface and its macvlan children
  is not looped back. Other machines on the LAN reach the container fine. To
  reach it from the host itself, either use the bridge network's address, or add
  a macvlan "shim" interface on the host:

  ```bash
  # one-off; make it persistent with your network manager
  sudo ip link add macvlan-shim link eth0 type macvlan mode bridge
  sudo ip addr add 192.168.170.215/32 dev macvlan-shim
  sudo ip link set macvlan-shim up
  sudo ip route add 192.168.170.216/29 dev macvlan-shim
  ```

  The shim address must be unused on the LAN and outside `ip_range`.

- **Wi-Fi interfaces generally do not work as `parent`.** Most access points
  accept only one MAC address per client. Use a wired interface.
- **Virtual machines and hypervisors.** The VM's virtual NIC must allow several
  MAC addresses (promiscuous mode on VMware vSwitch, "Allow MAC address spoofing"
  on Hyper-V, and similar). Otherwise the extra MAC is dropped.
- **Switch port security.** Switches that limit the number of MAC addresses per
  port may block the container's MAC.
- **No DHCP from Docker.** Docker assigns addresses itself from `ip_range`. Keep
  that range outside your router's DHCP pool to avoid duplicates.
- **IPv6.** Add an IPv6 `subnet` to `ipam` and set `enable_ipv6: true` on the
  network if your adapters need it. The example is IPv4 only.

## Multihost over host network or macvlan

The multihost master serves its objects/states databases on ports `9001` and
`9000`, and slaves connect to them (see
[volumes-and-multihost.md](./volumes-and-multihost.md#multihost-and-database-backends)).
The network mode decides how a slave reaches the master:

- **macvlan:** give the master a static `ipv4_address` and set the slave's
  `IOB_OBJECTSDB_HOST` and `IOB_STATESDB_HOST` to that address (or a DNS name
  that resolves to it). A slave on another machine can reach it directly.
- **Host network:** use the master host's own LAN IP or hostname.

Multicast discovery on a **slave** works the same way as on a standalone node:
run the slave on host network or macvlan on the machine where the devices
live.

## Rootless limits and capabilities

Neither option requires extra Linux capabilities for multicast or broadcast
traffic itself. Receiving multicast and sending broadcast on ordinary UDP
sockets works as an unprivileged user. Binding **ports below 1024** and
**raw sockets** (ICMP ping) are separate topics; see
[rootless-capabilities.md](./rootless-capabilities.md).

## Troubleshooting

- **Check that the traffic is reaching the container.** From a machine on the
  LAN, ping the container's macvlan IP. If it works from other machines but not
  from the Docker host, that is the host/macvlan limitation above.
- **Confirm which network the container is on.**
  `docker inspect iobroker --format '{{json .NetworkSettings.Networks}}'`.
- **Confirm multicast is delivered.** Install `tcpdump` on the host and watch the
  interface, for example `sudo tcpdump -ni eth0 udp port 5353 or udp port 1900`.
  If packets show on the host but not inside the container, the container is not
  on host network or macvlan.
- **Docker firewall and `iptables`.** Firewalls on the host or router can still
  drop multicast (IGMP snooping, "multicast filtering" or "client isolation" on
  access points). If discovery works from another LAN machine but not from the
  container, check these settings on the network side.
- **Adapter binds the wrong interface.** On a host with several interfaces
  (or a container on both bridge and macvlan), choose the LAN-facing address in
  the adapter's settings if it offers a "bind address" or "interface" option.

## See also

- [`examples/docker-compose-master.yml`](./examples/docker-compose-master.yml) —
  complete macvlan + bridge Compose example.
- [`examples/iobroker-podman-kube.yaml`](./examples/iobroker-podman-kube.yaml) —
  rootful Podman `kube play` example.
- [Volumes, persistence, and multihost](./volumes-and-multihost.md) — multihost
  database backends.
- [Rootless capabilities and limitations](./rootless-capabilities.md) —
  privileged ports, raw sockets, `NET_ADMIN`.
- [Environment variables](./environment-variables.md) — `IOB_ADMIN_PORT`,
  `IOB_WEB_PORT`, and multihost settings.

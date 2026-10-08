---
layout: home
title: ioBroker Container Image – Übersicht
---

# ioBroker Container Image

Ein **rootless**, **Multi-Architektur**-Container-Image für
[ioBroker](https://www.iobroker.net/), aufgebaut als schlankes Multi-Stage-Image
auf dem offiziellen Node.js-LTS-Image mit der aktuell von ioBroker empfohlenen
Version.

> **Hinweis:** Dieses Projekt ist eine Überarbeitung von
> [buanet/ioBroker.docker](https://github.com/buanet/ioBroker.docker). Es baut
> auf den Ideen dieses weit verbreiteten ioBroker-Container-Images auf und
> gestaltet es rund um ein rootless, Multi-Architektur- und
> reconciliation-basiertes Design neu.

Das veröffentlichte Image ist über die GitHub Container Registry verfügbar:

```
ghcr.io/fernetmenta/iobroker
```

(Der Paketname unterscheidet sich bewusst vom Quell-Repository
`ioBroker.container-image`.)

---

## Eigenschaften im Überblick

- **Standardmäßig rootless.** Läuft als Nicht-Root-Benutzer (uid/gid 1000) und
  unterstützt beliebige UIDs (OpenShift-Stil) über gruppenschreibbare
  Datenverzeichnisse mit GID 0. Das Node-Binary trägt keine Datei-Capabilities
  und läuft daher sauber unter rootless Docker, Podman und Kubernetes.
- **Schlanker Multi-Stage-Build.** Die Build-Toolchain und die `-dev`-Header zum
  Kompilieren der nativen Module von ioBroker existieren nur in der Build-Stufe
  und landen nie im ausgelieferten Runtime-Image.
- **Multi-Architektur.** Veröffentlicht als ein einziges Multi-Arch-Manifest für
  `linux/amd64` und `linux/arm64`.
- **Reconciliation-basierter Start.** Das Daten-Volume ist die maßgebliche
  Quelle dafür, welche Adapter installiert sind. Beim Start gleicht der Container
  den installierten Adapter-Code entsprechend ab, initialisiert ein frisches
  Daten-Volume beim ersten Lauf und richtet den Admin-Adapter ein, sodass ein
  neuer Container mit funktionierender Setup-Oberfläche hochfährt.
- **Upgrade-tolerante Healthcheck-Prüfung.** Ein Docker-/Podman-`HEALTHCHECK`
  (auch als Kubernetes-Liveness-/Readiness-Probe nutzbar) mit konfigurierbarer
  Start-Toleranz und Upgrade-Toleranzfenstern.
- **tini als PID 1.** Korrekte Signalweiterleitung und Zombie-Reaping.

---

## Schnellstart

Der erste Start auf einem leeren Daten-Volume dauert einen Moment, da der
Container ioBroker initialisiert und den Admin-Adapter installiert. Danach ist
die Admin-Oberfläche auf Port 8081 erreichbar.

### Docker (rootful)

```bash
docker run -d \
  --name iobroker \
  --user $(id -u):$(id -g) \
  -p 8081:8081 \
  -p 8082:8082 \
  -v iobroker-data:/opt/iobroker/iobroker-data \
  -v iobroker-log:/opt/iobroker/log \
  ghcr.io/fernetmenta/iobroker
```

### Podman (rootless)

```bash
podman run -d \
  --name iobroker \
  -p 8081:8081 \
  -p 8082:8082 \
  -v iobroker-data:/opt/iobroker/iobroker-data \
  -v iobroker-log:/opt/iobroker/log \
  ghcr.io/fernetmenta/iobroker
```

Anschließend <http://localhost:8081> für die Admin-Oberfläche öffnen.

> **Nicht als Host-Root laufen lassen – aber „Host-Root" hängt von der Laufzeit
> ab.** Die genauen Unterschiede zwischen rootful Docker/Podman und rootless
> Podman (inklusive wann `--user` nötig ist und wann nicht) sind ausführlich in
> der englischen README beschrieben.

---

## Ausführliche Dokumentation (englisch)

Diese Seite ist eine deutschsprachige Übersicht. Die detaillierte technische
Dokumentation wird auf Englisch gepflegt und liegt im Repository. Für Details
siehe:

- [README (vollständige Projektübersicht)](https://github.com/FernetMenta/ioBroker.container-image/blob/main/README.md)
- [Dokumentationsindex](https://github.com/FernetMenta/ioBroker.container-image/blob/main/docs/README.md)
- [Umgebungsvariablen-Referenz](https://github.com/FernetMenta/ioBroker.container-image/blob/main/docs/environment-variables.md)
- [ioBroker aktualisieren (Upgrading)](https://github.com/FernetMenta/ioBroker.container-image/blob/main/docs/upgrading.md)
- [Backup wiederherstellen](https://github.com/FernetMenta/ioBroker.container-image/blob/main/docs/restore-backup.md)
- [Image lokal bauen](https://github.com/FernetMenta/ioBroker.container-image/blob/main/docs/building.md)
- [Rootless-Capabilities und Einschränkungen](https://github.com/FernetMenta/ioBroker.container-image/blob/main/docs/rootless-capabilities.md)
- [Volumes, Persistenz und Multihost](https://github.com/FernetMenta/ioBroker.container-image/blob/main/docs/volumes-and-multihost.md)
- [Beispiel-Compose-Dateien](https://github.com/FernetMenta/ioBroker.container-image/tree/main/docs/examples)

---

<sub>Projekt-Repository:
[FernetMenta/ioBroker.container-image](https://github.com/FernetMenta/ioBroker.container-image)
· Lizenz siehe
[LICENSE](https://github.com/FernetMenta/ioBroker.container-image/blob/main/LICENSE).</sub>

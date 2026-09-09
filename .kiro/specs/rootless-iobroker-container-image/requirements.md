# Requirements Document

## Introduction

This feature modernizes the ioBroker Docker image (reference implementation: buanet/ioBroker.docker) into a rootless, multi-architecture container image. The revamp targets a meaningfully smaller runtime image built with multi-stage builds on a slim Node.js 22 LTS ("jod") base, published as a multi-arch image (amd64 and arm64) to the GitHub Container Registry (ghcr.io).

The modernized image runs as an unprivileged non-root user across Docker, Podman, and k3s (Kubernetes), with an overridable UID/GID for Kubernetes securityContext and host-permission alignment. It preserves ioBroker installer-required behaviors (derived from the ioBroker installer_library.sh), retains multihost support via configurable objects/states database backends (networked `jsonl` by default, or Redis), provides an upgrade-tolerant healthcheck usable by both Docker-style HEALTHCHECK and Kubernetes probes, uses a reduced persistence layout, and includes proper PID 1 signal handling with zombie reaping.

## Glossary

- **Container_Image**: The modernized ioBroker container image produced by this feature.
- **Build_Stage**: The multi-stage build stage that compiles native modules and holds the build toolchain; excluded from the final runtime image.
- **Runtime_Image**: The final image layer shipped to users; contains only runtime-necessary components.
- **Iobroker_Runtime**: The ioBroker installation and js-controller process running inside the Container_Image at `/opt/iobroker`.
- **Js_Controller**: The ioBroker js-controller process, the core supervisory process of the Iobroker_Runtime.
- **Init_Process**: The PID 1 init program (e.g., tini or dumb-init or equivalent) responsible for signal forwarding and zombie reaping.
- **Healthcheck_Mechanism**: The underlying script or command that verifies Js_Controller responsiveness, invokable by both Docker-style HEALTHCHECK and Kubernetes liveness/readiness probes.
- **Startup_Grace_Period**: A configurable time allowance during which the Healthcheck_Mechanism does not report unhealthy while the Iobroker_Runtime is starting or restarting.
- **Upgrade_Tolerance_Window**: A configurable time allowance during which the Healthcheck_Mechanism tolerates failed checks caused by a Js_Controller or adapter upgrade restart without reporting unhealthy.
- **Container_User**: The unprivileged non-root Linux user account that the Iobroker_Runtime runs as, identified by an overridable UID and GID.
- **Database_Backend**: The objects/states database an ioBroker host connects to. Each of the objects DB and states DB has an independent type (`jsonl` — the network-capable default, `file`, or `redis`), host, and port. In a multihost setup, slaves point their objects/states DB host at the master; Redis is one option, not a requirement.
- **Multihost_Role**: The role of a Container_Image instance in a multihost setup, either master or slave.
- **Build_Config**: The maintainer-owned build configuration in the repository's `package.json` under the `containerImage` key, declaring the Node.js major version (`nodeMajor`) and the Debian release codename (`debianCodename`) used to build the Container_Image.
- **Container_Registry**: The GitHub Container Registry (ghcr.io) where the Container_Image is published.
- **Data_Volume**: The `iobroker-data` subfolder under `/opt/iobroker` holding ioBroker configuration and state.
- **Log_Volume**: The `log` subfolder under `/opt/iobroker` holding ioBroker logs.
- **Modules_Volume**: The optional `/opt/iobroker/node_modules` mount point that, when mounted, persists installed adapter code across container upgrades.
- **Reconciliation**: The container startup step that aligns the installed adapter code in `node_modules` with the adapters recorded in the Data_Volume, selecting online or offline behavior based on whether the Modules_Volume is mounted and whether the adapter registry is reachable.
- **IOB_Variable**: An environment variable specific to ioBroker configuration, using the `IOB_` prefix.

## Requirements

### Requirement 1: Multi-Architecture Publishing

**User Story:** As an ioBroker operator, I want a multi-architecture image published to ghcr.io, so that I can run ioBroker on both amd64 and arm64 hosts from a single image reference.

#### Acceptance Criteria

1. THE Container_Image SHALL be built for the amd64 architecture.
2. THE Container_Image SHALL be built for the arm64 architecture.
3. THE Container_Image SHALL be published to the Container_Registry as a single multi-architecture manifest that references both the amd64 and arm64 variants under a shared version tag and a shared "latest" tag, such that both architecture variants resolve from the same tag and manifest.
4. WHEN an operator pulls the Container_Image on an amd64 host, THE Container_Registry SHALL serve the amd64 variant.
5. WHEN an operator pulls the Container_Image on an arm64 host, THE Container_Registry SHALL serve the arm64 variant.
6. IF the build for either the amd64 or arm64 architecture fails, THEN THE Container_Image SHALL NOT be published to the Container_Registry, and the failure SHALL be reported with an indication identifying the failed architecture.
7. IF an operator pulls the Container_Image on a host whose architecture is neither amd64 nor arm64, THEN THE Container_Registry SHALL reject the pull with an error indication that no matching variant exists.
8. THE Container_Image SHALL be published to the Container_Registry only after both the amd64 build and the arm64 build succeed, such that publication is blocked entirely until both architecture builds succeed and no single-architecture image is published.

### Requirement 2: Slim Multi-Stage Base Image

**User Story:** As an ioBroker operator, I want a slim image built with multi-stage builds on Node.js 22 LTS, so that I download and store a meaningfully smaller image than the current ~1.6GB image.

#### Acceptance Criteria

1. THE Runtime_Image SHALL be based on the official Node.js image using the "jod" codename corresponding to Node.js 22 LTS.
2. THE Container_Image SHALL be produced using a multi-stage build that separates the Build_Stage from the Runtime_Image, where the Runtime_Image is derived exclusively from the final stage.
3. THE Runtime_Image SHALL exclude the native compile toolchain (compilers, build tools, and header packages) used only during the Build_Stage.
4. THE Runtime_Image SHALL include only the components required at runtime by the Iobroker_Runtime and SHALL exclude all components used solely during the Build_Stage.
5. THE Runtime_Image SHALL be meaningfully smaller than the current reference image of approximately 1.6GB.
6. WHEN the Container_Image build completes, THE Build_Stage SHALL produce a Runtime_Image in which the Iobroker_Runtime starts successfully with no missing runtime dependency errors.
7. IF a component required at runtime by the Iobroker_Runtime is absent from the Runtime_Image, THEN THE Container_Image build SHALL fail with an error indicating the missing runtime dependency and SHALL NOT publish the Runtime_Image.
8. WHERE aggressive size reduction would break Iobroker_Runtime functionality, THE Container_Image SHALL prioritize Iobroker_Runtime success over further size reduction.
9. IF any runtime dependency issue is detected, THEN THE Container_Image build SHALL fail and SHALL NOT publish the Runtime_Image.

### Requirement 3: Rootless Non-Root Execution

**User Story:** As a security-conscious operator, I want the container to run as an unprivileged non-root user, so that a compromised container has reduced host impact.

#### Acceptance Criteria

1. THE Iobroker_Runtime SHALL run as the Container_User, a non-root Linux user with a UID greater than or equal to 1000 and not equal to 0.
2. THE Container_Image SHALL declare the Container_User with a non-zero UID as the default user such that all processes for normal operation start without root privileges.
3. WHEN the Container_Image is started on Docker without a user override, THE Iobroker_Runtime SHALL run as the Container_User with a non-zero UID.
4. WHEN the Container_Image is started on Podman in rootless mode without a user override, THE Iobroker_Runtime SHALL run as the Container_User with a non-zero UID.
5. WHEN the Container_Image is started on k3s without a user override, THE Iobroker_Runtime SHALL run as the Container_User with a non-zero UID.
6. THE Iobroker_Runtime SHALL complete normal operation without invoking setuid-based privilege escalation and without reliance on sudo.
7. IF a process within the Container_Image attempts to escalate to root during normal operation, THEN THE Iobroker_Runtime SHALL deny the escalation and continue running as the Container_User.
8. WHERE an operator explicitly invokes a diagnostic or maintenance operation, THE Container_Image MAY permit setuid-based escalation for that specific operation, and this exception SHALL NOT apply to normal operation, which continues to be governed by criterion 6 and remains free of setuid-based escalation and reliance on sudo.

### Requirement 4: Overridable UID and GID

**User Story:** As a Kubernetes operator, I want the container's UID and GID to be selectable via the runtime (securityContext / `--user`), so that I can satisfy a securityContext and align with host file permissions.

#### Acceptance Criteria

1. WHERE the container runtime specifies a UID (Docker/Podman `--user`, Kubernetes `runAsUser`) in the range 0 to 65535, THE Iobroker_Runtime SHALL run under that UID.
2. WHERE the container runtime specifies a GID (Docker/Podman `--user`, Kubernetes `runAsGroup`/`fsGroup`) in the range 0 to 65535, THE Iobroker_Runtime SHALL run under that GID.
3. WHEN a Kubernetes securityContext assigns a runAsUser value in the range 0 to 65535, THE Iobroker_Runtime SHALL run under that value.
4. WHERE no UID or GID override is provided, THE Container_Image SHALL run the Iobroker_Runtime under the default non-root UID and GID, each equal to 1000.
5. WHEN a UID or GID override is applied, THE Container_Image SHALL grant the Iobroker_Runtime read and write access to the Data_Volume and the Log_Volume.
6. WHEN the Iobroker_Runtime runs under an arbitrary UID that is not present in /etc/passwd, THE Container_Image SHALL assign the Iobroker_Runtime membership in GID 0 and SHALL grant GID 0 read and write access to the Data_Volume and the Log_Volume; the GID 0 membership assignment and GID 0 volume access SHALL apply only in this arbitrary-UID case and SHALL NOT be applied when the runtime UID is present in /etc/passwd.
7. THE Container_Image SHALL NOT provide an in-image UID/GID environment variable (such as the former `SETUID`/`SETGID` or `IOB_UID`/`IOB_GID`); UID/GID selection is delegated entirely to the container runtime, because a non-root entrypoint cannot change its own UID/GID. Out-of-range or invalid UID/GID values are rejected by the container runtime.

### Requirement 5: Installer-Derived System Packages

**User Story:** As an ioBroker maintainer, I want the image to include the packages expected by the ioBroker installer, so that adapter installation and native module compilation succeed.

#### Acceptance Criteria

1. THE Build_Stage SHALL include the build-time packages required to compile native modules — build-essential, gcc, make, cmake, pkg-config, and the development header packages libavahi-compat-libdnssd-dev, libudev-dev, libpam0g-dev, libcairo2-dev, libpango1.0-dev, libjpeg-dev, libgif-dev, librsvg2-dev, and libpixman-1-dev — each queryable as installed within the Build_Stage.
2. THE Runtime_Image SHALL include the runtime packages required by the Iobroker_Runtime and the ioBroker installer — acl, sudo, libcap2-bin, git, curl, unzip, distro-info, net-tools, polkitd, passwd, and lsb-release — each queryable as installed within the Runtime_Image.
3. THE Runtime_Image SHALL exclude the build-essential, gcc, make, cmake, and development header packages that are used only during the Build_Stage, such that each is not queryable as installed within the Runtime_Image.
4. THE Container_Image SHALL read the Node.js major version to install from the integer value of the `nodeMajor` field of the Build_Config and install that exact major version.
5. IF the `nodeMajor` field of the Build_Config is missing, empty, or not a valid integer, THEN THE Container_Image build SHALL fail immediately before any package installation or image building begins, SHALL emit an error indication, SHALL NOT fall back to a system default Node.js version, and SHALL NOT produce a Runtime_Image, treating an empty `nodeMajor` field the same as a missing or invalid value.
6. THE Container_Image SHALL install the package sets named in criteria 1 and 2 without pinning the packages to fixed version numbers.
7. THE Container_Image SHALL read the Debian release codename used for both the Build_Stage and Runtime_Image base images from the `debianCodename` field of the Build_Config, such that the Build_Stage and Runtime_Image use the same codename; IF `debianCodename` is missing or empty, THEN the build SHALL fail immediately with an error indication and SHALL NOT produce a Runtime_Image.

### Requirement 6: Container Environment Detection

**User Story:** As an ioBroker maintainer, I want the ioBroker installer to detect that it runs inside a container, so that installer logic branches correctly for containerized deployments.

#### Acceptance Criteria

1. WHEN the ioBroker installer inspects `/proc/self/cgroup`, THE Container_Image SHALL present a detectable container indicator.
2. THE Container_Image SHALL provide `/.dockerenv` as a present, readable filesystem entry so that the ioBroker installer recognizes the container environment.
3. THE Container_Image SHALL provide `/run/.containerenv` as a present, readable filesystem entry under all supported container runtimes so that the ioBroker installer recognizes the container environment for broader container-detection compatibility.

### Requirement 7: Node Binary Capabilities in a Rootless Context

**User Story:** As an ioBroker operator, I want capability handling documented and correctly configured for rootless operation, so that adapters requiring network capabilities work with clear guidance on when added capabilities are needed.

#### Acceptance Criteria

1. THE Container_Image SHALL NOT apply file capabilities (such as cap_net_bind_service or cap_net_raw) to the Node binary, so that the Node process can be executed in a fully rootless container (for example rootless Podman with no allowed capabilities); a file capability carrying the effective bit would otherwise cause the kernel to refuse to execute the binary when the capability is absent from the process's permitted set, preventing container startup.
2. THE Container_Image SHALL document that, because the Node binary carries no file capabilities, binding to privileged ports below 1024 (and using raw sockets) requires runtime configuration — granting the capability as an ambient capability, lowering the unprivileged-port threshold via the net.ipv4.ip_unprivileged_port_start sysctl, or mapping/proxying the port at the runtime layer — and that a bare capability add alone is not sufficient.
3. IF an adapter requires cap_net_admin, THEN THE Container_Image SHALL document that the runtime must be started with an explicitly granted NET_ADMIN capability.
4. THE Container_Image SHALL document the list of ioBroker functions that operate without added runtime capabilities in a rootless context.
5. THE Container_Image SHALL document the list of ioBroker functions that require explicitly granted runtime capabilities.

### Requirement 8: Reduced Persistence Layout

**User Story:** As an ioBroker operator, I want to persist only the necessary folders and optionally persist node_modules, so that adapter data, configuration, and installed adapter code survive restarts and upgrades without bind-mounting the entire installation.

#### Acceptance Criteria

1. THE Iobroker_Runtime SHALL install to `/opt/iobroker` inside the Container_Image.
2. THE Container_Image SHALL expose the Data_Volume (`/opt/iobroker/iobroker-data`) as a mount point that can be backed by host or Kubernetes storage.
3. THE Container_Image SHALL expose the Log_Volume (`/opt/iobroker/log`) as a mount point that can be backed by host or Kubernetes storage.
4. THE Container_Image SHALL expose the Modules_Volume (`/opt/iobroker/node_modules`) as an optional mount point that can be backed by host or Kubernetes storage.
5. THE Data_Volume SHALL be the source of truth for the set of installed adapters and their versions.
6. WHEN the Container_Image starts with an empty Data_Volume, THE Iobroker_Runtime SHALL initialize the Data_Volume with a default ioBroker configuration and state, and WHERE the adapter registry is reachable SHALL install the `admin` adapter so the initial setup UI is available.
7. WHEN the Container_Image is restarted with the Data_Volume and Log_Volume persisted, THE Iobroker_Runtime SHALL retain the ioBroker configuration and state stored in the Data_Volume.
8. WHEN the Container_Image is upgraded to a new image version with the Data_Volume persisted, THE Iobroker_Runtime SHALL retain the ioBroker configuration and state stored in the Data_Volume.
9. WHEN the Container_Image starts and the adapter registry is reachable, THE Reconciliation SHALL install into `node_modules` the adapters recorded in the Data_Volume that are not already present, so that the installed adapter set converges to the Data_Volume, regardless of whether `node_modules` is a persisted mount.
10. WHERE `node_modules` already contains adapters (for example a persisted Modules_Volume), THE Reconciliation SHALL install only the Data_Volume adapters that are missing from the currently present `node_modules`, determined by inspecting `node_modules` content rather than by detecting mount state (mount state is not reliably distinguishable across container runtimes).
11. WHERE the adapter registry is not reachable, THE Reconciliation SHALL start the Iobroker_Runtime using the adapters currently present in `node_modules` without failing the startup, logging a warning when recorded adapters could not be installed.
12. WHEN the Iobroker_Runtime detects that the Node.js ABI of the running runtime differs from the ABI the present `node_modules` native modules were built for, THE Reconciliation SHALL attempt an npm rebuild of the affected native modules.
13. IF an npm rebuild of native modules is required but cannot be completed because the adapter registry or build resources are not reachable, THEN THE Reconciliation SHALL log a clear warning identifying the affected modules and SHALL still start the Iobroker_Runtime.

### Requirement 9: Upgrade-Tolerant Healthcheck

**User Story:** As an ioBroker operator, I want a healthcheck that verifies js-controller responsiveness but tolerates upgrade restarts, so that expected controller and adapter upgrades do not cause the container to be killed.

#### Acceptance Criteria

1. WHEN the Healthcheck_Mechanism runs a check, THE Healthcheck_Mechanism SHALL execute a Js_Controller status command and treat the Js_Controller as up and responsive only if the command returns a success exit code (0) within a per-check timeout of 30 seconds.
2. IF the Js_Controller status command returns a non-zero exit code or does not complete within the per-check timeout of 30 seconds, THEN THE Healthcheck_Mechanism SHALL treat the check as failed, subject to the tolerance behavior in criteria 3, 4, and 5.
3. WHILE the Iobroker_Runtime is within the Startup_Grace_Period, THE Healthcheck_Mechanism SHALL report a starting or healthy status and SHALL NOT report unhealthy, regardless of failed checks.
4. WHILE a Js_Controller or adapter upgrade is in progress and within the Upgrade_Tolerance_Window, THE Healthcheck_Mechanism SHALL report a starting or healthy status and SHALL NOT report unhealthy, regardless of failed checks caused by the restart.
5. IF a check fails outside the Startup_Grace_Period and outside the Upgrade_Tolerance_Window, THEN THE Healthcheck_Mechanism SHALL report an unhealthy status indicating the Js_Controller is unresponsive.
6. THE Container_Image SHALL expose the Healthcheck_Mechanism as a Docker-style HEALTHCHECK instruction usable by Docker and Podman.
7. THE Container_Image SHALL expose the Healthcheck_Mechanism as a command or endpoint invokable by Kubernetes liveness and readiness probes.
8. THE Startup_Grace_Period SHALL be configurable by the operator to any value from 0 to 3600 seconds, with a default of 300 seconds.
9. THE Upgrade_Tolerance_Window SHALL be configurable by the operator to any value from 0 to 3600 seconds, with a default of 600 seconds, and SHALL be applied independently of the Startup_Grace_Period.
10. WHEN a check runs and the Js_Controller status command returns a success exit code (0) within the per-check timeout, and the Iobroker_Runtime is outside the Startup_Grace_Period and outside the Upgrade_Tolerance_Window, THE Healthcheck_Mechanism SHALL report a healthy status.
11. THE Healthcheck_Mechanism SHALL treat the Startup_Grace_Period and the Upgrade_Tolerance_Window as independent, such that being within either window alone prevents an unhealthy report regardless of the other window.

### Requirement 10: Environment Variable Set and Naming Convention

**User Story:** As an ioBroker operator, I want a clear, conventionally named environment variable set, so that I can configure the container predictably and rely on preserved variable names.

#### Acceptance Criteria

1. THE Container_Image SHALL prefix every ioBroker-specific environment variable with `IOB_`.
2. THE Container_Image SHALL keep conventional non-ioBroker environment variables under their conventional names without the `IOB_` prefix, including TZ and LANG.
3. THE Container_Image SHALL retain the reference image environment variables whose names remain reasonable under the modernized design, covering timezone, language, admin port, web port, and multihost and database-backend settings. (UID/GID are NOT among them; they are set by the container runtime.)
4. WHERE an environment variable that has a defined default is unset in the initial container state captured at container start, THE Container_Image SHALL apply that variable's default value based on that initial container state, ignoring any variables set during early startup phases after the initial state is captured.
5. WHILE TZ is set to a valid timezone, THE Container_Image SHALL configure the container timezone to the value of TZ.
6. THE Container_Image SHALL exclude the SETUID variable from the environment variable set.
7. THE Container_Image SHALL exclude the SETGID variable from the environment variable set.
8. THE Container_Image SHALL document the retained environment variable set, including each variable name and its default value, and SHALL document the removed variables SETUID and SETGID.

### Requirement 11: Preserve Installer npm Behaviors

**User Story:** As an ioBroker maintainer, I want the image to preserve the installer's npm configuration, so that adapter installation behaves consistently with a standard ioBroker installation.

#### Acceptance Criteria

1. THE Container_Image SHALL provide an npm settings file for the Iobroker_Runtime containing `audit=false`.
2. THE Container_Image SHALL provide an npm settings file for the Iobroker_Runtime containing `update-notifier=false`.
3. THE Container_Image SHALL provide an npm settings file for the Iobroker_Runtime containing `engine-strict=true`.
4. WHEN an adapter is installed via npm within the Iobroker_Runtime, THE Container_Image SHALL apply the `audit=false`, `update-notifier=false`, and `engine-strict=true` settings to that operation.
5. IF the npm settings cannot be applied during an adapter installation because the settings file is corrupted or inaccessible, THEN THE Container_Image SHALL block the adapter installation rather than proceeding with default npm behavior.

### Requirement 12: Multihost and Database Backend Configuration

**User Story:** As an ioBroker operator running a multihost cluster, I want to configure the objects and states database backends (their type, host, and port) and the host role, so that objects and states can be shared across hosts — using either the networked default `jsonl` databases or an external Redis, without assuming Redis.

#### Acceptance Criteria

1. THE Container_Image SHALL support configuring the objects database and the states database independently, each with its own type, host, and port; the two databases are separate and MAY use different ports.
2. THE Container_Image SHALL support the database backend types `jsonl` (the ioBroker default, network-capable), `file`, and `redis` for each of the objects and states databases.
3. WHERE the operator does not specify any objects/states database backend variables, THE Container_Image SHALL leave the local database configuration created by the ioBroker setup unchanged (the default local `jsonl` databases), and SHALL NOT modify `iobroker.json`.
4. WHERE the operator specifies objects-database backend variables (type via IOB_OBJECTSDB_TYPE, host via IOB_OBJECTSDB_HOST, port via IOB_OBJECTSDB_PORT, and optionally name and password), THE Container_Image SHALL configure the objects database of the Iobroker_Runtime accordingly.
5. WHERE the operator specifies states-database backend variables (type via IOB_STATESDB_TYPE, host via IOB_STATESDB_HOST, port via IOB_STATESDB_PORT, and optionally name and password), THE Container_Image SHALL configure the states database of the Iobroker_Runtime accordingly.
6. WHERE an operator specifies the Multihost_Role as master or slave via IOB_MULTIHOST, THE Container_Image SHALL configure the Iobroker_Runtime with that multihost role; WHERE IOB_MULTIHOST is unset, THE Container_Image SHALL run standalone (no multihost role change).
7. WHEN the Container_Image restarts with the same database/multihost IOB_Variable values, THE Container_Image SHALL leave the existing configuration unchanged rather than reconfiguring it (idempotent).
8. WHEN the database/multihost IOB_Variable values change between starts, THE Container_Image SHALL re-apply the objects/states database and Multihost_Role configuration to match the current values.
9. IF an operator specifies a Multihost_Role value other than master or slave, a database type other than jsonl, file, or redis, or a database port outside the range 1 to 65535, THEN THE Container_Image SHALL not start the Iobroker_Runtime and SHALL emit an error indication identifying the invalid value.

### Requirement 13: Drop User Startup Scripts

**User Story:** As an ioBroker maintainer, I want custom user startup scripts removed, so that the modernized image has a smaller and more predictable startup surface.

#### Acceptance Criteria

1. THE Container_Image SHALL exclude the user startup script files and their invocation entry point carried by the reference image.
2. WHEN the Container_Image starts, THE Iobroker_Runtime SHALL start without executing any custom user startup scripts.
3. IF a custom user startup script is present in a mounted volume at runtime, THEN THE Container_Image SHALL ignore it and SHALL NOT execute it.

### Requirement 14: PID 1 Signal Handling and Zombie Reaping

**User Story:** As a container operator, I want proper PID 1 signal handling and zombie reaping, so that the container shuts down gracefully and does not accumulate defunct processes.

#### Acceptance Criteria

1. THE Container_Image SHALL run an Init_Process as PID 1.
2. WHEN the container runtime sends a SIGTERM signal to the container, THE Init_Process SHALL forward the SIGTERM signal to the Js_Controller within 1 second so that the Iobroker_Runtime begins a graceful shutdown.
3. IF the Js_Controller has not exited after the Init_Process forwarded the SIGTERM signal, THEN forced termination via SIGKILL SHALL be delegated to the container runtime's configured stop timeout (e.g. Docker `--stop-timeout`, Kubernetes `terminationGracePeriodSeconds`), which sends SIGKILL to the container after the grace period elapses; the Container_Image SHALL NOT implement its own in-image SIGKILL timer.
4. WHEN the Iobroker_Runtime exits, THE Init_Process SHALL propagate the exit code or terminating signal of the Js_Controller as the Container_Image exit status.
5. WHEN a child process of the Iobroker_Runtime terminates, THE Init_Process SHALL reap the terminated child process such that no defunct (zombie) process remains.
6. THE Init_Process SHALL provide PID 1 signal handling and zombie reaping under Docker, Podman, and k3s.

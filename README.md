# FabricNavigator

FabricNavigator is a self-hosted network management application with multi-seed SNMP discovery, interactive topology visualization, device management, browser-based ACLI/SSH sessions, tunneled device WebViews, and guided service provisioning for Extreme Networks switches.

## Project status

This repository contains the FabricNavigator overlay source code and the scripts used for installation, release creation, and secure updates. FabricNavigator's original code is licensed under the [GNU General Public License v3.0](LICENSE); bundled third-party components remain under their respective licenses. Production credentials, user accounts, device assignments, SSH host keys, TLS private keys, and container runtime data must never be committed.

Publication and release checks are documented in [`PUBLIC_RELEASE_CHECKLIST.md`](PUBLIC_RELEASE_CHECKLIST.md).

## Screenshots

The topology previews use simulated devices and links. MAC addresses, serial numbers, credentials, and live customer data are not included. Vendor product photographs have been replaced with generic switch artwork in these documentation images.

### Topology — light mode

![FabricNavigator topology demo in light mode](docs/screenshots/topology-demo-light.png)

### Topology — dark mode

![FabricNavigator topology demo in dark mode](docs/screenshots/topology-demo-dark.png)

## Installation and releases

- [`INSTALLATION.md`](INSTALLATION.md) — complete Windows installation and operations guide
- [`linux/README-Linux.md`](linux/README-Linux.md) — installer for an existing Ubuntu Server
- [`proxmox/README-Proxmox.md`](proxmox/README-Proxmox.md) — Proxmox VE Ubuntu 24.04 LTS template builder
- [`esxi/README-ESXi.md`](esxi/README-ESXi.md) — VMware ESXi 7/8 OVA appliance installer
- [`work/fabricnavigator-import/FabricNavigator-Docker-20260821/README-Windows.md`](work/fabricnavigator-import/FabricNavigator-Docker-20260821/README-Windows.md) — Windows Docker Desktop package reference
- [`work/fabricnavigator-import/FabricNavigator-Docker-20260821/GITHUB-PUBLISHING.md`](work/fabricnavigator-import/FabricNavigator-Docker-20260821/GITHUB-PUBLISHING.md) — release publishing guide
- [`docs/FABRICNAVIGATOR-API.md`](docs/FABRICNAVIGATOR-API.md) — bearer-token API for device and assigned SSH-session exports

New Windows installations use `FabricNavigator-Installer-VERSION.zip`. Existing Ubuntu servers can use the small `FabricNavigator-Linux-Online-Installer.tar.gz`, which automatically selects the newest stable release containing a complete installer, or the versioned offline `FabricNavigator-Linux-Installer-VERSION.tar.gz`. Ubuntu can unpack both without a separate ZIP utility, and the installer runs `apt-get update` and installs `unzip` and all remaining host dependencies automatically. Existing installations download the matching `FabricNavigator-Update-VERSION.zip` after an administrator approves the update.

The public-preparation release is `26.09.10.231`. Full installers may be published less frequently than core updates. Proxmox, VMware ESXi, and Ubuntu online installers automatically skip update-only releases and select the newest compatible stable release. The Hyper-V appliance is currently generated and tested locally and is not published as a GitHub release asset.

For disconnected environments, an administrator can download the update ZIP on another computer and upload it under **Administration → Updates → Offline update**. FabricNavigator validates the package structure, target version, archive paths, and SHA-256 digest before the privileged host updater installs it. This path does not require a GitHub token or Internet access on the FabricNavigator host.

Build `26.08.10.116` is the compatibility transition from full-image updates to the smaller `core-overlay-v1` format. An existing `26.08.10.115` installation can install the `26.08.10.116` update normally and does not need to be reinstalled. Starting with the following build, routine updates contain only the FabricNavigator core overlay and are built locally on the already installed Docker image. Full images remain available for new installations and for releases that change the operating-system or Tomcat base.

Proxmox and VMware ESXi appliances use 2 vCPU, 8 GB RAM, and a 30 GB system disk by default.

Persistent credentials, ACLI components, preferences, discovery settings, routes, and WebView assignments are stored in `/opt/fabricnavigator/data`. Existing installations using the previous data location are migrated automatically while retaining their Docker volume contents.

### Optional Extreme device images

Extreme product photographs are distributed separately as `FabricNavigator-Extreme-Device-Images-VERSION.zip`. FabricNavigator uses the generic Fabric Engine and Switch Engine artwork when this optional package is not installed.

The optional package is not built from this repository. Its builder requires a separate source directory containing images that you are authorized to use and redistribute.

- Preferred: upload the unchanged ZIP under **Administration → Design → Device images**. The privileged Windows or Proxmox host updater validates and installs it.
- Command-line fallback on Windows Docker: extract the package and run `Install-Extreme-Device-Images.ps1` from the FabricNavigator installation directory.
- Command-line fallback on Proxmox: extract the package and run `sudo ./install-extreme-device-images.sh /opt/fabricnavigator`.

The plugin files are stored outside the container in `plugins/extreme-device-images`, so normal application updates neither download nor remove them.

## Security

- The web application has no access to the Docker socket.
- The host updater independently validates the repository, release version, and SHA-256 digest.
- Updates do not replace persistent Docker volumes.
- GitHub tokens are optional and must never be committed or embedded in the container image or release assets.

## Credits and third-party software

FabricNavigator is built on the work of several open-source projects and their contributors:

| Project | Use in FabricNavigator | Credit / license |
| --- | --- | --- |
| [ACLI Terminal](https://github.com/lgastevens/ACLI-terminal) | Interactive, browser-based switch sessions and file-based ACLI updates | Created and maintained by Ludovico Stevens (`lgastevens`), GNU GPL v3.0 |
| [SNMP4J](https://www.snmp4j.org/) | SNMPv1, SNMPv2c, and SNMPv3 discovery and device information | AGENTPP, Apache License 2.0 |
| [xterm.js](https://github.com/xtermjs/xterm.js) | Browser terminal rendering and keyboard input | MIT License |
| [Apache Tomcat](https://tomcat.apache.org/) | Java web application runtime | Apache License 2.0 |
| [nginx](https://nginx.org/) | HTTPS endpoint and reverse proxy | BSD-2-Clause License |
| [OpenJDK](https://openjdk.org/), [Python](https://www.python.org/), and [Perl](https://www.perl.org/) | Application, update, proxy, discovery, and terminal runtime components | Their respective project licenses |

Optional Extreme Networks product photographs and trademarks remain the property of their respective rights holders and are distributed separately from the FabricNavigator core. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and the in-application **Credits** page for the complete acknowledgements.

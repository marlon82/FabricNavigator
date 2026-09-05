# FabricNavigator on an existing Ubuntu server

This package installs FabricNavigator on an already installed Ubuntu Server 22.04 LTS or newer (amd64). The FabricNavigator container image is included. Ubuntu packages and Docker are intentionally not bundled: the installer downloads supported packages from the configured Ubuntu mirrors and Docker's official APT repository.

For a much smaller download, use `FabricNavigator-Linux-Online-Installer.tar.gz`.
It resolves the latest stable GitHub release and downloads the matching
FabricNavigator install image during setup. See `README-Linux-Online.md`.

## Requirements

- Ubuntu Server 22.04 LTS or newer, amd64
- root access through `sudo`
- working DNS and Internet access during installation
- access to the managed network from the Ubuntu host
- TCP port 8443 available
- approximately 2 GB of free disk space

The installer adds these host dependencies when required:

- `ca-certificates`, `curl`, `gnupg`, `python3`, and `unzip` from Ubuntu
- Docker Engine, containerd, Buildx, and Docker Compose v2 from Docker's official Ubuntu repository

## Install

The `tar.gz` package is recommended on a fresh Ubuntu installation because
Ubuntu can extract it without installing `unzip` first. Verify it against the
published SHA-256 manifest before extracting it.

```bash
sha256sum -c SHA256SUMS-Linux-26.09.10.231
tar -xzf FabricNavigator-Linux-Installer-26.09.10.231.tar.gz
cd FabricNavigator-Linux-26.09.10.231
chmod +x install-fabricnavigator.sh
sudo ./install-fabricnavigator.sh
```

No manual `apt-get` command is required. As its first installation step, the
script runs `apt-get update` and installs `unzip` together with the remaining
host dependencies. A ZIP with identical contents is also provided for systems
where `unzip` is already available.

For a private fork or authenticated GitHub API access, an optional update token can be installed at the same time without placing it inside the installer archive:

```bash
sudo ./install-fabricnavigator.sh \
  --token-file /root/github-update-token.txt
```

Use `--configure-ufw` if UFW is active and the installer should allow TCP port 8443. Without this option, firewall configuration is left unchanged.

After installation, open `https://SERVER-IP:8443/`. The first-run wizard creates the administrator and collects discovery settings.

## Operations

```bash
cd /opt/fabricnavigator
sudo docker compose ps
sudo docker compose logs --tail 200 fabricnavigator
sudo docker compose restart fabricnavigator
sudo systemctl status fabricnavigator-updater.service
```

To add or replace an optional GitHub update token later:

```bash
sudo fabricnavigator-token /path/to/github-update-token.txt
```

Existing installations should be upgraded through **Administration > Updates**. The Linux installer deliberately refuses to overwrite an existing `/opt/fabricnavigator/compose.yaml`.

Persistent users, credentials, topology data, certificates, and settings are stored in Docker volumes. Do not run `docker compose down --volumes` unless permanent data deletion is intended.

## Build the Linux installer

Maintainers can derive the Linux package from the matching verified Windows installer without rebuilding the container image:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\linux\Build-Linux-Installer.ps1 `
  -Version 26.09.10.231
```

The resulting online `tar.gz`, versioned offline `tar.gz`, ZIP, and
`SHA256SUMS-Linux-VERSION` are written to `linux/dist`. Ubuntu and Docker
package dependencies are not copied into the archives.

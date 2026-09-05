# Installing FabricNavigator

This guide covers the first installation on Windows with Docker Desktop and secure updates from the public GitHub repository. For an existing Ubuntu Server, use the [Linux installer guide](linux/README-Linux.md). For Proxmox VE, use the [Ubuntu template builder guide](proxmox/README-Proxmox.md). For VMware ESXi 7/8, use the [OVA appliance installer guide](esxi/README-ESXi.md).

The Ubuntu installer contains the FabricNavigator container image but does not bundle operating-system dependencies. It installs the required Ubuntu packages plus Docker Engine and Docker Compose from their configured online repositories.

## Requirements

- Windows 10 or Windows 11 x64
- Docker Desktop using Linux containers and Docker Compose v2
- At least 2 GB of free disk space
- Network access from the Windows host and Docker Desktop VM to the managed devices
- Local administrator rights for the host updater and optional firewall changes

Verify Docker before installation:

```powershell
docker version
docker compose version
```

## Install

1. Download the newest `FabricNavigator-Installer-VERSION.zip` and matching checksum manifest from the [latest release that includes an installer](https://github.com/marlon82/FabricNavigator/releases). Update-only releases can intentionally omit a full installer.
2. Verify the package:

   ```powershell
   Get-FileHash -Algorithm SHA256 .\FabricNavigator-Installer-VERSION.zip
   Get-Content .\SHA256SUMS
   ```

   Do not install the package if the hashes differ.

3. Extract it to a permanent directory:

   ```powershell
   New-Item -ItemType Directory -Force C:\FabricNavigator
   Expand-Archive .\FabricNavigator-Installer-VERSION.zip C:\FabricNavigator -Force
   Get-ChildItem C:\FabricNavigator -Recurse | Unblock-File
   Set-Location C:\FabricNavigator
   ```

4. Start the installer:

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\Import-FabricNavigator.ps1 -GitHubRepository marlon82/FabricNavigator
   ```

The installer imports the Docker image, starts Compose, creates the **FabricNavigator Updater** scheduled task, and configures support for host-level static routes. Use `-SkipUpdater` only if automatic updates and host route management are not required.

## First start

Open <https://localhost:8443/> locally or `https://WINDOWS-HOST-IP:8443/` from the LAN. The first-run wizard creates the initial administrator and collects optional SNMP, SSH, and WebView credentials before opening topology discovery.

FabricNavigator initially creates a self-signed certificate. For production, upload a PKCS#12 certificate under **Administration → System** whose DNS name or IP address matches the server.

If the Windows firewall blocks access from the LAN, run as administrator:

```powershell
New-NetFirewallRule -DisplayName "FabricNavigator HTTPS" -Direction Inbound -Protocol TCP -LocalPort 8443 -Action Allow
```

Restrict the firewall rule to the required private networks.

## GitHub updates

Public FabricNavigator releases can be checked and installed without a GitHub token. A token remains optional for private forks or higher authenticated GitHub API limits and can be stored under **Administration → Updates**. It is sent once over HTTPS, stored by the privileged host updater with restricted permissions, never displayed again, and never logged.

The host updater independently validates the repository, version, and SHA-256 digest, imports the new image, restarts FabricNavigator, and performs a health check. If the health check fails, it restores the previous runtime configuration. Persistent users, credentials, devices, host keys, certificates, and preferences remain intact.

## Operations

Run these commands from the installation directory:

```powershell
docker compose ps
docker compose logs --tail 200 fabricnavigator
docker compose restart fabricnavigator
docker compose down
docker compose up -d
```

Do not use `docker compose down --volumes` unless you intentionally want to permanently delete FabricNavigator data.

Back up these volumes before major changes: `fabricnavigator_security`, `fabricnavigator_devices`, and `fabricnavigator_tls`. Treat backups as secrets.

For update compatibility, the existing `fabricnavigator_security` volume name is retained, but its application data is mounted at `/opt/fabricnavigator/data`. Older installations are migrated automatically when the container starts.

## Troubleshooting

- **Docker not found:** Start Docker Desktop and wait until it reports that it is running.
- **PowerShell blocks the script:** Run `Set-ExecutionPolicy -Scope Process Bypass` and `Get-ChildItem . -Recurse | Unblock-File`.
- **Site unavailable:** Check `docker compose ps`, `docker compose logs --tail 200 fabricnavigator`, and `Test-NetConnection localhost -Port 8443`.
- **Update check returns 403 due to API limits:** Wait for the unauthenticated GitHub API limit to reset or configure an optional fine-grained token.
- **Update check returns 404 for a fork:** Verify the configured owner/repository and, for a private fork, configure a token that can read it.
- **Updater task is not running:** Inspect the **FabricNavigator Updater** task in Windows Task Scheduler or rerun the installer without `-SkipUpdater`.

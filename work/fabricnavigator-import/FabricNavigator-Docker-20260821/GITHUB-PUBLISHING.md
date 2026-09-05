# Publishing FabricNavigator on GitHub

Publish FabricNavigator primarily as a ready-to-run Docker application. The Windows installer ZIP contains the same container plus the privileged host updater. SNMP communication uses Apache-2.0 licensed SNMP4J. Optional product-image packages remain outside the public core distribution unless their redistribution rights are confirmed.

## Prepare the repository

1. Commit source code, scripts, and documentation. Generated archives, runtime state, and `.env` remain excluded by `.gitignore`.
2. Set `FABRICNAVIGATOR_GITHUB_REPOSITORY=OWNER/FabricNavigator` on installation hosts.
3. Public downloads require no token. A fine-grained token with **Contents: Read-only** is optional for private forks or authenticated API limits. Never place it in the image, `.env`, JavaScript, Git, or release artifacts.

## Build a release

```powershell
.\Build-FabricNavigator-Release.ps1 `
  -Version 26.08.10.109 `
  -SourceImage fabricnavigator:26.08.10.109
```

The script creates the installer ZIP, update ZIP, checksums, and release notes under `dist`.

## Publish the GitHub release

1. Create tag `vVERSION`.
2. Publish a normal GitHub release, not a draft.
3. Use the matching English release notes as the description.
4. Attach the update ZIP, Windows installer ZIP, small Linux online installer, Linux offline installer `tar.gz` and ZIP, Proxmox template builder ZIP, and checksum files.
5. Verify that GitHub exposes a `sha256:` digest for the update asset through the Releases API.

Build the Linux installer from the matching Windows installer before attaching it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\linux\Build-Linux-Installer.ps1 `
  -Version VERSION
```

The Admin UI reads release metadata from GitHub. The host updater downloads and validates the asset independently before changing the running installation. Persistent volumes are not deleted or replaced.

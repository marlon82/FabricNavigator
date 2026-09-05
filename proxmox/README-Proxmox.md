# FabricNavigator Proxmox VM Template

The builder creates an Ubuntu 24.04 LTS Cloud-Init template on a Proxmox VE node. The FabricNavigator release is embedded in the template. Docker Engine, Compose, QEMU Guest Agent, FabricNavigator, and the privileged Linux updater are configured automatically during the first boot of a clone. Static routes configured in FabricNavigator are applied to the Ubuntu Docker host rather than the container.

## Requirements

- Proxmox VE 8 or 9
- Internet access from the Proxmox node and future VM
- VM disk storage such as `local-lvm` and a bridge such as `vmbr0`
- About 4 GB of temporary free space
- No GitHub token is needed for the public FabricNavigator repository

The builder does not install or remove Proxmox packages. It uses the tools already supplied by Proxmox and aborts if required components are missing. An optional token can be used for a private fork or higher API limits and is never copied into the image or template.

## Create the template

Download these release assets:

- `FabricNavigator-Proxmox-Template-Builder-26.09.10.231.zip`
- `SHA256SUMS-Proxmox-26.09.10.231`

Copy them to the Proxmox host and prepare the builder:

```powershell
scp .\FabricNavigator-Proxmox-Template-Builder-26.09.10.231.zip root@PROXMOX-IP:/root/
scp .\SHA256SUMS-Proxmox-26.09.10.231 root@PROXMOX-IP:/root/
```

```bash
cd /root
sha256sum --check SHA256SUMS-Proxmox-26.09.10.231
unzip FabricNavigator-Proxmox-Template-Builder-26.09.10.231.zip -d /root
# Alternative when unzip is unavailable:
# python3 -m zipfile -e FabricNavigator-Proxmox-Template-Builder-26.09.10.231.zip /root
cd /root/FabricNavigator-Proxmox-26.09.10.231
chmod +x create-fabricnavigator-template.sh
```

Run the builder directly. It scans stable releases and chooses the newest release containing a complete FabricNavigator installer, so an update-only latest release is skipped automatically:

```bash
./create-fabricnavigator-template.sh \
  --vmid 9000 \
  --storage local-lvm \
  --bridge vmbr0
```

Alternatively, use a previously downloaded installer and its matching version:

```bash
./create-fabricnavigator-template.sh \
  --installer /root/FabricNavigator-Installer-26.09.10.231.zip \
  --vmid 9000 \
  --storage local-lvm \
  --bridge vmbr0
```

Existing VM IDs are never overwritten. Run `./create-fabricnavigator-template.sh --help` for all options.

## SSH username and password access

The template enables password authentication for the Cloud-Init user `fabricnavigator`, but does not embed a default password. Supply an initial password from a protected file:

```bash
printf '%s' 'USE-A-LONG-UNIQUE-PASSWORD' > /root/fabricnavigator-vm-password.txt
chmod 600 /root/fabricnavigator-vm-password.txt
./create-fabricnavigator-template.sh \
  --ssh-user fabricnavigator \
  --ssh-password-file /root/fabricnavigator-vm-password.txt \
  --vmid 9000 --storage local-lvm --bridge vmbr0
rm -f /root/fabricnavigator-vm-password.txt
```

Without `--ssh-password-file`, configure the user and password or SSH public key in the clone's **Cloud-Init** settings. Root password login remains disabled.

## Create a VM from the template

1. Select `fabricnavigator-ubuntu-template` in Proxmox.
2. Create a **Full Clone**.
3. Configure the Cloud-Init user, password or SSH key, and IP settings.
4. Start the VM.
5. Monitor first boot with `journalctl -u fabricnavigator-firstboot -f` if required.
6. Open `https://VM-IP:8443/`.

Recommended resources are 2 vCPU, 8 GB RAM, and a 30 GB disk.

## Optional authenticated updates

No token is needed for public updates. For a private fork or authenticated API limits, install a read-only token on the final clone without printing it:

```bash
sudo fabricnavigator-token /path/github-update-token.txt
rm -f /path/github-update-token.txt
```

Update checks, release notes, and administrator-approved installation are then available under **Administration → Updates**. The Linux updater validates the release version and GitHub SHA-256 digest, restarts Compose, performs a health check, and preserves persistent volumes.

## Troubleshooting

A GitHub `404 Not Found` normally means the owner, repository, tag, or required release asset is missing. For a private fork, also verify that the optional fine-grained token can read the repository. The token file must contain only the token, without quotes, `Token=`, or extra whitespace.

Connectivity checks:

```bash
getent ahostsv4 api.github.com
curl --ipv4 --http1.1 --connect-timeout 15 --max-time 30 --fail --show-error --location --output /dev/null https://api.github.com/
curl --ipv4 --http1.1 --connect-timeout 15 --max-time 30 --fail --show-error --location --output /dev/null https://cloud-images.ubuntu.com/noble/current/SHA256SUMS
```

Operations and diagnostics:

```bash
sudo docker compose --project-directory /opt/fabricnavigator ps
sudo docker compose --project-directory /opt/fabricnavigator logs --tail 200 fabricnavigator
sudo systemctl status fabricnavigator-firstboot fabricnavigator-updater
sudo journalctl -u fabricnavigator-updater -n 100
```

First boot is complete when `/var/lib/fabricnavigator-firstboot.complete` exists. Do not delete Docker volumes if users, devices, credentials, TLS data, and preferences must be retained.

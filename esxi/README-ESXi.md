# FabricNavigator on VMware ESXi

The ESXi installer creates an importable OVA containing Ubuntu Server, the FabricNavigator Docker image, the host updater, and VMware Tools. The resulting appliance does not require Docker to be installed manually.

Default virtual hardware:

- 2 vCPU
- 8 GB RAM
- 30 GB system disk
- VMXNET3 network adapter
- VMware virtual hardware version 17 (ESXi 7.0 or newer)

## Build the OVA

The downloaded installer ZIP contains the verified FabricNavigator payload and the OVA builder. Run the builder on a temporary Ubuntu 22.04/24.04 x86-64 system, not in the ESXi Shell and not directly on a Proxmox host.

```bash
sudo apt-get update
sudo apt-get install -y curl python3 unzip qemu-utils openssl genisoimage
unzip FabricNavigator-ESXi-Installer-26.09.10.231.zip
cd FabricNavigator-ESXi-26.09.10.231
printf '%s\n' 'replace-with-a-strong-initial-password' > ssh-password.txt
chmod 600 ssh-password.txt
sudo bash ./create-fabricnavigator-esxi-ova.sh \
  --payload ./FabricNavigator-ESXi-Payload-26.09.10.231.zip \
  --ssh-password-file ./ssh-password.txt \
  --output-directory ./output \
  --yes
```

The generated `FabricNavigator-ESXi-26.09.10.231.ova` and its SHA-256 file are written to `./output`.

The build system needs approximately 15 GB of free temporary disk space and internet access to download the checksum-verified Ubuntu Noble cloud image.

## Import into ESXi

1. In the ESXi Host Client select **Create / Register VM**.
2. Select **Deploy a virtual machine from an OVF or OVA file**.
3. Upload the generated OVA.
4. Select the datastore and destination network.
5. Complete the wizard and start the VM.
6. Obtain the DHCP address from ESXi or your DHCP server.
7. Open `https://VM-IP:8443` and complete the FabricNavigator setup wizard.

SSH uses the configured user `fabricnavigator` and the password supplied while building the OVA. Root password login remains disabled.

Public updates need no token. To use a private fork or authenticated GitHub API limits, optionally store a token inside the appliance:

```bash
sudo fabricnavigator-token /path/to/github-update-token.txt
```

The token can also be stored from **Administration → Updates** after initial web setup.

#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="${VERSION:-latest}"
REPOSITORY="${REPOSITORY:-marlon82/FabricNavigator}"
VM_NAME="${VM_NAME:-fabricnavigator}"
MEMORY="${MEMORY:-8192}"
CORES="${CORES:-2}"
DISK_SIZE="${DISK_SIZE:-30G}"
UBUNTU_IMAGE_URL="${UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
TOKEN_FILE=""
PAYLOAD_FILE=""
SSH_USER="${SSH_USER:-fabricnavigator}"
SSH_PASSWORD_FILE=""
OUTPUT_DIRECTORY="${OUTPUT_DIRECTORY:-$PWD}"
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage:
  sudo ./create-fabricnavigator-esxi-ova.sh --ssh-password-file /path/password.txt [options]
  sudo ./create-fabricnavigator-esxi-ova.sh --payload /path/FabricNavigator-ESXi-Payload-VERSION.zip --ssh-password-file /path/password.txt [options]

Options:
  --version VERSION        Exact release; default: latest stable ESXi installer
  --repository OWNER/REPO  GitHub repository
  --token-file PATH        Optional token for private forks or higher API limits
  --payload PATH           Use a previously downloaded ESXi payload ZIP
  --ssh-user USER          Initial SSH user (default: fabricnavigator)
  --ssh-password-file PATH File containing the initial SSH password
  --name NAME              Appliance and VM name (default: fabricnavigator)
  --memory MIB             Memory in MiB (default: 8192)
  --cores COUNT            CPU cores (default: 2)
  --disk-size SIZE         Virtual disk size (default: 30G)
  --output-directory PATH  OVA output directory (default: current directory)
  --yes                    Do not ask for confirmation
  --help                    Show this help
EOF
}

while (($#)); do
  case "$1" in
    --version) VERSION=$2; shift 2 ;;
    --repository) REPOSITORY=$2; shift 2 ;;
    --token-file) TOKEN_FILE=$2; shift 2 ;;
    --payload) PAYLOAD_FILE=$2; shift 2 ;;
    --ssh-user) SSH_USER=$2; shift 2 ;;
    --ssh-password-file) SSH_PASSWORD_FILE=$2; shift 2 ;;
    --name) VM_NAME=$2; shift 2 ;;
    --memory) MEMORY=$2; shift 2 ;;
    --cores) CORES=$2; shift 2 ;;
    --disk-size) DISK_SIZE=$2; shift 2 ;;
    --output-directory) OUTPUT_DIRECTORY=$2; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run this builder as root." >&2; exit 1; }
[[ "$VERSION" == "latest" || "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid version." >&2; exit 1; }
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Invalid repository." >&2; exit 1; }
[[ "$VM_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "Invalid VM name." >&2; exit 1; }
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "Invalid SSH user." >&2; exit 1; }
[[ "$MEMORY" =~ ^[0-9]+$ && "$MEMORY" -ge 2048 ]] || { echo "Memory must be at least 2048 MiB." >&2; exit 1; }
[[ "$CORES" =~ ^[0-9]+$ && "$CORES" -ge 1 ]] || { echo "CPU core count must be positive." >&2; exit 1; }
[[ "$DISK_SIZE" =~ ^[1-9][0-9]*G$ ]] || { echo "Disk size must use the form 30G." >&2; exit 1; }
[[ -f "$SSH_PASSWORD_FILE" ]] || { echo "Provide --ssh-password-file." >&2; exit 1; }
if [[ -n "$TOKEN_FILE" && ! -f "$TOKEN_FILE" ]]; then
  echo "The optional GitHub token file was not found." >&2
  exit 1
fi
if [[ -n "$PAYLOAD_FILE" ]]; then
  [[ -f "$PAYLOAD_FILE" ]] || { echo "ESXi payload ZIP was not found." >&2; exit 1; }
  if [[ "$VERSION" == "latest" && "$(basename -- "$PAYLOAD_FILE")" =~ ^FabricNavigator-ESXi-Payload-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\.zip$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
  fi
  [[ "$VERSION" != "latest" ]] || { echo "Use a versioned FabricNavigator-ESXi-Payload-VERSION.zip or add --version." >&2; exit 1; }
fi

for command in curl python3 unzip qemu-img qemu-nbd lsblk mount umount openssl genisoimage sha256sum tar; do
  command -v "$command" >/dev/null || {
    echo "Missing command: $command. On Ubuntu/Debian install curl python3 unzip qemu-utils openssl genisoimage." >&2
    exit 1
  }
done

SSH_PASSWORD=$(tr -d '\r\n' < "$SSH_PASSWORD_FILE")
(( ${#SSH_PASSWORD} >= 12 )) || { echo "The initial SSH password must contain at least 12 characters." >&2; exit 1; }
SSH_PASSWORD_HASH=$(printf '%s' "$SSH_PASSWORD" | openssl passwd -6 -stdin)
SSH_PASSWORD=""

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d /tmp/fabricnavigator-esxi.XXXXXX)
MOUNT_POINT="$WORK/mnt"
NBD_DEVICE=""
NBD_CONNECTED=0
IMAGE_MOUNTED=0
cleanup() {
  set +e
  if (( IMAGE_MOUNTED )); then umount "$MOUNT_POINT"; fi
  if (( NBD_CONNECTED )); then qemu-nbd --disconnect "$NBD_DEVICE"; fi
  rm -rf -- "$WORK"
}
trap cleanup EXIT

echo "FabricNavigator ESXi appliance"
echo "  Version:  $([[ "$VERSION" == "latest" ]] && printf 'latest stable ESXi installer' || printf '%s' "$VERSION")"
echo "  VM:       $VM_NAME"
echo "  CPU/RAM:  $CORES cores / $MEMORY MiB"
echo "  Disk:     $DISK_SIZE"
echo "  SSH user: $SSH_USER"
if (( ! ASSUME_YES )); then
  read -r -p "Create the OVA? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || exit 0
fi

PAYLOAD="$WORK/fabricnavigator-esxi-payload.zip"
if [[ -n "$PAYLOAD_FILE" ]]; then
  cp -- "$PAYLOAD_FILE" "$PAYLOAD"
else
  auth="$WORK/curl.conf"
  printf 'header = "X-GitHub-Api-Version: 2022-11-28"\nheader = "User-Agent: FabricNavigator-ESXi-Builder"\n' > "$auth"
  if [[ -n "$TOKEN_FILE" ]]; then
    token=$(tr -d '\r\n' < "$TOKEN_FILE")
    [[ "$token" =~ ^[A-Za-z0-9_]{20,512}$ ]] || { echo "Invalid GitHub token format." >&2; exit 1; }
    printf 'header = "Authorization: Bearer %s"\n' "$token" >> "$auth"
    unset token
  fi
  chmod 0600 "$auth"
  release_json="$WORK/release.json"
  if [[ "$VERSION" == "latest" ]]; then
    release_url="https://api.github.com/repos/$REPOSITORY/releases?per_page=100"
  else
    release_url="https://api.github.com/repos/$REPOSITORY/releases/tags/v$VERSION"
  fi
  curl --fail --show-error --silent --location --max-time 60 --config "$auth" \
    -H 'Accept: application/vnd.github+json' \
    "$release_url" -o "$release_json"
  IFS=$'\t' read -r resolved_version asset_id asset_digest asset_kind < <(python3 - "$release_json" "$VERSION" <<'PY'
import json, pathlib, sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
releases = payload if isinstance(payload, list) else [payload]
requested = sys.argv[2]
for release in releases:
    if requested == "latest" and (release.get("draft") or release.get("prerelease")):
        continue
    version = str(release.get("tag_name", "")).removeprefix("v")
    if requested != "latest" and version != requested:
        continue
    assets = release.get("assets", [])
    for kind, name in (("payload", "FabricNavigator-ESXi-Payload-" + version + ".zip"),
                       ("installer", "FabricNavigator-ESXi-Installer-" + version + ".zip")):
        asset = next((item for item in assets if item.get("name") == name), None)
        if asset:
            print(version + "\t" + str(asset.get("id", "")) + "\t" + str(asset.get("digest", "")) + "\t" + kind)
            raise SystemExit
PY
  )
  [[ "$resolved_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$asset_id" =~ ^[0-9]+$ && "$asset_digest" =~ ^sha256:[0-9a-fA-F]{64}$ && "$asset_kind" =~ ^(payload|installer)$ ]] || {
    echo "ESXi payload or its SHA-256 digest was not found in the release. For a private fork, add --token-file PATH." >&2; exit 1;
  }
  VERSION="$resolved_version"
  echo "Selected FabricNavigator ESXi release: $VERSION"
  downloaded_asset="$WORK/esxi-release-asset.zip"
  curl --fail --show-error --silent --location --max-time 1800 --config "$auth" \
    -H 'Accept: application/octet-stream' \
    "https://api.github.com/repos/$REPOSITORY/releases/assets/$asset_id" -o "$downloaded_asset"
  printf '%s  %s\n' "${asset_digest#sha256:}" "$downloaded_asset" | sha256sum --check --status || {
    echo "ESXi release asset verification failed." >&2; exit 1;
  }
  if [[ "$asset_kind" == "payload" ]]; then
    cp -- "$downloaded_asset" "$PAYLOAD"
  else
    python3 - "$downloaded_asset" "$PAYLOAD" "$VERSION" <<'PY'
import pathlib, shutil, sys, zipfile
archive, destination, version = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
wanted = "FabricNavigator-ESXi-Payload-" + version + ".zip"
with zipfile.ZipFile(archive) as bundle:
    matches = [item for item in bundle.infolist() if pathlib.PurePosixPath(item.filename).name == wanted]
    if len(matches) != 1:
        raise SystemExit("The ESXi installer does not contain exactly one matching payload.")
    with bundle.open(matches[0]) as source, destination.open("wb") as output:
        shutil.copyfileobj(source, output)
PY
  fi
fi

APP="$WORK/fabricnavigator"
mkdir -p "$APP"
python3 - "$PAYLOAD" "$APP" <<'PY'
import pathlib, shutil, sys, zipfile
archive = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2]).resolve()
with zipfile.ZipFile(archive) as package:
    for member in package.infolist():
        relative = pathlib.PurePosixPath(member.filename)
        if relative.is_absolute() or ".." in relative.parts:
            raise SystemExit("Unsafe payload path")
        target = destination.joinpath(*relative.parts).resolve()
        if destination != target and destination not in target.parents:
            raise SystemExit("Unsafe payload path")
        if member.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with package.open(member) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
PY
[[ -f "$APP/compose.yaml" && -f "$APP/.env.example" ]] || { echo "Invalid ESXi payload." >&2; exit 1; }
image_count=$(find "$APP" -maxdepth 1 -type f -name 'FabricNavigator-Image-*.tar.gz' | wc -l)
[[ "$image_count" -eq 1 ]] || { echo "Payload contains no unique image archive." >&2; exit 1; }
sed -i "s|^FABRICNAVIGATOR_GITHUB_REPOSITORY=.*|FABRICNAVIGATOR_GITHUB_REPOSITORY=$REPOSITORY|" "$APP/.env.example"
rm -f -- "$APP/FabricNavigator-Updater.ps1" "$APP/Import-FabricNavigator.ps1"
mkdir -p "$APP/secrets" "$APP/update-state"

IMAGE="$WORK/ubuntu-noble.img"
CHECKSUMS="$WORK/SHA256SUMS"
curl --fail --show-error --location --max-time 1800 "$UBUNTU_IMAGE_URL" -o "$IMAGE"
curl --fail --show-error --silent --location --max-time 60 "${UBUNTU_IMAGE_URL%/*}/SHA256SUMS" -o "$CHECKSUMS"
image_name=${UBUNTU_IMAGE_URL##*/}
expected=$(awk -v name="$image_name" '$2 == name || $2 == "*" name {print $1; exit}' "$CHECKSUMS")
[[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "Ubuntu image checksum was not found." >&2; exit 1; }
printf '%s  %s\n' "$expected" "$IMAGE" | sha256sum --check --status || { echo "Ubuntu image verification failed." >&2; exit 1; }
qemu-img resize "$IMAGE" "$DISK_SIZE"

modprobe nbd max_part=16
for candidate in /dev/nbd{0..15}; do
  [[ -b "$candidate" ]] || continue
  device_name=${candidate##*/}
  if [[ ! -s "/sys/block/$device_name/pid" ]]; then NBD_DEVICE=$candidate; break; fi
done
[[ -n "$NBD_DEVICE" ]] || { echo "No unused NBD device is available." >&2; exit 1; }
qemu-nbd --format=qcow2 --connect="$NBD_DEVICE" "$IMAGE"
NBD_CONNECTED=1
udevadm settle
root_partition=$(lsblk -b -lnpo NAME,FSTYPE,SIZE,TYPE "$NBD_DEVICE" | awk '$2 == "ext4" && $4 == "part" && $3 > size {name=$1; size=$3} END {print name}')
[[ -b "$root_partition" ]] || { echo "Ubuntu root partition was not found." >&2; exit 1; }
mkdir -p "$MOUNT_POINT"
mount -o rw "$root_partition" "$MOUNT_POINT"
IMAGE_MOUNTED=1

install -d -m 0755 "$MOUNT_POINT/opt" "$MOUNT_POINT/usr/local/sbin" \
  "$MOUNT_POINT/etc/systemd/system/multi-user.target.wants" \
  "$MOUNT_POINT/etc/ssh/sshd_config.d" "$MOUNT_POINT/etc/cloud/cloud.cfg.d"
cat > "$MOUNT_POINT/etc/ssh/sshd_config.d/00-fabricnavigator-password-auth.conf" <<'EOF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
PermitRootLogin prohibit-password
EOF
cat > "$MOUNT_POINT/etc/cloud/cloud.cfg.d/99-fabricnavigator-ssh-password.cfg" <<'EOF'
ssh_pwauth: true
EOF
cp -a "$APP" "$MOUNT_POINT/opt/fabricnavigator"
install -m 0755 "$SCRIPT_DIR/guest/fabricnavigator-firstboot.sh" "$MOUNT_POINT/usr/local/sbin/fabricnavigator-firstboot"
install -m 0755 "$SCRIPT_DIR/guest/fabricnavigator-token" "$MOUNT_POINT/usr/local/sbin/fabricnavigator-token"
install -m 0755 "$SCRIPT_DIR/guest/fabricnavigator-updater.py" "$MOUNT_POINT/opt/fabricnavigator/fabricnavigator-updater.py"
install -m 0644 "$SCRIPT_DIR/guest/fabricnavigator-firstboot.service" "$MOUNT_POINT/etc/systemd/system/fabricnavigator-firstboot.service"
install -m 0644 "$SCRIPT_DIR/guest/fabricnavigator-updater.service" "$MOUNT_POINT/etc/systemd/system/fabricnavigator-updater.service"
ln -sfn ../fabricnavigator-firstboot.service "$MOUNT_POINT/etc/systemd/system/multi-user.target.wants/fabricnavigator-firstboot.service"
chmod 0700 "$MOUNT_POINT/opt/fabricnavigator/secrets"
chmod 0733 "$MOUNT_POINT/opt/fabricnavigator/update-state"
truncate -s 0 "$MOUNT_POINT/etc/machine-id"
rm -f "$MOUNT_POINT/var/lib/dbus/machine-id"
rm -rf "$MOUNT_POINT/var/lib/cloud/instances"/*
sync
umount "$MOUNT_POINT"
IMAGE_MOUNTED=0
qemu-nbd --disconnect "$NBD_DEVICE"
NBD_CONNECTED=0

OVA_STAGE="$WORK/ova"
mkdir -p "$OVA_STAGE" "$WORK/seed"
VMDK_NAME="$VM_NAME-disk1.vmdk"
OVF_NAME="$VM_NAME.ovf"
ISO_NAME="$VM_NAME-seed.iso"
MF_NAME="$VM_NAME.mf"
qemu-img convert -p -f qcow2 -O vmdk -o subformat=streamOptimized,compat6 "$IMAGE" "$OVA_STAGE/$VMDK_NAME"
cat > "$WORK/seed/meta-data" <<EOF
instance-id: $VM_NAME-$VERSION
local-hostname: $VM_NAME
EOF
cat > "$WORK/seed/user-data" <<EOF
#cloud-config
users:
  - default
  - name: $SSH_USER
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: '$SSH_PASSWORD_HASH'
ssh_pwauth: true
chpasswd:
  expire: false
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
EOF
genisoimage -quiet -output "$OVA_STAGE/$ISO_NAME" -volid cidata -joliet -rock -graft-points \
  "user-data=$WORK/seed/user-data" "meta-data=$WORK/seed/meta-data"

disk_bytes=$(( ${DISK_SIZE%G} * 1024 * 1024 * 1024 ))
vmdk_size=$(stat -c %s "$OVA_STAGE/$VMDK_NAME")
iso_size=$(stat -c %s "$OVA_STAGE/$ISO_NAME")
cat > "$OVA_STAGE/$OVF_NAME" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Envelope vmw:buildId="build-117" xmlns="http://schemas.dmtf.org/ovf/envelope/1" xmlns:cim="http://schemas.dmtf.org/wbem/wscim/1/common" xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1" xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData" xmlns:vmw="http://www.vmware.com/schema/ovf" xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData">
  <References>
    <File ovf:href="$VMDK_NAME" ovf:id="file1" ovf:size="$vmdk_size"/>
    <File ovf:href="$ISO_NAME" ovf:id="file2" ovf:size="$iso_size"/>
  </References>
  <DiskSection><Info>Virtual disk</Info><Disk ovf:capacity="$disk_bytes" ovf:capacityAllocationUnits="byte" ovf:diskId="disk1" ovf:fileRef="file1" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/></DiskSection>
  <NetworkSection><Info>Logical networks</Info><Network ovf:name="VM Network"><Description>FabricNavigator network</Description></Network></NetworkSection>
  <VirtualSystem ovf:id="$VM_NAME">
    <Info>FabricNavigator $VERSION</Info><Name>$VM_NAME</Name>
    <OperatingSystemSection ovf:id="101" vmw:osType="ubuntu64Guest"><Info>Ubuntu Linux 64-bit</Info></OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtual hardware</Info>
      <System><vssd:ElementName>Virtual Hardware Family</vssd:ElementName><vssd:InstanceID>0</vssd:InstanceID><vssd:VirtualSystemIdentifier>$VM_NAME</vssd:VirtualSystemIdentifier><vssd:VirtualSystemType>vmx-17</vssd:VirtualSystemType></System>
      <Item><rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits><rasd:Description>Number of virtual CPUs</rasd:Description><rasd:ElementName>$CORES virtual CPU(s)</rasd:ElementName><rasd:InstanceID>1</rasd:InstanceID><rasd:ResourceType>3</rasd:ResourceType><rasd:VirtualQuantity>$CORES</rasd:VirtualQuantity></Item>
      <Item><rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits><rasd:Description>Memory Size</rasd:Description><rasd:ElementName>${MEMORY}MB of memory</rasd:ElementName><rasd:InstanceID>2</rasd:InstanceID><rasd:ResourceType>4</rasd:ResourceType><rasd:VirtualQuantity>$MEMORY</rasd:VirtualQuantity></Item>
      <Item><rasd:Address>0</rasd:Address><rasd:Description>SCSI Controller</rasd:Description><rasd:ElementName>SCSI controller 0</rasd:ElementName><rasd:InstanceID>3</rasd:InstanceID><rasd:ResourceSubType>lsilogicsas</rasd:ResourceSubType><rasd:ResourceType>6</rasd:ResourceType></Item>
      <Item><rasd:AddressOnParent>0</rasd:AddressOnParent><rasd:ElementName>Hard disk 1</rasd:ElementName><rasd:HostResource>ovf:/disk/disk1</rasd:HostResource><rasd:InstanceID>4</rasd:InstanceID><rasd:Parent>3</rasd:Parent><rasd:ResourceType>17</rasd:ResourceType></Item>
      <Item><rasd:AddressOnParent>0</rasd:AddressOnParent><rasd:AutomaticAllocation>true</rasd:AutomaticAllocation><rasd:Connection>VM Network</rasd:Connection><rasd:Description>VMXNET3 network adapter</rasd:Description><rasd:ElementName>Network adapter 1</rasd:ElementName><rasd:InstanceID>5</rasd:InstanceID><rasd:ResourceSubType>VmxNet3</rasd:ResourceSubType><rasd:ResourceType>10</rasd:ResourceType></Item>
      <Item><rasd:Address>0</rasd:Address><rasd:Description>IDE Controller</rasd:Description><rasd:ElementName>IDE controller 0</rasd:ElementName><rasd:InstanceID>6</rasd:InstanceID><rasd:ResourceType>5</rasd:ResourceType></Item>
      <Item><rasd:AddressOnParent>0</rasd:AddressOnParent><rasd:AutomaticAllocation>true</rasd:AutomaticAllocation><rasd:ElementName>CD/DVD drive 1</rasd:ElementName><rasd:HostResource>ovf:/file/file2</rasd:HostResource><rasd:InstanceID>7</rasd:InstanceID><rasd:Parent>6</rasd:Parent><rasd:ResourceSubType>vmware.cdrom.iso</rasd:ResourceSubType><rasd:ResourceType>15</rasd:ResourceType></Item>
      <vmw:Config ovf:required="false" vmw:key="firmware" vmw:value="bios"/>
    </VirtualHardwareSection>
    <AnnotationSection><Info>FabricNavigator appliance</Info><Annotation>FabricNavigator $VERSION. Open https://VM-IP:8443 after first-boot provisioning.</Annotation></AnnotationSection>
  </VirtualSystem>
</Envelope>
EOF

(
  cd "$OVA_STAGE"
  : > "$MF_NAME"
  for file in "$OVF_NAME" "$VMDK_NAME" "$ISO_NAME"; do
    printf 'SHA256(%s)= %s\n' "$file" "$(sha256sum "$file" | awk '{print $1}')" >> "$MF_NAME"
  done
)
mkdir -p "$OUTPUT_DIRECTORY"
OVA="$OUTPUT_DIRECTORY/FabricNavigator-ESXi-$VERSION.ova"
rm -f -- "$OVA"
tar -C "$OVA_STAGE" -cf "$OVA" "$OVF_NAME" "$VMDK_NAME" "$ISO_NAME" "$MF_NAME"
sha256sum "$OVA" > "$OVA.sha256"

echo
echo "Created: $OVA"
echo "Import the OVA into ESXi, select the destination network, and start it."
echo "FabricNavigator becomes available at https://VM-IP:8443 after first-boot provisioning."
echo "SSH user: $SSH_USER"

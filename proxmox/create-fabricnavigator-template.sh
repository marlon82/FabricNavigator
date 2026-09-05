#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="${VERSION:-latest}"
REPOSITORY="${REPOSITORY:-marlon82/FabricNavigator}"
VM_ID="${VM_ID:-9000}"
VM_NAME="${VM_NAME:-fabricnavigator-ubuntu-template}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
MEMORY="${MEMORY:-8192}"
CORES="${CORES:-2}"
DISK_SIZE="${DISK_SIZE:-30G}"
UBUNTU_IMAGE_URL="${UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
TOKEN_FILE=""
INSTALLER_FILE=""
SSH_USER="${SSH_USER:-fabricnavigator}"
SSH_PASSWORD_FILE=""
ASSUME_YES=0

usage() {
  cat <<'EOF'
Create a Proxmox VE Ubuntu 24.04 FabricNavigator VM template.

Usage:
  ./create-fabricnavigator-template.sh [options]
  ./create-fabricnavigator-template.sh --installer /path/FabricNavigator-Installer-VERSION.zip [options]

Options:
  --vmid ID            Template VM ID (default: 9000)
  --name NAME          Template name
  --storage STORAGE    Proxmox storage for the VM disk (default: local-lvm)
  --bridge BRIDGE      Network bridge (default: vmbr0)
  --memory MIB         Memory in MiB (default: 8192)
  --cores COUNT        CPU cores (default: 2)
  --disk-size SIZE     Resulting disk size (default: 30G)
  --version VERSION    Exact release; default: latest stable release with installer
  --repository O/R     GitHub repository
  --token-file PATH    Optional token for private forks or higher API limits
  --installer PATH     Use an already downloaded installer ZIP
  --ssh-user USER      Cloud-Init SSH user (default: fabricnavigator)
  --ssh-password-file PATH
                       Read the initial SSH password from this file
  --yes                Do not ask for confirmation
  --help               Show this help

An optional token and the SSH password file are used only on the Proxmox host
and are never copied into the image. Without --ssh-password-file, set the
password in the clone's Proxmox Cloud-Init settings before its first boot.
EOF
}

while (($#)); do
  case "$1" in
    --vmid) VM_ID=$2; shift 2 ;;
    --name) VM_NAME=$2; shift 2 ;;
    --storage) STORAGE=$2; shift 2 ;;
    --bridge) BRIDGE=$2; shift 2 ;;
    --memory) MEMORY=$2; shift 2 ;;
    --cores) CORES=$2; shift 2 ;;
    --disk-size) DISK_SIZE=$2; shift 2 ;;
    --version) VERSION=$2; shift 2 ;;
    --repository) REPOSITORY=$2; shift 2 ;;
    --token-file) TOKEN_FILE=$2; shift 2 ;;
    --installer) INSTALLER_FILE=$2; shift 2 ;;
    --ssh-user) SSH_USER=$2; shift 2 ;;
    --ssh-password-file) SSH_PASSWORD_FILE=$2; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run this builder as root on a Proxmox VE node." >&2; exit 1; }
[[ "$VM_ID" =~ ^[1-9][0-9]+$ ]] || { echo "Invalid VM ID." >&2; exit 1; }
[[ "$VERSION" == "latest" || "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid version." >&2; exit 1; }
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Invalid repository." >&2; exit 1; }
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "Invalid SSH user." >&2; exit 1; }
if [[ -n "$SSH_PASSWORD_FILE" ]]; then
  [[ -f "$SSH_PASSWORD_FILE" ]] || { echo "SSH password file was not found." >&2; exit 1; }
  SSH_PASSWORD=$(tr -d '\r\n' < "$SSH_PASSWORD_FILE")
  (( ${#SSH_PASSWORD} >= 12 && ${#SSH_PASSWORD} <= 128 )) || {
    echo "The SSH password must contain between 12 and 128 characters." >&2; exit 1;
  }
else
  SSH_PASSWORD=""
fi
command -v qm >/dev/null || { echo "qm was not found. Run this on a Proxmox VE node." >&2; exit 1; }
if qm status "$VM_ID" >/dev/null 2>&1; then
  echo "VM ID $VM_ID already exists. Choose another ID; nothing was changed." >&2
  exit 1
fi
if [[ -n "$TOKEN_FILE" && ! -f "$TOKEN_FILE" ]]; then
  echo "The optional GitHub token file was not found." >&2
  exit 1
fi
if [[ -n "$INSTALLER_FILE" ]]; then
  [[ -f "$INSTALLER_FILE" ]] || { echo "Installer ZIP was not found." >&2; exit 1; }
  if [[ "$VERSION" == "latest" && "$(basename -- "$INSTALLER_FILE")" =~ ^FabricNavigator-Installer-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\.zip$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
  fi
  [[ "$VERSION" != "latest" ]] || { echo "Use a versioned FabricNavigator-Installer-VERSION.zip or add --version." >&2; exit 1; }
fi

cat <<EOF
Template configuration
  VM ID:       $VM_ID
  Name:        $VM_NAME
  Storage:     $STORAGE
  Bridge:      $BRIDGE
  CPU / RAM:   $CORES cores / $MEMORY MiB
  Disk:        $DISK_SIZE
  Release:     $([[ "$VERSION" == "latest" ]] && printf 'latest stable release with installer' || printf '%s v%s' "$REPOSITORY" "$VERSION")
  SSH user:    $SSH_USER
  SSH password:$([[ -n "$SSH_PASSWORD" ]] && printf ' configured' || printf ' set on clone')
EOF
if (( ! ASSUME_YES )); then
  read -r -p "Create this template? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || exit 0
fi

for required_command in curl python3 qemu-nbd qm pvesm sha256sum mount umount lsblk modprobe udevadm; do
  command -v "$required_command" >/dev/null 2>&1 || {
    echo "Required Proxmox host command is missing: $required_command" >&2
    exit 1
  }
done
dpkg-query -W -f='${Status}' proxmox-ve 2>/dev/null | grep -q '^install ok installed$' || {
  echo "The proxmox-ve metapackage is not installed. Refusing to modify this host." >&2
  exit 1
}

curl_download() {
  local description=$1
  local output=$2
  local max_time=$3
  shift 3
  echo "$description..."
  if ! curl --ipv4 --http1.1 \
      --connect-timeout 15 --max-time "$max_time" \
      --retry 2 --retry-delay 2 --retry-all-errors \
      --fail-with-body --silent --show-error --location \
      "$@" -o "$output"; then
    if [[ -s "$output" ]]; then
      echo "Server response (first 2048 bytes):" >&2
      head -c 2048 "$output" >&2 || true
      echo >&2
    fi
    echo "$description failed." >&2
    return 1
  fi
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d /var/tmp/fabricnavigator-template.XXXXXX)
CREATED_VM=0
NBD_DEVICE=""
NBD_CONNECTED=0
IMAGE_MOUNTED=0
MOUNT_POINT="$WORK/image-root"
cleanup() {
  if (( IMAGE_MOUNTED )); then
    umount "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  if (( NBD_CONNECTED )); then
    qemu-nbd --disconnect "$NBD_DEVICE" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$WORK"
  if (( CREATED_VM )) && qm status "$VM_ID" >/dev/null 2>&1; then
    echo "Build failed; removing incomplete VM $VM_ID." >&2
    qm destroy "$VM_ID" --purge 1 >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

INSTALLER="$WORK/fabricnavigator-installer.zip"
if [[ -n "$INSTALLER_FILE" ]]; then
  cp -- "$INSTALLER_FILE" "$INSTALLER"
else
  curl_config="$WORK/github-curl.conf"
  printf 'header = "X-GitHub-Api-Version: 2022-11-28"\nheader = "User-Agent: FabricNavigator-Proxmox-Builder"\n' > "$curl_config"
  if [[ -n "$TOKEN_FILE" ]]; then
    token=$(tr -d '\r\n' < "$TOKEN_FILE")
    [[ "$token" =~ ^[A-Za-z0-9_]{20,512}$ ]] || { echo "Invalid GitHub token format." >&2; exit 1; }
    printf 'header = "Authorization: Bearer %s"\n' "$token" >> "$curl_config"
    unset token
  fi
  chmod 0600 "$curl_config"
  release_json="$WORK/release.json"
  if [[ "$VERSION" == "latest" ]]; then
    release_url="https://api.github.com/repos/$REPOSITORY/releases?per_page=100"
  else
    release_url="https://api.github.com/repos/$REPOSITORY/releases/tags/v$VERSION"
  fi
  curl_download "Downloading GitHub release metadata" "$release_json" 60 --config "$curl_config" \
    -H 'Accept: application/vnd.github+json' \
    "$release_url"
  asset_info=$(python3 - "$release_json" "$VERSION" <<'PY'
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
    name = "FabricNavigator-Installer-" + version + ".zip"
    asset = next((item for item in release.get("assets", []) if item.get("name") == name), None)
    if asset:
        print(version + "\t" + str(asset.get("id", "")) + "\t" + str(asset.get("digest", "")))
        break
PY
  )
  IFS=$'\t' read -r resolved_version asset_id asset_digest <<< "$asset_info"
  [[ "$resolved_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$asset_id" =~ ^[0-9]+$ && "$asset_digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || {
    echo "Release installer asset or SHA-256 digest was not found. For a private fork, add --token-file PATH." >&2; exit 1;
  }
  VERSION="$resolved_version"
  echo "Selected FabricNavigator installer release: $VERSION"
  curl_download "Downloading FabricNavigator installer asset" "$INSTALLER" 1800 --config "$curl_config" \
    -H 'Accept: application/octet-stream' \
    "https://api.github.com/repos/$REPOSITORY/releases/assets/$asset_id"
  printf '%s  %s\n' "${asset_digest#sha256:}" "$INSTALLER" | sha256sum --check --status || {
    echo "Installer SHA-256 verification failed." >&2; exit 1;
  }
  rm -f -- "$curl_config" "$release_json"
fi

APP="$WORK/fabricnavigator"
mkdir -p "$APP"
python3 - "$INSTALLER" "$APP" <<'PY'
import pathlib, shutil, sys, zipfile
archive = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2]).resolve()
with zipfile.ZipFile(archive) as bundle:
    for member in bundle.infolist():
        name = member.filename.replace("\\", "/")
        target = (destination / name).resolve()
        if target != destination and destination not in target.parents:
            raise RuntimeError("Unsafe ZIP path: " + member.filename)
        if member.is_dir() or name.endswith('/'):
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with bundle.open(member) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
PY
[[ -f "$APP/compose.yaml" && -f "$APP/.env.example" ]] || { echo "Invalid installer archive." >&2; exit 1; }
image_count=$(find "$APP" -maxdepth 1 -type f -name 'FabricNavigator-Image-*.tar.gz' | wc -l)
[[ "$image_count" -eq 1 ]] || { echo "Installer contains no unique image archive." >&2; exit 1; }
sed -i "s|^FABRICNAVIGATOR_GITHUB_REPOSITORY=.*|FABRICNAVIGATOR_GITHUB_REPOSITORY=$REPOSITORY|" "$APP/.env.example"
rm -f -- "$APP/FabricNavigator-Updater.ps1" "$APP/Import-FabricNavigator.ps1"
mkdir -p "$APP/secrets" "$APP/update-state"

IMAGE="$WORK/ubuntu-noble.img"
CHECKSUMS="$WORK/SHA256SUMS"
curl_download "Downloading Ubuntu cloud image" "$IMAGE" 1800 "$UBUNTU_IMAGE_URL"
curl_download "Downloading Ubuntu image checksums" "$CHECKSUMS" 60 "${UBUNTU_IMAGE_URL%/*}/SHA256SUMS"
image_name=${UBUNTU_IMAGE_URL##*/}
expected=$(awk -v name="$image_name" '$2 == name || $2 == "*" name {print $1; exit}' "$CHECKSUMS")
[[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "Ubuntu image checksum was not found." >&2; exit 1; }
printf '%s  %s\n' "$expected" "$IMAGE" | sha256sum --check --status || {
  echo "Ubuntu cloud image SHA-256 verification failed." >&2; exit 1;
}

# libguestfs pulls qemu-system-x86 on Debian and conflicts with Proxmox's
# pve-qemu-kvm package. Attach the verified cloud image temporarily through an
# unused NBD device instead and modify its ext4 root filesystem directly.
modprobe nbd max_part=16
for candidate in /dev/nbd{0..15}; do
  [[ -b "$candidate" ]] || continue
  device_name=${candidate##*/}
  if [[ ! -s "/sys/block/$device_name/pid" ]]; then
    NBD_DEVICE=$candidate
    break
  fi
done
[[ -n "$NBD_DEVICE" ]] || { echo "No unused NBD device is available." >&2; exit 1; }
qemu-nbd --format=qcow2 --connect="$NBD_DEVICE" "$IMAGE"
NBD_CONNECTED=1
udevadm settle
root_partition=$(lsblk -b -lnpo NAME,FSTYPE,SIZE,TYPE "$NBD_DEVICE" | \
  awk '$2 == "ext4" && $4 == "part" && $3 > size {name=$1; size=$3} END {print name}')
[[ -b "$root_partition" ]] || { echo "Ubuntu image root partition was not found." >&2; exit 1; }
mkdir -p "$MOUNT_POINT"
mount -o rw "$root_partition" "$MOUNT_POINT"
IMAGE_MOUNTED=1

install -d -m 0755 "$MOUNT_POINT/opt" "$MOUNT_POINT/usr/local/sbin" \
  "$MOUNT_POINT/etc/systemd/system/multi-user.target.wants" \
  "$MOUNT_POINT/etc/ssh/sshd_config.d" "$MOUNT_POINT/etc/cloud/cloud.cfg.d"
cat > "$MOUNT_POINT/etc/ssh/sshd_config.d/00-fabricnavigator-password-auth.conf" <<'EOF'
# FabricNavigator appliance access. Authentication still requires a Cloud-Init
# user with a password configured in Proxmox.
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
PermitRootLogin prohibit-password
EOF
chmod 0644 "$MOUNT_POINT/etc/ssh/sshd_config.d/00-fabricnavigator-password-auth.conf"
cat > "$MOUNT_POINT/etc/cloud/cloud.cfg.d/99-fabricnavigator-ssh-password.cfg" <<'EOF'
# Permit the password set through Proxmox Cloud-Init for the non-root appliance
# user. Root password login remains prohibited by sshd configuration.
ssh_pwauth: true
EOF
chmod 0644 "$MOUNT_POINT/etc/cloud/cloud.cfg.d/99-fabricnavigator-ssh-password.cfg"
cp -a "$APP" "$MOUNT_POINT/opt/fabricnavigator"
install -m 0755 "$SCRIPT_DIR/guest/fabricnavigator-firstboot.sh" \
  "$MOUNT_POINT/usr/local/sbin/fabricnavigator-firstboot"
install -m 0755 "$SCRIPT_DIR/guest/fabricnavigator-token" \
  "$MOUNT_POINT/usr/local/sbin/fabricnavigator-token"
install -m 0755 "$SCRIPT_DIR/guest/fabricnavigator-updater.py" \
  "$MOUNT_POINT/opt/fabricnavigator/fabricnavigator-updater.py"
install -m 0644 "$SCRIPT_DIR/guest/fabricnavigator-firstboot.service" \
  "$MOUNT_POINT/etc/systemd/system/fabricnavigator-firstboot.service"
install -m 0644 "$SCRIPT_DIR/guest/fabricnavigator-updater.service" \
  "$MOUNT_POINT/etc/systemd/system/fabricnavigator-updater.service"
ln -sfn ../fabricnavigator-firstboot.service \
  "$MOUNT_POINT/etc/systemd/system/multi-user.target.wants/fabricnavigator-firstboot.service"
chmod 0700 "$MOUNT_POINT/opt/fabricnavigator/secrets"
chmod 0733 "$MOUNT_POINT/opt/fabricnavigator/update-state"
truncate -s 0 "$MOUNT_POINT/etc/machine-id"
rm -f "$MOUNT_POINT/var/lib/dbus/machine-id"
if [[ -d "$MOUNT_POINT/var/lib/cloud/instances" ]]; then
  find "$MOUNT_POINT/var/lib/cloud/instances" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
fi
sync
umount "$MOUNT_POINT"
IMAGE_MOUNTED=0
qemu-nbd --disconnect "$NBD_DEVICE"
NBD_CONNECTED=0

qm create "$VM_ID" --name "$VM_NAME" --ostype l26 --machine q35 \
  --cpu host --cores "$CORES" --memory "$MEMORY" --balloon 0 \
  --scsihw virtio-scsi-single --net0 "virtio,bridge=$BRIDGE" \
  --agent "enabled=1,fstrim_cloned_disks=1" --serial0 socket --vga serial0
CREATED_VM=1
qm importdisk "$VM_ID" "$IMAGE" "$STORAGE"
unused=$(qm config "$VM_ID" | awk '/^unused[0-9]+:/{print $2; exit}')
[[ -n "$unused" ]] || { echo "Imported disk was not found in VM configuration." >&2; exit 1; }
qm set "$VM_ID" --scsi0 "$unused,discard=on,iothread=1,ssd=1"
qm resize "$VM_ID" scsi0 "$DISK_SIZE"
qm set "$VM_ID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0 --ipconfig0 ip=dhcp \
  --ciuser "$SSH_USER"
if [[ -n "$SSH_PASSWORD" ]]; then
  qm set "$VM_ID" --cipassword "$SSH_PASSWORD"
  SSH_PASSWORD=""
fi
qm template "$VM_ID"
CREATED_VM=0

cat <<EOF

Template $VM_ID ($VM_NAME) was created successfully.
Clone it as a full clone, configure its Cloud-Init password (unless it was
provided to this builder) and start it. SSH password authentication is enabled
for the Cloud-Init user $SSH_USER; root password login remains disabled.
FabricNavigator becomes available at https://VM-IP:8443 after first-boot provisioning.
For a private fork or authenticated GitHub API access, optionally run:
  sudo fabricnavigator-token /path/to/github-update-token.txt
EOF

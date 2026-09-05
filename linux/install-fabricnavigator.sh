#!/usr/bin/env bash
set -Eeuo pipefail

FABRICNAVIGATOR_VERSION="__VERSION__"
REPOSITORY="__REPOSITORY__"
INSTALL_ROOT="/opt/fabricnavigator"
TOKEN_FILE=""
ASSUME_YES=0
CONFIGURE_UFW=0
DOWNLOAD_WORK=""

usage() {
  cat <<EOF
Install FabricNavigator $FABRICNAVIGATOR_VERSION on an existing Ubuntu server.

Usage:
  sudo ./install-fabricnavigator.sh [options]

Options:
  --repository OWNER/REPO  GitHub repository used for updates
                           (default: $REPOSITORY)
  --token-file PATH        Optional token for private forks or higher API limits
  --configure-ufw          Allow TCP port 8443 if UFW is active
  --yes                    Do not ask for confirmation
  --help                   Show this help

If the package does not contain a FabricNavigator container image, the matching
verified installer asset is downloaded from GitHub. Ubuntu and Docker packages
are always downloaded from their configured repositories during setup.
EOF
}

while (($#)); do
  case "$1" in
    --repository) REPOSITORY=$2; shift 2 ;;
    --token-file) TOKEN_FILE=$2; shift 2 ;;
    --configure-ufw) CONFIGURE_UFW=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "Run this installer as root (sudo)." >&2
  exit 1
}
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  echo "Invalid GitHub repository. Use OWNER/REPOSITORY." >&2
  exit 1
}
if [[ -n "$TOKEN_FILE" ]]; then
  [[ -f "$TOKEN_FILE" ]] || { echo "Token file not found: $TOKEN_FILE" >&2; exit 1; }
  TOKEN_FILE=$(readlink -f -- "$TOKEN_FILE")
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BOOTSTRAP_DIR="$SCRIPT_DIR"

[[ -r /etc/os-release ]] || { echo "/etc/os-release was not found." >&2; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || {
  echo "This installer supports Ubuntu only. Detected: ${PRETTY_NAME:-unknown}." >&2
  exit 1
}
ubuntu_major=${VERSION_ID%%.*}
[[ "$ubuntu_major" =~ ^[0-9]+$ && "$ubuntu_major" -ge 22 ]] || {
  echo "Ubuntu 22.04 or newer is required. Detected: ${VERSION_ID:-unknown}." >&2
  exit 1
}
[[ "$(dpkg --print-architecture)" == "amd64" ]] || {
  echo "This FabricNavigator image currently supports Ubuntu amd64 only." >&2
  exit 1
}
if [[ -e "$INSTALL_ROOT/compose.yaml" && -e /var/lib/fabricnavigator-firstboot.complete ]]; then
  echo "FabricNavigator is already installed in $INSTALL_ROOT." >&2
  echo "Use Administration > Updates for an upgrade; the installer changed nothing." >&2
  exit 1
fi
if [[ -e "$INSTALL_ROOT/compose.yaml" ]]; then
  echo "An incomplete FabricNavigator installation was detected; setup will resume."
fi

cat <<EOF
FabricNavigator Linux installation
  Version:      $FABRICNAVIGATOR_VERSION
  Ubuntu:       ${PRETTY_NAME:-$VERSION_ID}
  Architecture: amd64
  Directory:    $INSTALL_ROOT
  HTTPS port:   8443/tcp
  Repository:   $REPOSITORY

The installer will download host dependencies and Docker packages. If the
container image is not included locally, it will also download the matching
verified FabricNavigator release asset from GitHub. It then imports the image
and enables the FabricNavigator update service.
EOF
if (( ! ASSUME_YES )); then
  read -r -p "Continue with the installation? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || exit 0
fi

on_error() {
  local exit_code=$?
  echo "FabricNavigator installation failed near line ${BASH_LINENO[0]}." >&2
  exit "$exit_code"
}
cleanup() {
  if [[ -n "$DOWNLOAD_WORK" && -d "$DOWNLOAD_WORK" ]]; then
    rm -rf -- "$DOWNLOAD_WORK"
  fi
}
trap on_error ERR
trap cleanup EXIT

export DEBIAN_FRONTEND=noninteractive
echo "[1/7] Installing Ubuntu host dependencies..."
apt-get update
apt-get install -y ca-certificates curl python3 unzip gnupg

required_files=(
  compose.yaml
  .env.example
  fabricnavigator-updater.py
  fabricnavigator-updater.service
  fabricnavigator-token
)
payload_complete=1
for relative in "${required_files[@]}"; do
  [[ -f "$SCRIPT_DIR/$relative" ]] || payload_complete=0
done
shopt -s nullglob
images=("$SCRIPT_DIR"/FabricNavigator-Image-*.tar.gz)
(( ${#images[@]} == 1 )) || payload_complete=0

if (( ! payload_complete )); then
  if [[ "$FABRICNAVIGATOR_VERSION" == "latest" ]]; then
    echo "Resolving the latest stable FabricNavigator release that contains an installer..."
    release_url="https://api.github.com/repos/$REPOSITORY/releases?per_page=100"
  else
    echo "Downloading the verified FabricNavigator $FABRICNAVIGATOR_VERSION installer from GitHub..."
    release_url="https://api.github.com/repos/$REPOSITORY/releases/tags/v$FABRICNAVIGATOR_VERSION"
  fi
  DOWNLOAD_WORK=$(mktemp -d /var/tmp/fabricnavigator-linux-installer.XXXXXX)
  release_json="$DOWNLOAD_WORK/release.json"
  curl_config="$DOWNLOAD_WORK/github-curl.conf"
  printf 'header = "X-GitHub-Api-Version: 2022-11-28"\nheader = "User-Agent: FabricNavigator-Linux-Installer"\n' > "$curl_config"
  if [[ -n "$TOKEN_FILE" ]]; then
    token=$(tr -d '\r\n' < "$TOKEN_FILE")
    [[ "$token" =~ ^[A-Za-z0-9_]{20,512}$ ]] || {
      echo "Invalid GitHub token format." >&2
      exit 1
    }
    printf 'header = "Authorization: Bearer %s"\n' "$token" >> "$curl_config"
    unset token
  fi
  chmod 0600 "$curl_config"

  if ! curl --ipv4 --http1.1 --connect-timeout 15 --max-time 60 \
      --retry 2 --retry-delay 2 --retry-all-errors \
      --fail-with-body --silent --show-error --location \
      --config "$curl_config" -H 'Accept: application/vnd.github+json' \
      "$release_url" \
      -o "$release_json"; then
    echo "The GitHub release could not be read. For a private fork, use --token-file PATH." >&2
    [[ -s "$release_json" ]] && head -c 2048 "$release_json" >&2
    exit 1
  fi

  asset_info=$(python3 - "$release_json" <<'PY'
import json, pathlib, sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
releases = payload if isinstance(payload, list) else [payload]
for release in releases:
    if release.get("draft") or release.get("prerelease"):
        continue
    version = str(release.get("tag_name", "")).removeprefix("v")
    name = "FabricNavigator-Installer-" + version + ".zip"
    asset = next((item for item in release.get("assets", []) if item.get("name") == name), None)
    if asset:
        print(version + "\t" + str(asset.get("id", "")) + "\t" + str(asset.get("digest", "")) + "\t" + str(asset.get("size", "")))
        break
PY
  )
  IFS=$'\t' read -r release_version asset_id asset_digest asset_size <<< "$asset_info"
  [[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$asset_id" =~ ^[0-9]+$ && "$asset_digest" =~ ^sha256:[0-9a-fA-F]{64}$ && "$asset_size" =~ ^[0-9]+$ ]] || {
    echo "The matching installer asset or its SHA-256 digest is missing from the GitHub release." >&2
    exit 1
  }
  FABRICNAVIGATOR_VERSION="$release_version"
  installer_zip="$DOWNLOAD_WORK/FabricNavigator-Installer-$FABRICNAVIGATOR_VERSION.zip"
  echo "Latest stable FabricNavigator version: $FABRICNAVIGATOR_VERSION"
  if ! curl --ipv4 --http1.1 --connect-timeout 15 --max-time 1800 \
      --retry 2 --retry-delay 2 --retry-all-errors \
      --fail-with-body --silent --show-error --location \
      --config "$curl_config" -H 'Accept: application/octet-stream' \
      "https://api.github.com/repos/$REPOSITORY/releases/assets/$asset_id" \
      -o "$installer_zip"; then
    echo "The FabricNavigator installer asset could not be downloaded." >&2
    exit 1
  fi
  downloaded_size=$(stat -c '%s' "$installer_zip")
  if [[ "$downloaded_size" != "$asset_size" ]]; then
    echo "The GitHub asset download is incomplete: expected $asset_size bytes, received $downloaded_size bytes." >&2
    exit 1
  fi
  python3 - "$installer_zip" <<'PY'
import pathlib, sys, zipfile
archive = pathlib.Path(sys.argv[1])
if not zipfile.is_zipfile(archive):
    raise SystemExit("GitHub returned a response that is not a ZIP installer asset.")
PY
  printf '%s  %s\n' "${asset_digest#sha256:}" "$installer_zip" | sha256sum --check --status || {
    echo "The downloaded FabricNavigator installer failed SHA-256 verification." >&2
    exit 1
  }

  payload_dir="$DOWNLOAD_WORK/payload"
  mkdir -p "$payload_dir"
  python3 - "$installer_zip" "$payload_dir" <<'PY'
import pathlib, shutil, sys, zipfile
archive = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2]).resolve()
with zipfile.ZipFile(archive) as bundle:
    for member in bundle.infolist():
        name = member.filename.replace("\\", "/")
        target = (destination / name).resolve()
        if target != destination and destination not in target.parents:
            raise RuntimeError("Unsafe ZIP path: " + member.filename)
        if member.is_dir() or name.endswith("/"):
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with bundle.open(member) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
PY
  if [[ ! -f "$payload_dir/fabricnavigator-token" && -f "$BOOTSTRAP_DIR/fabricnavigator-token" ]]; then
    cp -- "$BOOTSTRAP_DIR/fabricnavigator-token" "$payload_dir/fabricnavigator-token"
  fi
  SCRIPT_DIR="$payload_dir"
fi

for relative in "${required_files[@]}"; do
  [[ -f "$SCRIPT_DIR/$relative" ]] || {
    echo "Installer file is missing: $relative" >&2
    exit 1
  }
done
images=("$SCRIPT_DIR"/FabricNavigator-Image-*.tar.gz)
(( ${#images[@]} == 1 )) || {
  echo "Expected exactly one FabricNavigator image archive, found ${#images[@]}." >&2
  exit 1
}
[[ "${images[0]}" == *"FabricNavigator-Image-$FABRICNAVIGATOR_VERSION.tar.gz" ]] || {
  echo "The container image does not match installer version $FABRICNAVIGATOR_VERSION." >&2
  exit 1
}

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "[2/7] Installing Docker Engine and Docker Compose..."
  install -d -m 0755 /etc/apt/keyrings
  curl --fail --silent --show-error --location \
    https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$VERSION_CODENAME" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  echo "[2/7] Docker Engine and Docker Compose are already available."
fi
systemctl enable --now docker.service
docker compose version >/dev/null

echo "[3/7] Installing FabricNavigator runtime files..."
install -d -m 0755 "$INSTALL_ROOT"
install -d -m 0700 "$INSTALL_ROOT/secrets"
install -d -m 0733 "$INSTALL_ROOT/update-state"
install -d -m 0755 "$INSTALL_ROOT/plugins/extreme-device-images"
install -m 0644 "$SCRIPT_DIR/compose.yaml" "$INSTALL_ROOT/compose.yaml"
install -m 0600 "$SCRIPT_DIR/.env.example" "$INSTALL_ROOT/.env.example"
install -m 0755 "$SCRIPT_DIR/fabricnavigator-updater.py" "$INSTALL_ROOT/fabricnavigator-updater.py"
install -m 0644 "$SCRIPT_DIR/fabricnavigator-updater.service" "$INSTALL_ROOT/fabricnavigator-updater.service"
install -m 0755 "$SCRIPT_DIR/fabricnavigator-token" /usr/local/sbin/fabricnavigator-token
for optional in RELEASE_NOTES.md THIRD_PARTY_NOTICES.md compose.proxmox.yaml; do
  [[ -f "$SCRIPT_DIR/$optional" ]] && install -m 0644 "$SCRIPT_DIR/$optional" "$INSTALL_ROOT/$optional"
done
if [[ -d "$SCRIPT_DIR/licenses" ]]; then
  cp -a -- "$SCRIPT_DIR/licenses" "$INSTALL_ROOT/"
fi
install -m 0644 "${images[0]}" "$INSTALL_ROOT/${images[0]##*/}"
sed -i "s|^FABRICNAVIGATOR_GITHUB_REPOSITORY=.*|FABRICNAVIGATOR_GITHUB_REPOSITORY=$REPOSITORY|" \
  "$INSTALL_ROOT/.env.example"
if [[ ! -f "$INSTALL_ROOT/.env" ]]; then
  install -m 0600 "$INSTALL_ROOT/.env.example" "$INSTALL_ROOT/.env"
fi

echo "[4/7] Importing the FabricNavigator container image..."
docker load --input "$INSTALL_ROOT/${images[0]##*/}"

echo "[5/7] Starting FabricNavigator..."
docker compose --project-directory "$INSTALL_ROOT" \
  -f "$INSTALL_ROOT/compose.yaml" \
  up -d --remove-orphans

echo "[6/7] Waiting for the application health check..."
healthy=0
for attempt in {1..36}; do
  state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' fabricnavigator 2>/dev/null || true)
  if [[ "$state" == "healthy" ]]; then
    healthy=1
    break
  fi
  if [[ "$state" == "unhealthy" || "$state" == "exited" || "$state" == "dead" ]]; then
    break
  fi
  sleep 5
done
if (( ! healthy )); then
  docker compose --project-directory "$INSTALL_ROOT" -f "$INSTALL_ROOT/compose.yaml" ps >&2 || true
  docker compose --project-directory "$INSTALL_ROOT" -f "$INSTALL_ROOT/compose.yaml" logs --tail 100 fabricnavigator >&2 || true
  echo "FabricNavigator did not become healthy. Review the log output above." >&2
  exit 1
fi

echo "[7/7] Enabling host integration and the update service..."
touch /var/lib/fabricnavigator-firstboot.complete
install -m 0644 "$INSTALL_ROOT/fabricnavigator-updater.service" \
  /etc/systemd/system/fabricnavigator-updater.service
systemctl daemon-reload
systemctl enable --now fabricnavigator-updater.service

if [[ -n "$TOKEN_FILE" ]]; then
  /usr/local/sbin/fabricnavigator-token "$TOKEN_FILE"
fi
if (( CONFIGURE_UFW )) && command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -q '^Status: active'; then
    ufw allow 8443/tcp
  fi
fi

server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
cat <<EOF

FabricNavigator $FABRICNAVIGATOR_VERSION was installed successfully.
Open: https://${server_ip:-SERVER-IP}:8443/

The first-run wizard creates the administrator and discovery settings.
To add an optional token for a private fork or authenticated API access later:
  sudo fabricnavigator-token /path/to/github-update-token.txt
EOF

#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
install -d -m 0755 /etc/apt/keyrings
apt-get update
apt-get install -y ca-certificates curl open-vm-tools python3 unzip

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # /etc/os-release is provided by every supported Ubuntu release.
  # shellcheck disable=SC1091
  . /etc/os-release
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$VERSION_CODENAME" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

install -d -m 0700 /opt/fabricnavigator/secrets
install -d -m 0733 /opt/fabricnavigator/update-state
install -d -m 0755 /opt/fabricnavigator/plugins/extreme-device-images
if [[ ! -f /opt/fabricnavigator/.env ]]; then
  install -m 0600 /opt/fabricnavigator/.env.example /opt/fabricnavigator/.env
fi

if [[ -s /run/systemd/resolve/resolv.conf ]]; then
  ln -sfn /run/systemd/resolve/resolv.conf /etc/resolv.conf
fi

shopt -s nullglob
images=(/opt/fabricnavigator/FabricNavigator-Image-*.tar.gz)
if (( ${#images[@]} != 1 )); then
  echo "Expected exactly one FabricNavigator image archive, found ${#images[@]}." >&2
  exit 1
fi
docker load --input "${images[0]}"
docker compose --project-directory /opt/fabricnavigator \
  -f /opt/fabricnavigator/compose.yaml up -d --remove-orphans

touch /var/lib/fabricnavigator-firstboot.complete
systemctl enable --now open-vm-tools.service
systemctl enable fabricnavigator-updater.service
systemctl start --no-block fabricnavigator-updater.service

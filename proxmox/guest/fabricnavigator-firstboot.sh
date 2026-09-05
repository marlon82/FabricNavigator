#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
install -d -m 0755 /etc/apt/keyrings
apt-get update
apt-get install -y ca-certificates curl python3 unzip qemu-guest-agent

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
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

# Give both the Ubuntu host and the container the real DHCP-provided upstream
# resolvers instead of systemd-resolved's host-only 127.0.0.53 stub.
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
  -f /opt/fabricnavigator/compose.yaml \
  -f /opt/fabricnavigator/compose.proxmox.yaml \
  up -d --remove-orphans

touch /var/lib/fabricnavigator-firstboot.complete
systemctl enable --now qemu-guest-agent.service
systemctl enable fabricnavigator-updater.service
# The updater is ordered after this oneshot unit. Queue it without waiting for
# this unit to finish, otherwise systemd would correctly wait on itself.
systemctl start --no-block fabricnavigator-updater.service

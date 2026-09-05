#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "Run this migration as root (sudo)." >&2
  exit 1
}

root=/opt/fabricnavigator
updater="$root/fabricnavigator-updater.py"
service="$root/fabricnavigator-updater.service"

[[ -f "$updater" && -f "$service" ]] || {
  echo "FabricNavigator 26.08.10.98 or newer must be installed first." >&2
  exit 1
}

install -d -m 0733 "$root/update-state"
install -d -m 0755 "$root/plugins/extreme-device-images"
chmod 0755 "$updater"
install -m 0644 "$service" /etc/systemd/system/fabricnavigator-updater.service
systemctl daemon-reload
systemctl enable --now fabricnavigator-updater.service
systemctl restart fabricnavigator-updater.service
systemctl --no-pager --full status fabricnavigator-updater.service

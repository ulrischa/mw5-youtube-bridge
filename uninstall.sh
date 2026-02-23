#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo ./uninstall.sh"
  exit 1
fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

purge_user="no"
if [[ "${1:-}" == "--purge-user" ]]; then
  purge_user="yes"
fi

"${BASE_DIR}/stop.sh" || true
rm -f /etc/cron.d/mw5_youtube_bridge

if [[ "${purge_user}" == "yes" ]]; then
  userdel mw5stream 2>/dev/null || true
fi

echo "Cron entry removed: /etc/cron.d/mw5_youtube_bridge"
echo "To remove all files, delete the directory explicitly, e.g.:"
echo "  sudo rm -rf /opt/mw5-youtube-bridge"
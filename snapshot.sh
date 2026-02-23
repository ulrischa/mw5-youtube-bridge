#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${BASE_DIR}/config.env"
STATE_DIR="${BASE_DIR}/state"
LAST_JPG="${STATE_DIR}/last.jpg"
TMP_JPG="${STATE_DIR}/last.tmp.jpg"

mkdir -p "${STATE_DIR}"

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

RTSP_URL="rtsp://${CAM_IP}:554/stream=1"

try_once() {
  # Capture one frame quickly and atomically replace last.jpg.
  "${TIMEOUT_BIN}" "${SNAPSHOT_TIMEOUT_SEC}" "${FFMPEG_BIN}" \
    -nostdin \
    -rw_timeout "${RW_TIMEOUT_US}" \
    -stimeout "${STIMEOUT_US}" \
    -rtsp_transport tcp \
    -i "${RTSP_URL}" \
    -frames:v 1 \
    -q:v 2 \
    -y "${TMP_JPG}" >/dev/null 2>&1

  if [[ -s "${TMP_JPG}" ]]; then
    mv -f "${TMP_JPG}" "${LAST_JPG}"
    return 0
  fi
  rm -f "${TMP_JPG}"
  return 1
}

retries="${SNAPSHOT_RETRIES}"
delay="${SNAPSHOT_DELAY_SEC}"

for _ in $(seq 1 "${retries}"); do
  if try_once; then
    exit 0
  fi
  sleep "${delay}"
done

exit 1
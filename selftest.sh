#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo ./selftest.sh"
  exit 1
fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${BASE_DIR}/config.env"
SCHEDULE_FILE="${BASE_DIR}/schedule.conf"

do_probe="0"
do_snapshot="0"
for a in "$@"; do
  case "$a" in
    --probe) do_probe="1" ;;
    --snapshot) do_snapshot="1" ;;
  esac
done

echo "[1/6] Syntax checks..."
for f in "${BASE_DIR}"/*.sh; do
  bash -n "$f"
done

echo "[2/6] Required files..."
for f in "${CONFIG_FILE}" "${SCHEDULE_FILE}" "${BASE_DIR}/run_ffmpeg_rtsp.sh" "${BASE_DIR}/run_ffmpeg_offline.sh"; do
  [[ -r "$f" ]] || { echo "Missing or unreadable: $f"; exit 1; }
done

# shellcheck source=/dev/null
source "${CONFIG_FILE}"
# shellcheck source=/dev/null
source "${SCHEDULE_FILE}"

echo "[3/6] Binary availability..."
command -v "${FFMPEG_BIN}" >/dev/null
command -v "${FFPROBE_BIN}" >/dev/null
command -v "${TIMEOUT_BIN}" >/dev/null
command -v flock >/dev/null
command -v runuser >/dev/null

echo "[4/6] Basic config validation..."
[[ "${YT_URL}" == rtmp*://* ]] || { echo "Invalid YT_URL"; exit 1; }
[[ "${FPS}" =~ ^[0-9]+$ ]] || { echo "Invalid FPS"; exit 1; }
[[ "${GOP}" =~ ^[0-9]+$ ]] || { echo "Invalid GOP"; exit 1; }
if (( GOP > FPS * 4 )); then
  echo "GOP too large (keyframes > 4 seconds)"
  exit 1
fi
[[ -r "${FONT_FILE}" ]] || { echo "Font file not found: ${FONT_FILE}"; exit 1; }

echo "[5/6] Permissions sanity..."
# These should exist after install; create if missing to avoid confusion.
mkdir -p "${BASE_DIR}/run" "${BASE_DIR}/logs" "${BASE_DIR}/state"
chown -R mw5stream:mw5stream "${BASE_DIR}/run" "${BASE_DIR}/logs" "${BASE_DIR}/state" 2>/dev/null || true

# Can mw5stream read config files?
runuser -u mw5stream -- bash -c "test -r '${CONFIG_FILE}' && test -r '${SCHEDULE_FILE}'"

# Can mw5stream write into runtime dirs?
runuser -u mw5stream -- bash -c "touch '${BASE_DIR}/state/.perm_test' && rm -f '${BASE_DIR}/state/.perm_test'"

echo "[6/6] Optional runtime checks..."
if [[ "${do_probe}" == "1" ]]; then
  echo "RTSP probe..."
  runuser -u mw5stream -- bash -c "${TIMEOUT_BIN} ${PROBE_TIMEOUT_SEC} ${FFPROBE_BIN} -v error -rtsp_transport tcp -stimeout ${PROBE_STIMEOUT_US} 'rtsp://${CAM_IP}:554/stream=1' >/dev/null"
  echo "Probe OK."
fi

if [[ "${do_snapshot}" == "1" ]]; then
  echo "Snapshot capture..."
  runuser -u mw5stream -- "${BASE_DIR}/snapshot.sh"
  ls -l "${BASE_DIR}/state/last.jpg"
  echo "Snapshot OK."
fi

echo
echo "SELFTEST PASSED"
#!/usr/bin/env bash
set -euo pipefail

# If called as root, drop privileges to mw5stream.
if [[ "${EUID}" -eq 0 && -z "${MW5_AS_USER:-}" ]]; then
  if command -v runuser >/dev/null 2>&1; then
    exec env MW5_AS_USER=1 runuser -u mw5stream -- "$0" "$@"
  fi
  echo "ERROR: runuser not found. Install util-linux." >&2
  exit 1
fi

MODE="${1:-}"
if [[ "${MODE}" != "rtsp" && "${MODE}" != "offline" ]]; then
  echo "Usage: $0 {rtsp|offline}" >&2
  exit 2
fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${BASE_DIR}/run"
LOG_DIR="${BASE_DIR}/logs"
PID_FILE="${RUN_DIR}/ffmpeg.pid"
MODE_FILE="${RUN_DIR}/ffmpeg.mode"
LOCK_FILE="${RUN_DIR}/start.lock"
STREAM_LOG="${LOG_DIR}/stream.log"
CONFIG_FILE="${BASE_DIR}/config.env"

mkdir -p "${RUN_DIR}" "${LOG_DIR}"

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

pid_uid_matches() {
  local pid="$1"
  [[ -r "/proc/${pid}/status" ]] || return 1
  local uid
  uid="$(awk '/^Uid:/{print $2}' "/proc/${pid}/status" 2>/dev/null || true)"
  [[ -n "${uid}" ]] && [[ "${uid}" == "$(id -u)" ]]
}

is_pid_ours() {
  local pid="$1"
  pid_uid_matches "${pid}" || return 1
  [[ -r "/proc/${pid}/cmdline" ]] || return 1
  local cmd
  cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  [[ "${cmd}" == *"ffmpeg"* && "${cmd}" == *"-f flv"* && "${cmd}" == *"rtmp"* ]] || return 1
  # Accept if it looks like one of our known inputs
  [[ "${cmd}" == *"stream=1"* || "${cmd}" == *"/state/last.jpg"* || "${cmd}" == *"color=c=black"* ]]
}

detect_mode() {
  local pid="$1"
  [[ -r "/proc/${pid}/cmdline" ]] || return 1
  local cmd
  cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  if [[ "${cmd}" == *"stream=1"* ]]; then
    echo "rtsp"
  else
    echo "offline"
  fi
}

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  exit 0
fi

# If already running in desired mode, do nothing
if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}" || true)"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null && is_pid_ours "${pid}"; then
    running_mode="$(detect_mode "${pid}" || true)"
    if [[ "${running_mode}" == "${MODE}" ]]; then
      echo "${MODE}" > "${MODE_FILE}"
      exit 0
    fi
  fi
fi

# Otherwise stop current and start desired
"${BASE_DIR}/stop.sh" || true

run_script="${BASE_DIR}/run_ffmpeg_${MODE}.sh"

# IMPORTANT: close FD 9 for the child process so the lock is not inherited (prevents deadlocks)
nohup "${run_script}" >>"${STREAM_LOG}" 2>&1 9>&- &

echo $! > "${PID_FILE}"
echo "${MODE}" > "${MODE_FILE}"
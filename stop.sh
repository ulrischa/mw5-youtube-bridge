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

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${BASE_DIR}/run"
PID_FILE="${RUN_DIR}/ffmpeg.pid"
MODE_FILE="${RUN_DIR}/ffmpeg.mode"
LOCK_FILE="${RUN_DIR}/stop.lock"

mkdir -p "${RUN_DIR}"

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
  [[ "${cmd}" == *"stream=1"* || "${cmd}" == *"/state/last.jpg"* || "${cmd}" == *"color=c=black"* ]]
}

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  exit 0
fi

if [[ ! -f "${PID_FILE}" ]]; then
  exit 0
fi

pid="$(cat "${PID_FILE}" || true)"
if [[ -z "${pid}" ]]; then
  rm -f "${PID_FILE}" "${MODE_FILE}"
  exit 0
fi

# Do not kill unrelated processes (PID reuse safety)
if ! is_pid_ours "${pid}"; then
  rm -f "${PID_FILE}" "${MODE_FILE}"
  exit 0
fi

if kill -0 "${pid}" 2>/dev/null; then
  kill -INT "${pid}" 2>/dev/null || true

  for _ in $(seq 1 20); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  if kill -0 "${pid}" 2>/dev/null; then
    kill -TERM "${pid}" 2>/dev/null || true
    sleep 2
  fi

  if kill -0 "${pid}" 2>/dev/null; then
    kill -KILL "${pid}" 2>/dev/null || true
  fi
fi

rm -f "${PID_FILE}" "${MODE_FILE}"
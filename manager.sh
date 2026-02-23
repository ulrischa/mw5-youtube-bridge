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
CONFIG_FILE="${BASE_DIR}/config.env"
SCHEDULE_FILE="${BASE_DIR}/schedule.conf"

LOG_DIR="${BASE_DIR}/logs"
RUN_DIR="${BASE_DIR}/run"
STATE_DIR="${BASE_DIR}/state"

PID_FILE="${RUN_DIR}/ffmpeg.pid"
MODE_FILE="${RUN_DIR}/ffmpeg.mode"
LOCK_FILE="${RUN_DIR}/manager.lock"
MANAGER_LOG="${LOG_DIR}/manager.log"
TEXT_FILE="${STATE_DIR}/offline_text.txt"

mkdir -p "${LOG_DIR}" "${RUN_DIR}" "${STATE_DIR}"

ts() { date +"%Y-%m-%d %H:%M:%S"; }
log_info() { printf '%s INFO %s\n' "$(ts)" "$*" >> "${MANAGER_LOG}"; }
log_warn() { printf '%s WARN %s\n' "$(ts)" "$*" >> "${MANAGER_LOG}"; }
log_err()  { printf '%s ERROR %s\n' "$(ts)" "$*" >> "${MANAGER_LOG}"; }

on_error() { log_err "Unexpected error on line ${1}"; }
trap 'on_error "$LINENO"' ERR

# Ensure only one manager runs at a time
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  exit 0
fi

for f in "${CONFIG_FILE}" "${SCHEDULE_FILE}" "${BASE_DIR}/start.sh" "${BASE_DIR}/stop.sh" "${BASE_DIR}/snapshot.sh"; do
  if [[ ! -r "${f}" ]]; then
    log_err "Required file missing or not readable: ${f}"
    "${BASE_DIR}/stop.sh" || true
    exit 0
  fi
done

# shellcheck source=/dev/null
source "${CONFIG_FILE}"
# shellcheck source=/dev/null
source "${SCHEDULE_FILE}"

valid_time() { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }
valid_enabled() { [[ "${ENABLED}" == "0" || "${ENABLED}" == "1" ]]; }

valid_days_num() {
  [[ -n "${DAYS_NUM:-}" ]] || return 1
  for d in ${DAYS_NUM}; do
    [[ "${d}" =~ ^[1-7]$ ]] || return 1
  done
  return 0
}

validate_all() {
  if ! valid_enabled; then
    log_err "Invalid ENABLED: '${ENABLED}' (must be 0 or 1)"
    return 1
  fi

  if [[ "${ENABLED}" == "0" ]]; then
    return 0
  fi

  if ! valid_days_num; then
    log_err "Invalid DAYS_NUM: provide numbers 1..7 (1=Mon..7=Sun), e.g. '1 2 3 4 5'"
    return 1
  fi

  if ! valid_time "${START_TIME}" || ! valid_time "${STOP_TIME}"; then
    log_err "Invalid time format START_TIME='${START_TIME}' STOP_TIME='${STOP_TIME}' (HH:MM)"
    return 1
  fi

  if [[ "${YT_URL}" != rtmp*://* ]]; then
    log_err "Invalid YT_URL: must start with rtmp:// or rtmps://"
    return 1
  fi

  if ! [[ "${FPS}" =~ ^[0-9]+$ && "${GOP}" =~ ^[0-9]+$ ]]; then
    log_err "FPS/GOP must be integers"
    return 1
  fi
  if (( GOP > FPS * 4 )); then
    log_err "GOP too large (keyframes would exceed 4 seconds)"
    return 1
  fi

  command -v "${FFMPEG_BIN}" >/dev/null 2>&1 || { log_err "FFMPEG_BIN not found: ${FFMPEG_BIN}"; return 1; }
  command -v "${TIMEOUT_BIN}" >/dev/null 2>&1 || { log_err "TIMEOUT_BIN not found: ${TIMEOUT_BIN}"; return 1; }

  return 0
}

time_to_minutes() {
  local t="$1"
  local h="${t%:*}"
  local m="${t#*:}"
  echo $((10#${h} * 60 + 10#${m}))
}

today_daynum() { date +%u; }                 # 1..7
yesterday_daynum() { date -d "yesterday" +%u; }

is_day_allowed_num() {
  local want="$1"
  for d in ${DAYS_NUM}; do
    [[ "${d}" == "${want}" ]] && return 0
  done
  return 1
}

should_stream_now() {
  if [[ "${ENABLED}" != "1" ]]; then
    return 1
  fi

  local now start stop
  now="$(time_to_minutes "$(date +%H:%M)")"
  start="$(time_to_minutes "${START_TIME}")"
  stop="$(time_to_minutes "${STOP_TIME}")"

  # 24h window
  if (( start == stop )); then
    is_day_allowed_num "$(today_daynum)"
    return
  fi

  if (( start < stop )); then
    is_day_allowed_num "$(today_daynum)" || return 1
    (( now >= start && now < stop ))
    return
  fi

  # Cross-midnight:
  if (( now >= start )); then
    is_day_allowed_num "$(today_daynum)" || return 1
    return 0
  fi
  if (( now < stop )); then
    is_day_allowed_num "$(yesterday_daynum)" || return 1
    return 0
  fi
  return 1
}

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

detect_running_mode() {
  [[ -f "${PID_FILE}" ]] || { echo ""; return 0; }
  local pid
  pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  [[ -n "${pid}" ]] || { echo ""; return 0; }

  if ! (kill -0 "${pid}" 2>/dev/null && is_pid_ours "${pid}"); then
    echo ""
    return 0
  fi

  local cmd
  cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  if [[ "${cmd}" == *"stream=1"* ]]; then
    echo "rtsp"
  else
    echo "offline"
  fi
}

# Write a single textfile used by offline drawtext (1 or 2 lines).
sync_offline_textfile() {
  local line1="${OFFLINE_TEXT:-}"
  [[ -n "${line1}" ]] || line1="Camera offline - last frame"

  if [[ "${OFFLINE_SHOW_TIME:-0}" == "1" ]]; then
    local line2
    line2="$(date +"%Y-%m-%d %H:%M:%S")"
    printf '%s\n%s\n' "${line1}" "${line2}" > "${TEXT_FILE}"
    return 0
  fi

  if [[ ! -f "${TEXT_FILE}" ]]; then
    printf '%s\n' "${line1}" > "${TEXT_FILE}"
    return 0
  fi

  local current
  current="$(head -n 1 "${TEXT_FILE}" 2>/dev/null || true)"
  if [[ "${current}" != "${line1}" ]]; then
    printf '%s\n' "${line1}" > "${TEXT_FILE}"
  fi
}

# IMPORTANT: Use the same method that worked for you: FFmpeg reads 1 frame via TCP.
camera_online() {
  local rtsp_url="rtsp://${CAM_IP}:554/stream=1"
  local timeout_s="${PROBE_TIMEOUT_SEC:-5}"
  local retries="${PROBE_RETRIES:-3}"
  local delay_s="${PROBE_DELAY_SEC:-2}"
  local st_us="${PROBE_STIMEOUT_US:-5000000}"

  for _ in $(seq 1 "${retries}"); do
    if "${TIMEOUT_BIN}" "${timeout_s}" "${FFMPEG_BIN}" \
      -nostdin \
      -rtsp_transport tcp \
      -stimeout "${st_us}" \
      -i "${rtsp_url}" \
      -analyzeduration 0 -probesize 32 \
      -frames:v 1 \
      -f null - >/dev/null 2>&1; then
      return 0
    fi
    sleep "${delay_s}"
  done
  return 1
}

refresh_snapshot_if_needed() {
  local last="${STATE_DIR}/last.jpg"
  local interval="${SNAPSHOT_INTERVAL_SEC:-300}"

  if [[ ! -s "${last}" ]]; then
    "${BASE_DIR}/snapshot.sh" && log_info "Snapshot captured (initial)" || log_warn "Snapshot capture failed"
    return
  fi

  local now mtime age
  now="$(date +%s)"
  mtime="$(stat -c %Y "${last}" 2>/dev/null || echo 0)"
  age=$(( now - mtime ))

  if (( age >= interval )); then
    "${BASE_DIR}/snapshot.sh" && log_info "Snapshot refreshed" || log_warn "Snapshot refresh failed"
  fi
}

switch_to() {
  local mode="$1"
  local running_mode
  running_mode="$(detect_running_mode)"

  if [[ -n "${running_mode}" && "${running_mode}" == "${mode}" ]]; then
    echo "${mode}" > "${MODE_FILE}" 2>/dev/null || true
    return 0
  fi

  log_info "Switching mode -> ${mode}"
  "${BASE_DIR}/start.sh" "${mode}" || log_err "Failed to start mode=${mode}"
}

main() {
  if ! validate_all; then
    log_warn "Validation failed; stopping for safety"
    "${BASE_DIR}/stop.sh" || true
    exit 0
  fi

  sync_offline_textfile

  if ! should_stream_now; then
    log_info "Outside schedule; stopping"
    "${BASE_DIR}/stop.sh" || true
    exit 0
  fi

  local running_mode
  running_mode="$(detect_running_mode)"

  if camera_online; then
    if [[ "${running_mode}" != "rtsp" ]]; then
      log_info "RTSP probe OK; switching to rtsp"
    fi
    refresh_snapshot_if_needed
    switch_to "rtsp"
  else
    if [[ "${running_mode}" != "offline" ]]; then
      log_info "RTSP probe failed; switching to offline"
    fi
    switch_to "offline"
  fi
}

main
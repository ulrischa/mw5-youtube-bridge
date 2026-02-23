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

# Required files readable?
for f in "${CONFIG_FILE}" "${SCHEDULE_FILE}" "${BASE_DIR}/start.sh" "${BASE_DIR}/stop.sh" "${BASE_DIR}/snapshot.sh"; do
  if [[ ! -r "${f}" ]]; then
    log_err "Required file missing or not readable: ${f}"
    "${BASE_DIR}/stop.sh" || true
    exit 0
  fi
done

# Load config + schedule
# shellcheck source=/dev/null
source "${CONFIG_FILE}"
# shellcheck source=/dev/null
source "${SCHEDULE_FILE}"

# -------- Validation (safe default: do not stream) --------
valid_time() { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }
valid_enabled() { [[ "${ENABLED}" == "0" || "${ENABLED}" == "1" ]]; }

valid_days() {
  [[ -n "${DAYS}" ]] || return 1
  local allowed="Mon Tue Wed Thu Fri Sat Sun"
  for d in ${DAYS}; do
    case " ${allowed} " in
      *" ${d} "*) : ;;
      *) return 1 ;;
    esac
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
  if ! valid_days; then
    log_err "Invalid DAYS: '${DAYS}' (use Mon Tue Wed Thu Fri Sat Sun)"
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
  if [[ ! -x "$(command -v "${FFMPEG_BIN}")" ]]; then
    log_err "FFMPEG_BIN not found: ${FFMPEG_BIN}"
    return 1
  fi
  if [[ ! -x "$(command -v "${FFPROBE_BIN}")" ]]; then
    log_err "FFPROBE_BIN not found: ${FFPROBE_BIN}"
    return 1
  fi
  if [[ ! -x "$(command -v "${TIMEOUT_BIN}")" ]]; then
    log_err "TIMEOUT_BIN not found: ${TIMEOUT_BIN}"
    return 1
  fi
  return 0
}

# ---------- Helpers ----------
time_to_minutes() {
  local t="$1"
  local h="${t%:*}"
  local m="${t#*:}"
  echo $((10#${h} * 60 + 10#${m}))
}

today_abbr() { LC_TIME=C date +%a; }
yesterday_abbr() { LC_TIME=C date -d "yesterday" +%a; }

is_day_listed() {
  local day="$1"
  for d in ${DAYS}; do
    [[ "${d}" == "${day}" ]] && return 0
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
    is_day_listed "$(today_abbr)"
    return
  fi

  if (( start < stop )); then
    is_day_listed "$(today_abbr)" || return 1
    (( now >= start && now < stop ))
    return
  fi

  # Cross-midnight:
  if (( now >= start )); then
    is_day_listed "$(today_abbr)" || return 1
    return 0
  fi
  if (( now < stop )); then
    is_day_listed "$(yesterday_abbr)" || return 1
    return 0
  fi
  return 1
}

current_mode() {
  if [[ -f "${MODE_FILE}" ]]; then
    cat "${MODE_FILE}" 2>/dev/null || true
  fi
}

camera_online() {
  local rtsp_url="rtsp://${CAM_IP}:554/stream=1"
  local timeout_s="${PROBE_TIMEOUT_SEC}"
  local retries="${PROBE_RETRIES}"
  local delay_s="${PROBE_DELAY_SEC}"

  for _ in $(seq 1 "${retries}"); do
    if "${TIMEOUT_BIN}" "${timeout_s}" "${FFPROBE_BIN}" \
      -v error \
      -rtsp_transport tcp \
      -stimeout "${PROBE_STIMEOUT_US}" \
      -select_streams v:0 \
      -show_entries stream=codec_name \
      -of default=nw=1:nk=1 \
      "${rtsp_url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${delay_s}"
  done
  return 1
}

sync_offline_text() {
  local desired="${OFFLINE_TEXT}"
  if [[ -z "${desired}" ]]; then
    desired="Camera offline - last frame"
  fi

  if [[ ! -f "${TEXT_FILE}" ]]; then
    printf '%s\n' "${desired}" > "${TEXT_FILE}"
    return 0
  fi

  local current
  current="$(head -n 1 "${TEXT_FILE}" 2>/dev/null || true)"
  if [[ "${current}" != "${desired}" ]]; then
    printf '%s\n' "${desired}" > "${TEXT_FILE}"
  fi
}

refresh_snapshot_if_needed() {
  local last="${STATE_DIR}/last.jpg"
  local interval="${SNAPSHOT_INTERVAL_SEC}"

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
  running_mode="$(current_mode)"

  if [[ "${running_mode}" == "${mode}" ]]; then
    # start.sh is idempotent, but no need to call it constantly
    return 0
  fi

  log_info "Switching mode -> ${mode}"
  "${BASE_DIR}/start.sh" "${mode}" || log_err "Failed to start mode=${mode}"
}

# ---------- Main ----------
main() {
  if ! validate_all; then
    log_warn "Validation failed; stopping for safety"
    "${BASE_DIR}/stop.sh" || true
    exit 0
  fi

  sync_offline_text

  if ! should_stream_now; then
    if [[ -f "${PID_FILE}" ]]; then
      log_info "Outside schedule; stopping"
      "${BASE_DIR}/stop.sh" || log_err "Failed to stop"
    fi
    exit 0
  fi

  if camera_online; then
    refresh_snapshot_if_needed
    switch_to "rtsp"
  else
    switch_to "offline"
  fi
}

main
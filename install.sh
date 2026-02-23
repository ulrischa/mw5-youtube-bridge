#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo ./install.sh"
  exit 1
fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${BASE_DIR}/config.env"
SCHEDULE_FILE="${BASE_DIR}/schedule.conf"
CRON_DST="/etc/cron.d/mw5_youtube_bridge"

echo "Installing dependencies..."
apt update
apt install -y ffmpeg cron util-linux coreutils fonts-dejavu-core

systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now cron.service >/dev/null 2>&1 || true

if ! id -u mw5stream >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin mw5stream
fi

cam_ip_default="192.168.1.50"
yt_url_default="rtmps://a.rtmps.youtube.com/live2"
fps_default="30"
vbitrate_default="3000k"
abitrate_default="128k"
days_num_default="1 2 3 4 5 6 7"
start_default="08:00"
stop_default="18:00"
offline_text_default="Camera sleeping (solar) - last frame"

echo
read -r -p "Camera IP [${cam_ip_default}]: " cam_ip
cam_ip="${cam_ip:-${cam_ip_default}}"

read -r -p "YouTube ingest base URL (rtmps://... or rtmp://...) [${yt_url_default}]: " yt_url
yt_url="${yt_url:-${yt_url_default}}"
yt_url="${yt_url%/}"
if [[ "${yt_url}" != rtmp*://* ]]; then
  echo "ERROR: YouTube URL must start with rtmp:// or rtmps://"
  exit 1
fi

read -r -s -p "YouTube Stream Key (hidden input): " yt_key
echo
if [[ -z "${yt_key}" ]]; then
  echo "ERROR: Stream key cannot be empty."
  exit 1
fi

read -r -p "FPS [${fps_default}]: " fps
fps="${fps:-${fps_default}}"
if ! [[ "${fps}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: FPS must be an integer."
  exit 1
fi

gop=$(( fps * 2 ))

read -r -p "Video bitrate (e.g. 2500k, 3000k) [${vbitrate_default}]: " vbitrate
vbitrate="${vbitrate:-${vbitrate_default}}"

read -r -p "Audio bitrate (e.g. 128k) [${abitrate_default}]: " abitrate
abitrate="${abitrate:-${abitrate_default}}"

vbufsize="6000k"
if [[ "${vbitrate}" =~ ^([0-9]+)([kKmM])$ ]]; then
  num="${BASH_REMATCH[1]}"
  suf="${BASH_REMATCH[2]}"
  vbuf_num=$(( num * 2 ))
  vbufsize="${vbuf_num}${suf}"
fi

echo
read -r -p "Enabled schedule? (1=yes, 0=no) [1]: " enabled
enabled="${enabled:-1}"
if ! [[ "${enabled}" =~ ^[01]$ ]]; then
  echo "ERROR: Enabled must be 0 or 1."
  exit 1
fi

echo "Active days as numbers (1=Mon ... 7=Sun). Example: '1 2 3 4 5' for Mon-Fri."
read -r -p "DAYS_NUM [${days_num_default}]: " days_num
days_num="${days_num:-${days_num_default}}"
for d in ${days_num}; do
  if ! [[ "${d}" =~ ^[1-7]$ ]]; then
    echo "ERROR: DAYS_NUM must contain only numbers 1..7 (space-separated)."
    exit 1
  fi
done

read -r -p "Start time (HH:MM) [${start_default}]: " start_time
start_time="${start_time:-${start_default}}"
read -r -p "Stop time (HH:MM) [${stop_default}]: " stop_time
stop_time="${stop_time:-${stop_default}}"

if ! [[ "${start_time}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  echo "ERROR: Start time must be HH:MM (24h)."
  exit 1
fi
if ! [[ "${stop_time}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  echo "ERROR: Stop time must be HH:MM (24h)."
  exit 1
fi

read -r -p "Offline overlay text [${offline_text_default}]: " offline_text
offline_text="${offline_text:-${offline_text_default}}"

read -r -p "Show timestamp in offline mode? (1=yes, 0=no) [1]: " offline_show_time
offline_show_time="${offline_show_time:-1}"
if ! [[ "${offline_show_time}" =~ ^[01]$ ]]; then
  echo "ERROR: Offline show time must be 0 or 1."
  exit 1
fi

video_encoder="h264_v4l2m2m"
if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_v4l2m2m"; then
  video_encoder="libx264"
  echo
  echo "WARNING: h264_v4l2m2m encoder not found. Falling back to libx264 (higher CPU)."
fi

umask 027

echo "Writing ${CONFIG_FILE} and ${SCHEDULE_FILE} ..."
{
  printf 'FFMPEG_BIN=%q\n' "ffmpeg"
  printf 'FFPROBE_BIN=%q\n' "ffprobe"
  printf 'TIMEOUT_BIN=%q\n' "timeout"

  printf 'CAM_IP=%q\n' "${cam_ip}"

  printf 'YT_URL=%q\n' "${yt_url}"
  printf 'YT_KEY=%q\n' "${yt_key}"

  printf 'OUT_WIDTH=%q\n' "1280"
  printf 'OUT_HEIGHT=%q\n' "720"

  printf 'FPS=%q\n' "${fps}"
  printf 'GOP=%q\n' "${gop}"
  printf 'VBITRATE=%q\n' "${vbitrate}"
  printf 'VBUFSIZE=%q\n' "${vbufsize}"
  printf 'ABITRATE=%q\n' "${abitrate}"

  printf 'VIDEO_ENCODER=%q\n' "${video_encoder}"
  printf 'X264_PRESET=%q\n' "veryfast"
  printf 'X264_TUNE=%q\n' "zerolatency"

  # RTSP socket timeout (microseconds). rw_timeout is not used due to ffmpeg 4.1 compatibility.
  printf 'STIMEOUT_US=%q\n' "15000000"

  printf 'PROBE_TIMEOUT_SEC=%q\n' "5"
  printf 'PROBE_STIMEOUT_US=%q\n' "5000000"
  printf 'PROBE_RETRIES=%q\n' "3"
  printf 'PROBE_DELAY_SEC=%q\n' "2"

  printf 'SNAPSHOT_INTERVAL_SEC=%q\n' "300"
  printf 'SNAPSHOT_TIMEOUT_SEC=%q\n' "8"
  printf 'SNAPSHOT_RETRIES=%q\n' "2"
  printf 'SNAPSHOT_DELAY_SEC=%q\n' "2"

  printf 'OFFLINE_TEXT=%q\n' "${offline_text}"
  printf 'OFFLINE_SHOW_TIME=%q\n' "${offline_show_time}"
  printf 'OFFLINE_TEXT_SIZE=%q\n' "36"
  printf 'OFFLINE_TEXT_COLOR=%q\n' "white"
  printf 'OFFLINE_BOX_COLOR=%q\n' "black@0.45"
  printf 'OFFLINE_MARGIN=%q\n' "24"
  printf 'FONT_FILE=%q\n' "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
} > "${CONFIG_FILE}"

{
  printf 'ENABLED=%q\n' "${enabled}"
  printf 'DAYS_NUM=%q\n' "${days_num}"
  printf 'START_TIME=%q\n' "${start_time}"
  printf 'STOP_TIME=%q\n' "${stop_time}"
} > "${SCHEDULE_FILE}"

echo "Setting permissions..."
chown -R root:mw5stream "${BASE_DIR}"
chmod 750 "${BASE_DIR}"
chmod 750 "${BASE_DIR}"/*.sh
chmod 640 "${CONFIG_FILE}" "${SCHEDULE_FILE}"

mkdir -p "${BASE_DIR}/run" "${BASE_DIR}/logs" "${BASE_DIR}/state"
chown -R mw5stream:mw5stream "${BASE_DIR}/run" "${BASE_DIR}/logs" "${BASE_DIR}/state"
chmod 750 "${BASE_DIR}/run" "${BASE_DIR}/logs" "${BASE_DIR}/state"

echo "Generating cron file: ${CRON_DST}"
cat > "${CRON_DST}" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
* * * * * mw5stream ${BASE_DIR}/manager.sh >> ${BASE_DIR}/logs/cron.log 2>&1
EOF
chmod 644 "${CRON_DST}"

echo "Stopping any previous run..."
"${BASE_DIR}/stop.sh" || true

echo
echo "Done."
echo "Logs:"
echo "  tail -f ${BASE_DIR}/logs/manager.log"
echo "  tail -f ${BASE_DIR}/logs/stream.log"
echo "  tail -f ${BASE_DIR}/logs/cron.log"
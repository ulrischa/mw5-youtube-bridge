#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${BASE_DIR}/config.env"
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

RTSP_URL="rtsp://${CAM_IP}:554/stream=1"
OUT_URL="${YT_URL}/${YT_KEY}"

video_args=()
x264_extra=()

if [[ "${VIDEO_ENCODER}" == "libx264" ]]; then
  video_args=(-c:v libx264 -preset "${X264_PRESET}" -tune "${X264_TUNE}")
  x264_extra=(-keyint_min "${GOP}" -sc_threshold 0)
else
  video_args=(-c:v h264_v4l2m2m)
fi

exec "${FFMPEG_BIN}" \
  -nostdin \
  -rtsp_transport tcp \
  -stimeout "${STIMEOUT_US}" \
  -i "${RTSP_URL}" \
  -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=44100" \
  "${video_args[@]}" -pix_fmt yuv420p \
  -r "${FPS}" -g "${GOP}" "${x264_extra[@]}" \
  -b:v "${VBITRATE}" -maxrate "${VBITRATE}" -bufsize "${VBUFSIZE}" \
  -c:a aac -b:a "${ABITRATE}" -ar 44100 -ac 2 \
  -shortest \
  -f flv "${OUT_URL}"
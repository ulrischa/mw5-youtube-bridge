#!/usr/bin/env bash
set -euo pipefail

# RTSP -> YouTube (RTMP/RTMPS)
# Supports:
# - video copy mode (no re-encode): -c:v copy
# - re-encode mode (libx264 or h264_v4l2m2m)

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${BASE_DIR}/config.env"

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

RTSP_URL="rtsp://${CAM_IP}:554/stream=1"
OUT_URL="${YT_URL}/${YT_KEY}"

rtsp_video_mode="${RTSP_VIDEO_MODE:-}"
video_encoder="${VIDEO_ENCODER:-libx264}"

# Enable copy mode if either RTSP_VIDEO_MODE=copy or VIDEO_ENCODER=copy
if [[ "${rtsp_video_mode}" == "copy" || "${video_encoder}" == "copy" ]]; then
  # NOTE:
  # - Do NOT set -r / -g / -b:v / -pix_fmt when copying.
  # - We generate a silent AAC audio track because YouTube often expects audio.
  exec "${FFMPEG_BIN}" \
    -nostdin \
    -rtsp_transport tcp \
    -stimeout "${STIMEOUT_US}" \
    -i "${RTSP_URL}" \
    -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=44100" \
    -map 0:v:0 -map 1:a:0 \
    -c:v copy \
    -c:a aac -b:a "${ABITRATE}" -ar 44100 -ac 2 \
    -f flv "${OUT_URL}"
fi

# Re-encode fallback (keeps your previous behavior)
video_args=()
x264_extra=()

if [[ "${video_encoder}" == "libx264" ]]; then
  video_args=(-c:v libx264 -preset "${X264_PRESET}" -tune "${X264_TUNE}")
  x264_extra=(-keyint_min "${GOP}" -sc_threshold 0)
else
  # Assume Raspberry Pi HW encoder
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
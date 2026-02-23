#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${BASE_DIR}/config.env"
STATE_DIR="${BASE_DIR}/state"
LAST_JPG="${STATE_DIR}/last.jpg"
TEXT_FILE="${STATE_DIR}/offline_text.txt"

mkdir -p "${STATE_DIR}"

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

OUT_URL="${YT_URL}/${YT_KEY}"

margin="${OFFLINE_MARGIN}"
box_color="${OFFLINE_BOX_COLOR}"
text_color="${OFFLINE_TEXT_COLOR}"
text_size="${OFFLINE_TEXT_SIZE}"
font_file="${FONT_FILE}"

text_y="h-${margin}-${text_size}*3"

vf_common="scale=${OUT_WIDTH}:${OUT_HEIGHT}:force_original_aspect_ratio=decrease,\
pad=${OUT_WIDTH}:${OUT_HEIGHT}:(ow-iw)/2:(oh-ih)/2,\
format=yuv420p"

vf_text="drawtext=fontfile=${font_file}:textfile=${TEXT_FILE}:reload=1:\
x=${margin}:y=${text_y}:fontsize=${text_size}:fontcolor=${text_color}:\
line_spacing=8:box=1:boxcolor=${box_color}:boxborderw=10"

vf="${vf_common},${vf_text}"

video_args=()
x264_extra=()

if [[ "${VIDEO_ENCODER}" == "libx264" ]]; then
  video_args=(-c:v libx264 -preset "${X264_PRESET}" -tune "${X264_TUNE}")
  x264_extra=(-keyint_min "${GOP}" -sc_threshold 0)
else
  video_args=(-c:v h264_v4l2m2m)
fi

if [[ -s "${LAST_JPG}" ]]; then
  exec "${FFMPEG_BIN}" \
    -nostdin \
    -re \
    -loop 1 -framerate "${FPS}" -i "${LAST_JPG}" \
    -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=44100" \
    -vf "${vf}" \
    "${video_args[@]}" "${x264_extra[@]}" \
    -r "${FPS}" -g "${GOP}" \
    -b:v "${VBITRATE}" -maxrate "${VBITRATE}" -bufsize "${VBUFSIZE}" \
    -c:a aac -b:a "${ABITRATE}" -ar 44100 -ac 2 \
    -f flv "${OUT_URL}"
else
  exec "${FFMPEG_BIN}" \
    -nostdin \
    -re \
    -f lavfi -i "color=c=black:s=${OUT_WIDTH}x${OUT_HEIGHT}:r=${FPS}" \
    -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=44100" \
    -vf "${vf}" \
    "${video_args[@]}" "${x264_extra[@]}" \
    -r "${FPS}" -g "${GOP}" \
    -b:v "${VBITRATE}" -maxrate "${VBITRATE}" -bufsize "${VBUFSIZE}" \
    -c:a aac -b:a "${ABITRATE}" -ar 44100 -ac 2 \
    -f flv "${OUT_URL}"
fi
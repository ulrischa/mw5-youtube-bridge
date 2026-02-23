# mw5-youtube-bridge

This package streams the WIWACAM MW5 RTSP SD stream (stream=1) to YouTube Live.
Because the camera may go offline (solar/battery), it automatically switches to an
offline fallback that loops the last captured frame ("state/last.jpg") with an overlay text.
When RTSP comes back, it switches back to the live RTSP stream.

Scheduling is enforced by cron (every minute):
- Outside the schedule: stop streaming
- Inside the schedule:
  - If RTSP is reachable (probe with timeout + retries): stream RTSP and refresh last.jpg periodically
  - If RTSP is not reachable: stream offline fallback (last.jpg + overlay)

## Requirements
- Raspberry Pi 4 (recommended: wired LAN)
- Raspberry Pi OS
- Camera reachable via RTSP in local network when awake
- YouTube Live enabled on the channel
- Packages: ffmpeg, cron, util-linux (runuser + flock), coreutils (timeout), fonts-dejavu-core

## Security model (simple and safe)
- A locked system user "mw5stream" runs cron + FFmpeg.
- config.env and schedule.conf are root-owned, group-readable by mw5stream (not writable by mw5stream).
- logs/, run/, state/ are owned by mw5stream.

## Install (interactive)
1) Put this folder at /opt/mw5-youtube-bridge
OR:
sudo apt update
sudo apt install -y git
sudo git clone https://github.com/ulrischa/mw5-youtube-bridge
cd /opt/mw5-youtube-bridge
sudo ./install.sh
2) set rights (chmod +x ./*.sh)
3) Run:
   sudo /opt/mw5-youtube-bridge/install.sh

The installer writes:
- config.env
- schedule.conf
and installs one cron file:
- /etc/cron.d/mw5_youtube_bridge

## Edit configuration later
- sudo nano /opt/mw5-youtube-bridge/config.env
- sudo nano /opt/mw5-youtube-bridge/schedule.conf

Changes apply automatically within 1 minute (cron runs manager every minute).
You can also trigger immediately:
- sudo /opt/mw5-youtube-bridge/manager.sh

## Scheduling (IMPORTANT: locale-independent)
This package uses numeric weekdays to avoid locale issues:
- 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat, 7=Sun

Configure in schedule.conf:
- ENABLED="1"
- DAYS_NUM="1 2 3 4 5"          # Mon-Fri example
- START_TIME="08:00"
- STOP_TIME="18:00"

Cross-midnight example (20:00 -> 06:00):
- DAYS_NUM="1 2 3 4 5"
- START_TIME="20:00"
- STOP_TIME="06:00"
After midnight, the day check uses "yesterday" to match the intended schedule.

## Offline overlay text
Set OFFLINE_TEXT in config.env.
The manager syncs it into: state/offline_text.txt (used by FFmpeg drawtext via textfile=...:reload=1)
Optional: OFFLINE_SHOW_TIME=1 adds a timestamp line.

## Logs
- Streaming (both modes):
  tail -f /opt/mw5-youtube-bridge/logs/stream.log
- Manager decisions + validation:
  tail -f /opt/mw5-youtube-bridge/logs/manager.log
- Cron output:
  tail -f /opt/mw5-youtube-bridge/logs/cron.log

## Manual control
- sudo /opt/mw5-youtube-bridge/start.sh rtsp
- sudo /opt/mw5-youtube-bridge/start.sh offline
- sudo /opt/mw5-youtube-bridge/stop.sh

## Uninstall
- sudo /opt/mw5-youtube-bridge/uninstall.sh
Optionally remove the system user:
- sudo /opt/mw5-youtube-bridge/uninstall.sh --purge-user
Optionally remove the directory:
- sudo rm -rf /opt/mw5-youtube-bridge

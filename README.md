# mw5-youtube-bridge
(WIWACAM MW5 RTSP -> YouTube Live) — Raspberry Pi 4

Streams the WIWACAM MW5 RTSP SD stream to YouTube Live using FFmpeg.

Behavior:
- **Inside schedule:** stream the camera (RTSP) to YouTube.
- **Outside schedule:** stream an **offline view** (last frame / black background + overlay text) to YouTube.

The offline view uses `state/last.jpg` (captured periodically while inside schedule). If no image exists yet, a black background is used.

---

## Requirements

- Raspberry Pi OS (recommended)
- Raspberry Pi 4 (recommended)
- Network access to the camera (RTSP) and to YouTube ingest
- YouTube Live enabled on your channel
- Packages installed by installer: `ffmpeg`, `cron`, `util-linux`, `coreutils`, `fonts-dejavu-core`

---

## Installation

### Option A: Install from Git (recommended)

```bash
sudo apt update
sudo apt install -y git
sudo git clone <REPO_URL> /opt/mw5-youtube-bridge
cd /opt/mw5-youtube-bridge
sudo ./install.sh

chmod +x ./*.sh

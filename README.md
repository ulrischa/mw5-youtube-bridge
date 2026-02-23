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
````

### Option B: Install from ZIP

1. Copy the ZIP to the Raspberry Pi and unzip:

```bash
sudo mkdir -p /opt/mw5-youtube-bridge
sudo unzip mw5-youtube-bridge.zip -d /opt/mw5-youtube-bridge
cd /opt/mw5-youtube-bridge
sudo ./install.sh
```

---

## Configuration

After installation, edit if necessary:

* `/opt/mw5-youtube-bridge/config.env`
* `/opt/mw5-youtube-bridge/schedule.conf`

### `config.env` (key settings)

* `CAM_IP` — camera IP address
* `YT_URL` — YouTube ingest base URL (e.g. `rtmps://a.rtmps.youtube.com/live2`)
* `YT_KEY` — YouTube stream key (keep secret!)
* `OFFLINE_TEXT` — text overlay shown in offline mode
* `OFFLINE_SHOW_TIME` — `1` to show timestamp as second line, `0` to disable
* `SNAPSHOT_INTERVAL_SEC` — how often `last.jpg` is refreshed while inside schedule

### `schedule.conf`

This package uses **numeric weekdays** (locale-independent):

* `1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat, 7=Sun`

Example (daily 04:00–23:20):

```bash
ENABLED="1"
DAYS_NUM="1 2 3 4 5 6 7"
START_TIME="04:00"
STOP_TIME="23:20"
```

Cross-midnight example (Mon–Fri 20:00–06:00):

```bash
ENABLED="1"
DAYS_NUM="1 2 3 4 5"
START_TIME="20:00"
STOP_TIME="06:00"
```

---

## How it runs

The installer sets up a cron entry that runs the manager every minute:

* `/etc/cron.d/mw5_youtube_bridge`

The manager enforces the schedule:

* inside schedule: `rtsp`
* outside schedule: `offline`

---

## Logs

* Stream output:

  * `/opt/mw5-youtube-bridge/logs/stream.log`
* Manager decisions:

  * `/opt/mw5-youtube-bridge/logs/manager.log`
* Cron output:

  * `/opt/mw5-youtube-bridge/logs/cron.log`

Tail logs:

```bash
sudo tail -f /opt/mw5-youtube-bridge/logs/manager.log
sudo tail -f /opt/mw5-youtube-bridge/logs/stream.log
sudo tail -f /opt/mw5-youtube-bridge/logs/cron.log
```

---

## Manual control

```bash
sudo /opt/mw5-youtube-bridge/start.sh rtsp
sudo /opt/mw5-youtube-bridge/start.sh offline
sudo /opt/mw5-youtube-bridge/stop.sh
```

Force one manager run:

```bash
sudo /opt/mw5-youtube-bridge/manager.sh
```

---

## Uninstall

```bash
sudo /opt/mw5-youtube-bridge/uninstall.sh
```

Optional: remove the system user:

```bash
sudo /opt/mw5-youtube-bridge/uninstall.sh --purge-user
```

Optional: remove all files:

```bash
sudo rm -rf /opt/mw5-youtube-bridge
```


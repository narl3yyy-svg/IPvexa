# Ipvexa

Self-hosted, offline video management for Linux: 24/7 recording, a native desktop app with live view, and synced multi-camera playback on a zoomable timeline. No cloud and no containers.

- `server/` — **ipvexa-server** (Go). Records cameras with FFmpeg (no re-encoding), streams live and recorded video, and serves the API on port 7480.
- `client/` — **Ipvexa** desktop app (Qt 6 / QML / C++ / FFmpeg, with hardware decoding via NVDEC or VAAPI).
- `packaging/linux/` — systemd unit, desktop launcher, icon.
- `scripts/` — install and dev helpers.
- [PLAN.md](PLAN.md) — goals, architecture and roadmap.

## Install on Ubuntu / Kubuntu 26.04

```bash
sudo apt install -y ffmpeg cmake ninja-build pkg-config build-essential \
  qt6-base-dev qt6-declarative-dev qt6-multimedia-dev \
  qml6-module-qtquick-controls qml6-module-qtquick-layouts qml6-module-qtquick-window \
  qml6-module-qtmultimedia qml6-module-qtqml-workerscript qml6-module-qtquick-templates \
  qml6-module-qtquick-dialogs qml6-module-qtcore \
  libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libva-dev vainfo
```

Install Go 1.27+ from https://go.dev/dl (or to `~/.local/go`), then:

```bash
./scripts/install-linux.sh
```

This builds both programs and installs `ipvexa-server` as a systemd service, storing data in `/var/lib/ipvexa`. It also adds **Ipvexa** to the app menu. On first start the server creates the user `admin` and writes its password to `/var/lib/ipvexa/initial-admin-password`.

## Run from source (development)

```bash
cd server && go build -o bin/ipvexa-server ./cmd/ipvexa-server && ./bin/ipvexa-server -debug
# data in ~/.local/share/ipvexa, admin password in ~/.local/share/ipvexa/initial-admin-password

cd client && cmake -S . -B build -G Ninja && cmake --build build && ./build/ipvexa
```

Useful app options: `--seek <minutes>` starts in playback that many minutes ago. Set `IPVEXA_NO_HWDEC=1` to force CPU decoding.

## Using it
- **Add a camera:** click **+** in the resource tree, pick the brand, then enter the IP and login. *Find cameras* scans the network with ONVIF.
- **Layouts:** pick a grid in the top bar, drag cameras from the tree onto tiles, and save with 💾. Double-click a tile to maximize it.
- **Timeline:** scroll to zoom, drag to pan, click to jump. **Space** plays/pauses, **← / →** jumps 10 s, **L** goes live, **F11** toggles full screen.

## Remote access
Ipvexa never contacts the internet. To view it away from home, connect to your network with a VPN (WireGuard/Tailscale) and sign in to `http://<server-lan-ip>:7480`. Don't forward port 7480 on your router.

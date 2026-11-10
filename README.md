# IPvexa

Self-hosted, offline video management for Linux. It records around the clock or only on motion, and ships a native desktop app in the style of Nx Witness: free-form layouts, synced multi-camera playback on a zoomable timeline, motion search, PTZ and clip export. Browsers and phones get a web view, and alerts go to the ntfy phone app. No cloud and no containers.

- `server/` — **ipvexa-server** (Go). Records cameras with FFmpeg (no re-encoding), detects motion, streams live and recorded video, sends alerts, and serves the API and web view on port 7480.
- `client/` — **IPvexa** desktop app (Qt 6 / QML / C++ / FFmpeg, with hardware decoding via NVDEC or VAAPI).
- `packaging/` — systemd unit, desktop launcher, icon (`linux/`) and an Arch Linux PKGBUILD (`arch/`).
- `scripts/` — install, packaging and dev helpers.
- [PLAN.md](PLAN.md) — goals, architecture and roadmap.

## Install (Linux)

On Ubuntu/Kubuntu/Debian or Arch, from this folder:

```bash
./install.sh
```

The installer:
- installs the build tools it needs (it asks for your sudo password)
- builds IPvexa and installs it as packages (`.deb` on Ubuntu/Debian, `makepkg` on Arch)
- starts `ipvexa-server` as a system service under its own `ipvexa` user, with data in `/var/lib/ipvexa`
- puts **IPvexa** in the app menu

At the end it prints the first sign-in password and the address for browsers and phones.

| Command | What it does |
|---|---|
| `./install.sh` | Install or upgrade the server and the desktop app |
| `./install.sh --client` | Desktop app only, to view a server on another machine |
| `./install.sh --server` | Server only, for a headless machine |
| `./install.sh --import-dev` | Also move a development setup (`~/.local/share/ipvexa`: cameras, users, recordings) into the installed server |
| `./uninstall.sh` | Remove the programs; recordings, cameras and settings are kept for a reinstall |
| `./uninstall.sh --purge` | Remove everything, including all recordings and settings (asks you to type DELETE) |

**Starting the app:** open **IPvexa** from the app menu, or run `ipvexa`. The server starts by itself at boot.

You can also build the packages yourself: `./scripts/build-deb.sh` writes them to `dist/`, and `packaging/arch/PKGBUILD` works with `makepkg -si`.

## Run from source (development)

```bash
cd server && go build -o bin/ipvexa-server ./cmd/ipvexa-server && ./bin/ipvexa-server -debug
# data in ~/.local/share/ipvexa, admin password in ~/.local/share/ipvexa/initial-admin-password

cd client && cmake -S . -B build -G Ninja && cmake --build build && ./build/ipvexa
```

Tests: `cd server && go test ./...` and `cd client && cmake --build build --target layout_tests && ./build/layout_tests`.

App options for testing and support: `--seek <minutes>` starts in playback that many minutes ago; `--open <users|password|notifications|audit|settings|addcamera|events|tour|wall:<screen>|fullscreen:<tile>>` opens a screen on start. Set `IPVEXA_DEBUG=1` for FFmpeg messages.

## Using it

- **Add a camera:** **+ Add camera** in the tree. Pick the brand and enter the address and login. **Detect streams** asks the camera for its stream addresses over ONVIF, and **Find cameras** scans the network.
- **Layouts:** drag cameras from the tree onto the grid. Drag a tile to move or swap it, and drag its corner to make it bigger. **Drag the border between two tiles** to widen or shrink them (double-click a border to make them equal again). **Auto-arrange** fills the screen with the layout's cameras and no empty tiles, e.g. 5 cameras as 2 on top and 3 below. Grid size and tile shape are in the toolbar. Layouts are tabs and save automatically.
- **Quality:** the toolbar's **Auto / High / Low** applies to the whole layout. Each tile's **AUTO/HD/SD** button (or right-click > Quality) overrides it.
- **Live smoothing:** **Live: Fast / Smooth / Smoothest** in the toolbar trades a little delay for even motion. *Smooth* (about 0.6 s) suits most Wi-Fi cameras; *Smoothest* (about 2.5 s) hides longer Wi-Fi pauses. Live video always stays at real time: if the app falls behind for a moment (a busy PC, the screen locking), it plays through the waiting video and catches up within a second or two, so camera clocks on screen stay in step. High-quality streams are only pulled from a camera while someone watches them (unless recording), which halves the load on Wi-Fi cameras.
- **Tiles:** hover for the toolbar: smart search, info, **full screen**, settings and remove; double-click maximizes. Right-click > **Maximize frames** fills every tile with video by trimming the edges (no black bars), or **Stretch video to tiles**. The scroll wheel zooms digitally; drag to pan while zoomed. The zoom is saved with the layout, and right-click > **Open zoomed area as new tile** gives a second tile of the same camera. The full-screen button in the toolbar (or **F11**) shows only the layout's live cameras, edge to edge, with no bars or panels; double-click a camera there to fill the screen with it. **Esc** goes back. Camera names and the LIVE label appear when the mouse is over a tile, and clicking the empty space around the tiles clears the selection.
- **Tours and video walls:** **Tour** in the toolbar cycles through the open layout tabs (right-click it for the interval). Right-click a layout tab > **Show full screen on** puts that layout on another monitor; Esc closes it.
- **Timeline:** green is recorded, red is motion, and amber flags are bookmarks. Scroll to zoom, drag to pan, click to jump. Hover over recorded footage for a picture preview. Right-click to bookmark or export a clip. The ◀▶ buttons jump between events, and clicking the date opens a calendar. The badge at the bottom right shows **LIVE** (red) or **PLAYBACK** / **PAUSED** (blue), with **Go live** next to it. **Sync** plays every camera on the layout at the same moment (a thin blue strip shows when any of them recorded); with Sync off only the selected camera plays back and the others stay live. **◂◂** plays backwards, and **‹| |›** (or **,** and **.**) step one frame. **Space** plays/pauses, **← / →** jumps 10 s, **L** goes live.
- **Motion:** Camera settings > **Motion** turns detection on, sets sensitivity and paints areas to ignore. Things that keep moving in place, such as trees and flags in the wind, are learned and ignored, and motion only counts once something moves across the picture or comes closer. **Recording** can be *Always* or *Only when there's motion* (keeps 10 s before and after; adjustable). **Also record the low-quality stream** makes playback in small tiles smooth. A weekly **schedule** can switch the mode at set times, e.g. motion only during working hours.
- **Graphics card:** the app decodes video on an NVIDIA GPU (NVDEC) or Intel/AMD graphics (VAAPI) when present, and hands decoded frames to the screen without extra copies. The tile's info button shows which is used (NVDEC, VAAPI or CPU). With an NVIDIA GPU the server also decodes video for motion detection on the GPU. Set `IPVEXA_NO_HWDEC=1` to use the CPU only.
- **Server settings** (user menu, admins): the recordings **folder** (e.g. a second disk under `/mnt`; it must belong to the `ipvexa` user), how long new cameras keep footage (optionally applied to all), the motion buffer, the share of the disk to keep free, an optional storage limit for all footage, and how long motion events are kept.
- **Camera clocks:** the server is also a time server (NTP, UDP port 123), so cameras without internet access can keep the same time as the server. In each camera's Date & Time settings, turn on NTP and enter the server's address (shown in **Server settings › Camera clocks**) with port 123. If the server's firewall is on, allow it: `sudo ufw allow from 192.168.1.0/24 to any port 123 proto udp` (use your cameras' network). The server also checks every camera's clock every 30 minutes over ONVIF and sets any that are 2 s or more off (only while its own clock is synchronised). **Health** shows each camera's clock and where it gets its time.
- **Smart search:** the magnifier on a tile, then drag a box over the area. The timeline then shows only motion inside it.
- **Users:** user menu (top right) > **User management**. Roles are Administrator, Operator and Viewer, with per-user camera lists and playback, PTZ and export permissions. Everyone can **Change password**. Admins also get an **Audit log**.
- **Forgot the password?** An admin can reset it in User management, or on the server run `ipvexa-server passwd <username>` (as the service user: `sudo -u ipvexa ipvexa-server -data /var/lib/ipvexa passwd admin`).

## Phones and browsers

- **Web view:** open `http://<server>:7480` in any browser. It has a camera grid, live view, playback and the event list, and needs no app or plugin. Video plays at full quality where the browser supports the camera's codec (H.264 everywhere, H.265 on many phones); otherwise it falls back to a lighter picture stream. SD/HD switches between the substream and the main stream. Live view runs indefinitely: if the stream is interrupted (a camera reconnecting, a Wi-Fi drop) the page notices within seconds and reconnects by itself, and it renews the connection every 30 minutes without a visible gap. **⛶ Full screen** at the top shows only the cameras, filling the screen; move the mouse or tap to get the exit button, or press Esc.
- **Alerts:** user menu > **Phone notifications** shows the steps for the ntfy app and lets you set rules: motion, camera offline/online or disk almost full, for chosen cameras, days and hours, with cooldowns, optional bookmarks and webhooks (e.g. Home Assistant). Alerts include a snapshot, and tapping one opens the web view at that moment.

## Remote access

IPvexa never contacts the internet. To use it away from home, connect to your network with a VPN (WireGuard/Tailscale) and sign in to `http://<server-lan-ip>:7480`. Don't forward port 7480 on your router.

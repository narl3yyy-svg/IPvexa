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
- **Layouts:** drag cameras from the tree onto the grid. Drag a tile to move or swap it, and drag its corner to make it bigger. Presets, grid size and tile shape are in the toolbar. Layouts are tabs and save automatically.
- **Quality:** the toolbar's **Auto / High / Low** applies to the whole layout. Each tile's **AUTO/HD/SD** button (or right-click > Quality) overrides it.
- **Tiles:** hover for the toolbar: smart search, info, maximize, **full screen**, settings and remove. The scroll wheel zooms digitally; drag to pan while zoomed. The zoom is saved with the layout, and right-click > **Open zoomed area as new tile** gives a second tile of the same camera. **Esc** leaves full screen and **F11** makes the window full screen.
- **Tours and video walls:** **Tour** in the toolbar cycles through the open layout tabs (right-click it for the interval). Right-click a layout tab > **Show full screen on** puts that layout on another monitor; Esc closes it.
- **Timeline:** green is recorded, red is motion, and amber flags are bookmarks. Scroll to zoom, drag to pan, click to jump. Hover over recorded footage for a picture preview. Right-click to bookmark or export a clip. The ◀▶ buttons jump between events, and the calendar jumps to a day. **◂◂** plays backwards, and **‹| |›** (or **,** and **.**) step one frame. **Space** plays/pauses, **← / →** jumps 10 s, **L** goes live.
- **Motion:** Camera settings > **Motion** turns detection on, sets sensitivity and paints areas to ignore. **Recording** can be *Always* or *Only when there's motion* (keeps 10 s before and after). A weekly **schedule** can switch the mode at set times, e.g. motion only during working hours.
- **Server settings** (user menu, admins): the share of the disk to keep free, an optional storage limit for all footage, and how long motion events are kept.
- **Smart search:** the magnifier on a tile, then drag a box over the area. The timeline then shows only motion inside it.
- **Users:** user menu (top right) > **User management**. Roles are Administrator, Operator and Viewer, with per-user camera lists and playback, PTZ and export permissions. Everyone can **Change password**. Admins also get an **Audit log**.
- **Forgot the password?** An admin can reset it in User management, or on the server run `ipvexa-server passwd <username>` (as the service user: `sudo -u ipvexa ipvexa-server -data /var/lib/ipvexa passwd admin`).

## Phones and browsers

- **Web view:** open `http://<server>:7480` in any browser. It has a camera grid, live view, playback and the event list, and needs no app or plugin. Video plays at full quality where the browser supports the camera's codec (H.264 everywhere, H.265 on many phones); otherwise it falls back to a lighter picture stream. SD/HD switches between the substream and the main stream.
- **Alerts:** user menu > **Phone notifications** shows the steps for the ntfy app and lets you set rules: motion, camera offline/online or disk almost full, for chosen cameras, days and hours, with cooldowns, optional bookmarks and webhooks (e.g. Home Assistant). Alerts include a snapshot, and tapping one opens the web view at that moment.

## Remote access

IPvexa never contacts the internet. To use it away from home, connect to your network with a VPN (WireGuard/Tailscale) and sign in to `http://<server-lan-ip>:7480`. Don't forward port 7480 on your router.

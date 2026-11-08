# Ipvexa — Plan

**Ipvexa** is a self-hosted video management system for Linux, built to replace Blue Iris. It aims for the look and workflow of Nx Witness: a native desktop app, a timeline-first playback screen, and synced multi-camera playback. It is one purchase, never a subscription, and fully offline.

> The name: "IPV" from IPVMS plus "exa". At the time of choosing (2026-11-08) a web search and GitHub showed no product, company, user or repository called Ipvexa. That is not a legal trademark search: check USPTO/EUIPO before any commercial use.

## Design goals

| Topic | Decision |
|---|---|
| App | **Native desktop app** (Qt 6 / C++ / FFmpeg) is the main interface, like the Nx Witness desktop client. A web view comes later for phones and remote use. |
| Server | `ipvexa-server` is a single Go binary run by **systemd**. No Docker and no containers. |
| Network | **Offline only.** No cloud and no phone-home. For remote access, use your own VPN (WireGuard/Tailscale). |
| Platforms | Ubuntu/Kubuntu now. Arch (AUR) next. macOS and Windows later. Qt and Go both port cleanly. |
| Hardware | Runs on low-power Intel mini PCs (VAAPI) up to desktops with NVIDIA GPUs (NVDEC/CUDA for decoding and AI). The app picks NVDEC, then VAAPI, then CPU automatically. |
| Cameras | First-class: Dahua/Amcrest (incl. 4K H.265), OpenIPC and Thingino open firmware. Then most cameras via RTSP + ONVIF. |

## Architecture

```
 Ipvexa desktop app (Qt/QML)                 ipvexa-server (Go, systemd)
 ┌───────────────────────────┐   HTTP/TS   ┌─────────────────────────────────────────┐
 │ Resource tree │ Video grid│◄───────────►│ API + login (bcrypt, sessions, roles)    │
 │               │ (N tiles) │   live      │ Per camera: ffmpeg → live fan-out (TS)   │
 │ Timeline (zoom/scrub)     │   playback  │                    → 1-min MP4 segments  │
 │ FFmpeg decode (NVDEC/VAAPI)│            │ Indexer → SQLite · Retention · ONVIF scan │
 └───────────────────────────┘             └─────────────────────────────────────────┘
```

- **No re-encoding.** Camera video is copied straight to disk and to viewers, so a 4K H.265 camera costs almost no server CPU.
- **Live:** one camera connection is fanned out to every viewer. New viewers start from the last keyframe, so the picture appears instantly.
- **Playback:** the server streams recorded segments from any moment, and the app paces every tile against one shared clock. That is what keeps multi-camera playback in sync.
- **Storage:** `recordings/<camera>/<stream>/YYYY/MM/DD/<unix>.mp4` (fragmented MP4, so a crash loses at most a second). Retention is per camera (days), plus a disk-space guard that deletes the oldest footage first.

## Status

### ✅ v0.1 (built and tested on Ubuntu/Kubuntu 26.04 with Intel VAAPI)
- Server: cameras (add/edit/delete), live streaming, 24/7 recording, segment index, timeline API, playback from any moment, retention, disk guard, ONVIF discovery, JPEG snapshots, login with roles, first-run admin password.
- Desktop app: sign-in, Nx-style dark shell, resource tree with drag-and-drop, layouts (1, 2×2, 3×3, 4×4, 5×5, 1+5, 1+7, 1+12), 16:9 / 4:3 / Fill tile shapes, saved layouts, double-click to maximize, automatic substream/main-stream switching by tile size.
- Desktop app, playback: hardware decoding, zoomable/draggable timeline with recorded footage, click-to-seek, synced playback across tiles, 1–16× speed (keyframe-only above 4×), LIVE button, "NO RECORDING" for gaps.
- Camera dialog: templates for Dahua/Amcrest, OpenIPC, Thingino, Hikvision, Reolink, Uniview, Axis, generic RTSP and a demo pattern.
- Packaging: systemd unit, desktop launcher, icon, `scripts/install-linux.sh`.

### Next phases

**Phase 2 — Real-camera support (next)**
- Test and tune Dahua 4K (H.265), OpenIPC PTZ and Thingino cameras (main/substreams, audio).
- ONVIF Profile S: fetch stream URLs automatically after discovery (no URL typing).
- PTZ controls on the tile (ONVIF; OpenIPC/Thingino specifics) with presets.
- Health panel: bitrate, fps, dropped connections, disk write rate.

**Phase 3 — Motion and AI**
- Motion detection on substreams (low fps, GPU decode), with zones and masks drawn on the image.
- Motion drawn on the timeline (red), and **smart search**: draw a box and find motion only there.
- Object detection (person/vehicle/animal) with ONNX Runtime + YOLO on NVIDIA GPUs (CUDA), with OpenVINO/CPU fallback.
- Camera-side events: Dahua event stream, OpenIPC/Thingino motion hooks.
- Event list with thumbnails, bookmarks with notes and tags.
- Recording modes: motion-only and scheduled, with pre/post buffer.

**Phase 4 — Phone notifications (offline-friendly)**
- Ipvexa will serve an **ntfy-compatible** notification feed itself. The ntfy Android app (or any UnifiedPush app) subscribes to it over the LAN or your VPN, so no Google/Apple cloud is involved. Alerts include a snapshot and open playback at that moment.
- iPhone caveat: iOS only delivers background notifications through Apple's servers. Fully offline iOS alerts need the app open, or a self-hosted relay. We'll pick the least-cloud option when we get there.
- Rules: what (motion/person/offline/disk) × where (camera/zone) × when (schedule: Home/Away/Night) → actions (notify, record, bookmark, webhook, MQTT/Home Assistant). Includes cooldowns so one person walking by doesn't trigger 50 alerts.

**Phase 5 — Pro features**
- Clip export (MP4 with timestamp overlay) and a bookmarks list.
- Calendar date picker, thumbnail strip on timeline hover, frame stepping, reverse playback.
- Layout tours, multi-monitor video walls (one window per screen), digital zoom (and opening a zoomed region as its own tile).
- Users and permissions UI, audit log, password change in the app.
- Server settings in the app (storage paths, multiple disks, retention by disk size).

**Phase 6 — Web/phone view**
- A lightweight web UI served by ipvexa-server (live grid + timeline) for phones and browsers over the VPN.

**Phase 7 — Distribution**
- `.deb` packages (server + app), AUR PKGBUILD, AppImage of the desktop app.
- Then macOS (Homebrew + .app) and Windows (service + installer).

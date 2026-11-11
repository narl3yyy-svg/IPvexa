# IPvexa — Plan

**IPvexa** is a self-hosted video management system for Linux, built to replace Blue Iris. It aims for the look and workflow of Nx Witness: a native desktop app, a timeline-first playback screen, and synced multi-camera playback. It is one purchase, never a subscription, and fully offline.

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
 IPvexa desktop app (Qt/QML)                 ipvexa-server (Go, systemd)
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
- Desktop app: sign-in, dark shell, resource tree with drag-and-drop, layouts, tile shapes, synced playback on a zoomable timeline, 1–16× speed, hardware decoding.
- Camera templates for Dahua/Amcrest, OpenIPC, Thingino, Hikvision, Reolink, Uniview, Axis, generic RTSP and a demo pattern.

### ✅ v0.2
- **Look and layouts:** Nx-style shell and dialogs. Free-form layouts: drag to move or swap, corner resize, presets, layout tabs. Per-layout and per-tile **High/Low/Auto quality**, camera **full screen** and window full screen, digital zoom.
- **Users:** Administrator/Operator/Viewer roles, per-user camera lists, playback/PTZ/export permissions, disabling accounts, password change in the app, password reset by admins or `ipvexa-server passwd`, audit log.
- **Phase 2 — real cameras:** Dahua 4K H.265, OpenIPC (PTZ via ptzd) and Thingino verified. ONVIF stream detection fills in stream addresses. Health panel with bitrate, fps, reconnects, disk write rate and days of space left. Fixed black H.265 tiles and faster snapshots.
- **Phase 3 — motion:** server-side motion detection on the substream (16×9 grid, sensitivity, painted ignore zones, lighting-change filter). Motion on the timeline, event list with thumbnails, previous/next event, **smart search** by area, bookmarks with notes, and **motion-only recording** (10 s before and after).
- **Phase 4 — phone alerts:** ntfy-compatible feed served by the server itself (JSON stream, SSE, polling, Basic auth), so no cloud is involved. Rules: motion / offline / online / disk low × cameras × days and hours, with cooldown and priority, then notify (with snapshot and a tap-to-open link), bookmark or webhook.
- **Phase 5 — pro features:** clip export to MP4 (original quality), bookmarks list, calendar date picker, digital zoom, users UI, audit log.
- **Phase 6 — web/phone view:** a single self-contained page at `/web/` with a camera grid, live view, playback and the event list. Video is MJPEG, so any browser works with no plugins.
- **Phase 7 — distribution:** `.deb` packages for the server (systemd, `ipvexa` system user) and the app (`scripts/build-deb.sh`), and an Arch PKGBUILD.

### ✅ v0.3
- **Linux installer:** `./install.sh` (Debian/Ubuntu and Arch) installs the build tools, builds packages, starts the service and adds the app to the menu. It can import a development setup and uninstall.
- **Playback:** reverse playback, frame stepping, and a picture preview when hovering over the timeline.
- **Layouts:** tours, video walls on other monitors, digital zoom saved per tile, and opening a zoomed area as its own tile.
- **Server:** weekly recording schedules, server settings in the app, a total storage limit.
- **Web view:** full-quality video (fragmented MP4, no re-encoding) with MJPEG as the fallback, and an SD/HD switch.
- **Fixes:** camera passwords no longer appear in error messages, `ffprobe` can't stall indexing, stricter URL redaction, and more tests (18 Go test functions across 7 packages, 28 layout-engine checks).

### ✅ v0.4
- **Layouts:** drag the borders between tiles to resize columns and rows; **Auto-arrange** fills the screen with any number of cameras (grids up to 12×12); **Maximize frames** (crop to fill) and stretch, Blue Iris style.
- **Playback:** a clear LIVE / PLAYBACK / PAUSED badge with **Go live**, the date opens the calendar, **Sync** on/off (synchronised playback of the whole layout, or only the selected camera), and small tiles play the recorded low-quality stream, so several cameras play back smoothly.
- **Recording settings:** recordings folder (switchable without a restart; older footage stays playable), default retention (optionally for all cameras), motion pre/post buffer, and recording the low-quality stream.
- **Motion:** busy cells (trees, flags, water) are learned and ignored, and an event needs the moving area to travel or grow, so things moving in place don't trigger recordings.
- **Tests:** 24 Go test functions across 7 packages, 63 layout-engine checks.

### ✅ AI object detection
- **Local AI** (person/vehicle/animal) with ONNX Runtime (loaded at run time, no cgo) and YOLOX-S/Tiny (Apache-2.0) on the CPU. The model is picked by the processor's speed. It only analyses pictures while there is motion, plus one every 30 s to learn parked objects.
- Per camera, motion can count for **anything**, **people**, **vehicles** or **people and vehicles**. With a filter set, an event (recording, alert) only starts once a wanted object moves inside the moving area. Events list what moved.

### Next
- **AI on the GPU:** ONNX Runtime's CUDA build for NVIDIA GPUs (needs cuDNN), for many cameras or larger models.
- **Camera-side events:** the Dahua event stream and OpenIPC/Thingino motion hooks. These need the cameras' HTTP/ONVIF ports reachable from the server.
- AppImage of the desktop app; then macOS (.dmg) and Windows (.exe installer).
- iPhone alerts: iOS only delivers background notifications through Apple's servers. Fully offline iOS alerts need the app open, or a self-hosted relay.

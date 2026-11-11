#!/usr/bin/env bash
# IPvexa installer for macOS on Apple silicon (M1 and newer). Builds from this
# source tree and installs:
#   - ipvexa-server: a background service that starts with the Mac
#     (launchd, data in "/Library/Application Support/IPvexa")
#   - IPvexa.app: the desktop app, in /Applications
#
# Usage:
#   ./installmac.sh               install (or upgrade) server and desktop app
#   ./installmac.sh --client      desktop app only (to view a server on another machine)
#   ./installmac.sh --server      server only
#   ./installmac.sh --uninstall   remove the programs (recordings and settings are kept)
#   ./installmac.sh --purge       remove the programs AND delete all recordings and settings
#
# Needs Homebrew (https://brew.sh). Build tools, Qt and FFmpeg are installed with it.
# To update later: git pull && ./installmac.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHAT="all"
UNINSTALL=0
PURGE=0
for a in "$@"; do
  case "$a" in
    --client) WHAT="client" ;;
    --server) WHAT="server" ;;
    --uninstall) UNINSTALL=1 ;;
    --purge) UNINSTALL=1; PURGE=1 ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $a (see --help)" >&2; exit 1 ;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "this installer is for macOS; on Linux use ./install.sh"
[[ "$(uname -m)" == arm64 ]] || die "only Apple silicon Macs (M1 and newer) are supported"
if [[ $EUID -eq 0 ]]; then die "run this as your normal user, not root (it asks for your password when needed)"; fi

LABEL="org.ipvexa.server"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
BIN="/usr/local/bin/ipvexa-server"
DATA="/Library/Application Support/IPvexa"
APP="/Applications/IPvexa.app"
FIREWALL="/usr/libexec/ApplicationFirewall/socketfilterfw"

stop_server() {
  if sudo launchctl print "system/$LABEL" >/dev/null 2>&1; then
    sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
    sleep 1
  fi
}

# ---------------------------------------------------------------- uninstall
if [[ $UNINSTALL == 1 ]]; then
  if [[ $PURGE == 1 ]]; then
    echo "This removes IPvexa AND permanently deletes every recording, camera, user and setting."
    read -r -p "Type DELETE to continue: " answer
    [[ "$answer" == "DELETE" ]] || { echo "Cancelled."; exit 1; }
  else
    read -r -p "Remove IPvexa? Recordings and settings are kept. [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]] || { echo "Cancelled."; exit 1; }
  fi
  say "Removing IPvexa (your password may be asked)"
  stop_server
  sudo rm -f "$PLIST" "$BIN"
  if [[ -x "$FIREWALL" ]]; then sudo "$FIREWALL" --remove "$BIN" >/dev/null 2>&1 || true; fi
  sudo rm -rf "$APP"
  if [[ $PURGE == 1 ]]; then
    sudo rm -rf "$DATA"
    rm -rf "$HOME/Library/Preferences/com.ipvexa.Ipvexa.plist" "$HOME/Library/Preferences/org.ipvexa.app.plist"
    say "IPvexa, its recordings and its settings are removed"
  else
    say "IPvexa is removed. Recordings and settings are still in \"$DATA\" (./installmac.sh --purge deletes them)"
  fi
  exit 0
fi

# ---------------------------------------------------------------- build tools
if ! xcode-select -p >/dev/null 2>&1; then
  say "Installing Apple's command line tools (a window opens; run this script again when it has finished)"
  xcode-select --install || true
  exit 1
fi
BREW=""
for b in brew /opt/homebrew/bin/brew; do
  if command -v "$b" >/dev/null 2>&1; then BREW="$(command -v "$b")"; break; fi
done
if [[ -z "$BREW" ]]; then
  die "Homebrew is needed. Install it with the command on https://brew.sh, then run this script again."
fi
eval "$("$BREW" shellenv)"
HB="$("$BREW" --prefix)"

need=(ffmpeg)
if [[ $WHAT != client ]]; then need+=(go); fi
if [[ $WHAT != server ]]; then need+=(cmake ninja pkg-config qt); fi
missing=()
for f in "${need[@]}"; do
  "$BREW" list --versions "$f" >/dev/null 2>&1 || missing+=("$f")
done
if ((${#missing[@]})); then
  say "Installing with Homebrew: ${missing[*]}"
  "$BREW" install "${missing[@]}"
fi
if [[ $WHAT != client ]]; then
  v="$(go env GOVERSION | sed 's/^go//')"
  if ! printf '%s\n%s\n' "1.27" "$v" | sort -V -C; then
    say "Updating Go (1.27 or newer is needed, found $v)"
    "$BREW" upgrade go
  fi
fi

say "IPvexa needs your password to install the server and the app"
sudo -v

# ---------------------------------------------------------------- server
if [[ $WHAT != client ]]; then
  say "Building the server"
  (cd "$ROOT/server" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$ROOT/server/build/ipvexa-server" ./cmd/ipvexa-server)

  # A server started by hand would hold port 7480.
  if pgrep -u "$USER" -x ipvexa-server >/dev/null; then
    say "Stopping the IPvexa server you started by hand (the service needs port 7480)"
    pkill -u "$USER" -x ipvexa-server || true
    sleep 2
  fi
  stop_server

  say "Installing the server"
  sudo mkdir -p /usr/local/bin
  sudo install -m 755 "$ROOT/server/build/ipvexa-server" "$BIN"
  sudo mkdir -p "$DATA"
  sudo chown "$USER":staff "$DATA"
  chmod 750 "$DATA"

  # The service runs as you (no extra account is needed on a Mac), starts with the
  # Mac and restarts by itself if it stops. It is also the cameras' time server on
  # port 123 (macOS lets programs use that port without special rights).
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>-data</string><string>$DATA</string>
        <string>-listen</string><string>:7480</string>
        <string>-ffmpeg</string><string>$HB/bin/ffmpeg</string>
        <string>-ffprobe</string><string>$HB/bin/ffprobe</string>
    </array>
    <key>UserName</key><string>$USER</string>
    <key>GroupName</key><string>staff</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$HB/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key><string>$HOME</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>3</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>$DATA/server.log</string>
    <key>StandardErrorPath</key><string>$DATA/server.log</string>
</dict>
</plist>
EOF
  sudo install -m 644 -o root -g wheel "$tmp" "$PLIST"
  rm -f "$tmp"

  # With the macOS firewall on, allow the server to accept connections.
  if [[ -x "$FIREWALL" ]] && "$FIREWALL" --getglobalstate 2>/dev/null | grep -qi enabled; then
    say "Allowing the server through the macOS firewall"
    sudo "$FIREWALL" --add "$BIN" >/dev/null 2>&1 || true
    sudo "$FIREWALL" --unblockapp "$BIN" >/dev/null 2>&1 || true
  fi

  say "Starting the server"
  sudo launchctl enable "system/$LABEL" # in case it was disabled before
  sudo launchctl bootstrap system "$PLIST"
fi

# ---------------------------------------------------------------- desktop app
if [[ $WHAT != server ]]; then
  say "Building the desktop app"
  build="$ROOT/client/build-mac"
  cmake -S "$ROOT/client" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$("$BREW" --prefix qt)" >/dev/null
  cmake --build "$build"

  say "Installing IPvexa.app in /Applications"
  sudo rm -rf "$APP"
  sudo cp -R "$build/IPvexa.app" "$APP"
  sudo chown -R "$USER":staff "$APP"
  # Locally built apps get an ad-hoc signature so macOS will open them.
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || warn "could not sign IPvexa.app; if macOS refuses to open it, right-click it and choose Open"
fi

# ---------------------------------------------------------------- finish
echo
say "IPvexa is installed"
if [[ $WHAT != client ]]; then
  ok=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fs -o /dev/null "http://127.0.0.1:7480/api/info"; then ok=1; break; fi
    sleep 1
  done
  if [[ $ok == 1 ]]; then
    echo "    Server:      running on port 7480 (log: \"$DATA/server.log\")"
  else
    warn "the server isn't answering yet; see \"$DATA/server.log\" or run: sudo launchctl print system/$LABEL"
  fi
  if [[ -f "$DATA/initial-admin-password" ]]; then
    echo "    First login: user 'admin', password $(cat "$DATA/initial-admin-password")"
    echo "                 (change it in the app: user menu > Change password)"
  fi
  ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="<this Mac's address>"
  echo "    Web/phones:  http://$ip:7480"
  echo "    Cameras' time server (NTP): $ip, port 123"
fi
if [[ $WHAT != server ]]; then
  echo "    Desktop app: open IPvexa from Launchpad or /Applications"
  echo "                 (the first time, macOS asks to allow local network access: choose Allow)"
  if pgrep -x IPvexa >/dev/null; then
    warn "IPvexa is still open with the old version: quit it (Cmd+Q) and open it again"
  fi
fi
echo "    Update later: git pull && ./installmac.sh"

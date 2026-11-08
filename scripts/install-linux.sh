#!/usr/bin/env bash
# Build and install Ipvexa natively on Ubuntu/Kubuntu (no containers).
#   ./scripts/install-linux.sh            build + install server and desktop app
#   ./scripts/install-linux.sh --client   desktop app only (viewing a server elsewhere)
# Needs: Go 1.27+ on PATH, and the apt packages listed in README.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT_ONLY=0
[[ "${1:-}" == "--client" ]] && CLIENT_ONLY=1

echo "==> Building desktop app"
cmake -S "$ROOT/client" -B "$ROOT/client/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -Wno-dev >/dev/null
cmake --build "$ROOT/client/build"

if [[ $CLIENT_ONLY == 0 ]]; then
  echo "==> Building server"
  (cd "$ROOT/server" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o bin/ipvexa-server ./cmd/ipvexa-server)
fi

echo "==> Installing (sudo)"
sudo install -Dm755 "$ROOT/client/build/ipvexa" /usr/local/bin/ipvexa
sudo install -Dm644 "$ROOT/packaging/linux/ipvexa.desktop" /usr/local/share/applications/ipvexa.desktop
sudo install -Dm644 "$ROOT/packaging/linux/ipvexa.svg" /usr/local/share/icons/hicolor/scalable/apps/ipvexa.svg

if [[ $CLIENT_ONLY == 0 ]]; then
  sudo install -Dm755 "$ROOT/server/bin/ipvexa-server" /usr/local/bin/ipvexa-server
  if ! id ipvexa >/dev/null 2>&1; then
    sudo useradd --system --home-dir /var/lib/ipvexa --shell /usr/sbin/nologin ipvexa
  fi
  sudo install -d -o ipvexa -g ipvexa -m 750 /var/lib/ipvexa
  sudo install -Dm644 "$ROOT/packaging/linux/ipvexa-server.service" /etc/systemd/system/ipvexa-server.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now ipvexa-server
  sleep 2
  echo
  echo "Server running:  systemctl status ipvexa-server"
  if sudo test -f /var/lib/ipvexa/initial-admin-password; then
    echo "First login:     user 'admin', password in /var/lib/ipvexa/initial-admin-password"
    echo "                 (sudo cat it, then change it: sudo -u ipvexa ipvexa-server -data /var/lib/ipvexa passwd admin)"
  fi
fi
echo "Desktop app:     launch 'Ipvexa' from the app menu"

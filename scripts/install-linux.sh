#!/usr/bin/env bash
# IPvexa installer for Linux. Builds from this source tree and installs:
#   - ipvexa-server: a systemd service (user "ipvexa", data in /var/lib/ipvexa)
#   - IPvexa desktop app: in the app menu, or run `ipvexa`
#
# Usage:
#   ./install.sh                  install (or upgrade) server and desktop app
#   ./install.sh --client         desktop app only (to view a server on another machine)
#   ./install.sh --server         server only (headless machines)
#   ./install.sh --import-dev     also move a development setup (~/.local/share/ipvexa:
#                                 cameras, users, recordings) into the installed server
#   ./install.sh --uninstall      remove the programs (recordings and settings are kept)
#
# Supports Debian/Ubuntu (apt, builds .deb packages) and Arch (pacman, builds with makepkg).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GO_VERSION="1.27.3"
WHAT="all"
IMPORT=0
UNINSTALL=0
for a in "$@"; do
  case "$a" in
    --client) WHAT="client" ;;
    --server) WHAT="server" ;;
    --import-dev) IMPORT=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $a (see --help)" >&2; exit 1 ;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ $EUID -eq 0 ]]; then die "run this as your normal user, not root (it asks for sudo when needed)"; fi
command -v sudo >/dev/null || die "sudo is required"
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
  *" debian "*|*" ubuntu "*) FAMILY=debian ;;
  *" arch "*) FAMILY=arch ;;
  *) die "unsupported distribution '${ID:-unknown}'. Supported: Debian/Ubuntu and Arch. See README.md to build by hand." ;;
esac

# ---------------------------------------------------------------- uninstall
if [[ $UNINSTALL == 1 ]]; then
  exec "$ROOT/uninstall.sh"
fi

# ---------------------------------------------------------------- build tools
install_go() {
  local g have=""
  for g in go "$HOME/.local/go/bin/go" /usr/local/go/bin/go; do
    if command -v "$g" >/dev/null 2>&1; then have="$g"; break; fi
  done
  if [[ -n "$have" ]]; then
    local v
    v="$("$have" env GOVERSION | sed 's/^go//')"
    if printf '%s\n%s\n' "1.27" "$v" | sort -V -C; then
      PATH="$(dirname "$(command -v "$have")"):$PATH"
      export PATH
      return
    fi
    warn "Go $v is too old (1.27+ is needed)"
  fi
  local arch
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "no Go download for $(uname -m); install Go 1.27+ yourself" ;;
  esac
  say "Downloading Go $GO_VERSION into ~/.local/go (only used to build IPvexa)"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" -o "$tmp/go.tgz"
  rm -rf "$HOME/.local/go"
  mkdir -p "$HOME/.local"
  tar -xzf "$tmp/go.tgz" -C "$HOME/.local"
  rm -rf "$tmp"
  export PATH="$HOME/.local/go/bin:$PATH"
}

stop_dev_server() {
  # A development server started by hand would hold port 7480.
  if pgrep -u "$USER" -x ipvexa-server >/dev/null; then
    say "Stopping the development server you started by hand (the service needs port 7480)"
    pkill -u "$USER" -x ipvexa-server || true
    sleep 2
  fi
}

if [[ $FAMILY == debian ]]; then
  say "Installing build tools and libraries (sudo)"
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends \
    ffmpeg cmake ninja-build pkg-config build-essential dpkg-dev curl ca-certificates \
    qt6-base-dev qt6-declarative-dev qt6-multimedia-dev \
    qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-layouts qml6-module-qtquick-window \
    qml6-module-qtquick-templates qml6-module-qtqml-workerscript qml6-module-qtmultimedia qml6-module-qtcore \
    libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libva-dev
  if [[ $WHAT != client ]]; then install_go; fi

  say "Building packages"
  case "$WHAT" in
    client) "$ROOT/scripts/build-deb.sh" --client ;;
    server) "$ROOT/scripts/build-deb.sh" --server ;;
    *) "$ROOT/scripts/build-deb.sh" ;;
  esac
  version="$(sed -n 's/^const Version = "\(.*\)"$/\1/p' "$ROOT/server/internal/api/api.go")"
  debarch="$(dpkg --print-architecture)"
  pkgs=()
  if [[ $WHAT != client ]]; then pkgs+=("$ROOT/dist/ipvexa-server_${version}_${debarch}.deb"); stop_dev_server; fi
  if [[ $WHAT != server ]]; then pkgs+=("$ROOT/dist/ipvexa_${version}_${debarch}.deb"); fi
  say "Installing packages (sudo)"
  sudo apt-get install -y "${pkgs[@]}"
else
  say "Installing build tools (sudo)"
  sudo pacman -S --needed --noconfirm base-devel git go cmake ninja qt6-base qt6-declarative qt6-multimedia ffmpeg
  if [[ $WHAT != client ]]; then stop_dev_server; fi
  say "Building and installing with makepkg (from this checkout's last commit)"
  work="$(mktemp -d)"
  cp "$ROOT/packaging/arch/PKGBUILD" "$ROOT/packaging/arch/ipvexa-server.install" "$work/"
  sed -i "s#^source=.*#source=(\"ipvexa::git+file://$ROOT\")#" "$work/PKGBUILD"
  (cd "$work" && makepkg -si --noconfirm)
  rm -rf "$work"
  if [[ $WHAT != client ]]; then sudo systemctl enable --now ipvexa-server; fi
fi

# ---------------------------------------------------------------- import a development setup
if [[ $IMPORT == 1 && $WHAT != client ]]; then
  src="$HOME/.local/share/ipvexa"
  if [[ ! -f "$src/ipvexa.db" ]]; then
    warn "--import-dev: nothing to import ($src/ipvexa.db not found)"
  else
    say "Moving your development setup from $src into /var/lib/ipvexa"
    sudo systemctl stop ipvexa-server
    stamp="$(date +%Y%m%d-%H%M%S)"
    if sudo test -f /var/lib/ipvexa/ipvexa.db; then
      sudo mv /var/lib/ipvexa/ipvexa.db "/var/lib/ipvexa/ipvexa.db.before-import-$stamp"
      sudo rm -f /var/lib/ipvexa/ipvexa.db-wal /var/lib/ipvexa/ipvexa.db-shm
      echo "    (the installed server's own database was kept as ipvexa.db.before-import-$stamp)"
    fi
    sudo cp -a "$src/ipvexa.db" /var/lib/ipvexa/
    for f in ipvexa.db-wal ipvexa.db-shm; do
      if [[ -f "$src/$f" ]]; then sudo cp -a "$src/$f" /var/lib/ipvexa/; fi
    done
    for d in recordings thumbs; do
      if [[ -d "$src/$d" ]]; then
        sudo mkdir -p "/var/lib/ipvexa/$d"
        sudo cp -a "$src/$d/." "/var/lib/ipvexa/$d/"
        rm -rf "${src:?}/$d"
      fi
    done
    sudo rm -f /var/lib/ipvexa/initial-admin-password # your existing users and passwords apply
    sudo chown -R ipvexa:ipvexa /var/lib/ipvexa
    mv "$src" "$src.imported-$stamp"
    sudo systemctl start ipvexa-server
    echo "    Done. Sign in with your existing username and password."
  fi
fi

# ---------------------------------------------------------------- finish
# A development launcher in ~/.local would shadow the installed one in the app menu.
dev="$HOME/.local/share/applications/ipvexa.desktop"
if [[ $WHAT != server && -f "$dev" ]] && grep -q '^Exec=.*/build/ipvexa' "$dev"; then
  rm -f "$dev"
fi
if command -v update-desktop-database >/dev/null; then
  update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null || true
fi

echo
say "IPvexa is installed"
if [[ $WHAT != client ]]; then
  if systemctl is-active --quiet ipvexa-server; then
    echo "    Server:      running on port 7480 (systemctl status ipvexa-server)"
  else
    warn "the server isn't running: sudo systemctl status ipvexa-server"
  fi
  if sudo test -f /var/lib/ipvexa/initial-admin-password; then
    echo "    First login: user 'admin', password $(sudo cat /var/lib/ipvexa/initial-admin-password)"
    echo "                 (change it in the app: user menu > Change password)"
  fi
  echo "    Web/phones:  http://$(hostname -I 2>/dev/null | awk '{print $1}'):7480"
fi
if [[ $WHAT != server ]]; then
  echo "    Desktop app: open \"IPvexa\" from the app menu, or run: ipvexa"
fi

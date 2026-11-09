#!/usr/bin/env bash
# Build Debian/Ubuntu packages into dist/:
#   ipvexa-server_<version>_<arch>.deb   recording server (systemd service, runs as user "ipvexa")
#   ipvexa_<version>_<arch>.deb          desktop app
# Needs: Go 1.27+, cmake, ninja, a C++ compiler, the Qt 6 and FFmpeg dev packages
# (see README.md), and dpkg-dev.
#   ./scripts/build-deb.sh            both packages
#   ./scripts/build-deb.sh --server   server only
#   ./scripts/build-deb.sh --client   desktop app only
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHAT="${1:-all}"
VERSION="$(sed -n 's/^const Version = "\(.*\)"$/\1/p' "$ROOT/server/internal/api/api.go")"
# Every build from a newer commit gets a higher package version (0.4.0+r57.565ad05),
# so installing it always replaces the previous build, even when the release number
# hasn't changed. Uncommitted changes add a build time so they count as newer too.
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  VERSION="$VERSION+r$(git -C "$ROOT" rev-list --count HEAD).$(git -C "$ROOT" rev-parse --short HEAD)"
  if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]]; then
    VERSION="$VERSION.local$(date +%s)"
  fi
fi
ARCH="$(dpkg --print-architecture)"
MAINT="IPvexa project <283486160+narl3yyy-svg@users.noreply.github.com>"
OUT="$ROOT/dist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
echo "$VERSION" > "$OUT/.version" # read by install-linux.sh

build_server() {
  echo "==> Building ipvexa-server $VERSION"
  (cd "$ROOT/server" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$WORK/ipvexa-server" ./cmd/ipvexa-server)
  local P="$WORK/server-pkg"
  install -Dm755 "$WORK/ipvexa-server" "$P/usr/bin/ipvexa-server"
  sed 's#/usr/local/bin/ipvexa-server#/usr/bin/ipvexa-server#' "$ROOT/packaging/linux/ipvexa-server.service" \
    | install -Dm644 /dev/stdin "$P/usr/lib/systemd/system/ipvexa-server.service"
  install -Dm644 "$ROOT/LICENSE" "$P/usr/share/doc/ipvexa-server/copyright"
  mkdir -p "$P/DEBIAN"
  cat > "$P/DEBIAN/control" <<EOF
Package: ipvexa-server
Version: $VERSION
Architecture: $ARCH
Maintainer: $MAINT
Depends: ffmpeg, adduser, systemd
Section: video
Priority: optional
Homepage: https://github.com/narl3yyy-svg/IPvexa
Description: IPvexa video management server
 Records IP cameras around the clock or on motion, detects motion, and serves
 live and recorded video to the IPvexa desktop app, browsers and phones.
 Runs fully offline; reach it from outside through your own VPN.
EOF
  cat > "$P/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  if ! getent passwd ipvexa >/dev/null; then
    adduser --system --group --home /var/lib/ipvexa --no-create-home --shell /usr/sbin/nologin ipvexa >/dev/null
  fi
  for g in video render; do getent group "$g" >/dev/null && adduser ipvexa "$g" >/dev/null 2>&1 || true; done
  install -d -o ipvexa -g ipvexa -m 750 /var/lib/ipvexa
  if [ -d /run/systemd/system ]; then
    systemctl daemon-reload
    systemctl enable ipvexa-server.service >/dev/null 2>&1 || true
    systemctl restart ipvexa-server.service || true
  fi
  sleep 2
  if [ -f /var/lib/ipvexa/initial-admin-password ]; then
    echo "IPvexa: first sign-in is user 'admin' with the password in /var/lib/ipvexa/initial-admin-password"
    echo "        (read it with: sudo cat /var/lib/ipvexa/initial-admin-password, then change it in the app)"
  fi
fi
exit 0
EOF
  cat > "$P/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if [ -d /run/systemd/system ] && [ "$1" = "remove" ]; then
  systemctl disable --now ipvexa-server.service >/dev/null 2>&1 || true
fi
exit 0
EOF
  cat > "$P/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ -d /run/systemd/system ]; then systemctl daemon-reload >/dev/null 2>&1 || true; fi
if [ "$1" = "purge" ]; then
  # Recordings and settings are never deleted automatically.
  echo "IPvexa: recordings and settings were kept in /var/lib/ipvexa. Delete that folder yourself if you no longer need them."
fi
exit 0
EOF
  chmod 755 "$P/DEBIAN/postinst" "$P/DEBIAN/prerm" "$P/DEBIAN/postrm"
  dpkg-deb --root-owner-group --build "$P" "$OUT/ipvexa-server_${VERSION}_${ARCH}.deb" >/dev/null
  echo "    $OUT/ipvexa-server_${VERSION}_${ARCH}.deb"
}

build_client() {
  echo "==> Building ipvexa (desktop app) $VERSION"
  cmake -S "$ROOT/client" -B "$WORK/client-build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -Wno-dev >/dev/null
  cmake --build "$WORK/client-build" >/dev/null
  local P="$WORK/client-pkg"
  install -Dm755 "$WORK/client-build/ipvexa" "$P/usr/bin/ipvexa"
  strip --strip-unneeded "$P/usr/bin/ipvexa"
  install -Dm644 "$ROOT/packaging/linux/ipvexa.desktop" "$P/usr/share/applications/ipvexa.desktop"
  install -Dm644 "$ROOT/packaging/linux/ipvexa.svg" "$P/usr/share/icons/hicolor/scalable/apps/ipvexa.svg"
  install -Dm644 "$ROOT/LICENSE" "$P/usr/share/doc/ipvexa/copyright"
  # Shared libraries from the binary, plus the QML modules it imports at run time.
  mkdir -p "$WORK/shlib/debian"
  printf 'Source: ipvexa\n\nPackage: ipvexa\nArchitecture: any\n' > "$WORK/shlib/debian/control"
  local libs
  libs="$(cd "$WORK/shlib" && dpkg-shlibdeps -O "$P/usr/bin/ipvexa" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')"
  local qml="qml6-module-qtquick, qml6-module-qtquick-controls, qml6-module-qtquick-templates, qml6-module-qtquick-layouts, qml6-module-qtquick-window, qml6-module-qtqml-workerscript, qml6-module-qtmultimedia, qml6-module-qtcore"
  mkdir -p "$P/DEBIAN"
  cat > "$P/DEBIAN/control" <<EOF
Package: ipvexa
Version: $VERSION
Architecture: $ARCH
Maintainer: $MAINT
Depends: ${libs:+$libs, }$qml
Recommends: va-driver-all
Section: video
Priority: optional
Homepage: https://github.com/narl3yyy-svg/IPvexa
Description: IPvexa video management system - desktop app
 Live view and synchronized playback for an IPvexa server: free-form layouts,
 timeline with motion and bookmarks, smart motion search, PTZ, clip export and
 user management. Uses NVIDIA (NVDEC) or Intel/AMD (VAAPI) hardware decoding.
EOF
  dpkg-deb --root-owner-group --build "$P" "$OUT/ipvexa_${VERSION}_${ARCH}.deb" >/dev/null
  echo "    $OUT/ipvexa_${VERSION}_${ARCH}.deb"
}

case "$WHAT" in
  --server) build_server ;;
  --client) build_client ;;
  *) build_server; build_client ;;
esac
echo "Install with: sudo apt install ./dist/<package>.deb"

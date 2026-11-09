#!/usr/bin/env bash
# IPvexa uninstaller for Linux.
#
#   ./uninstall.sh            remove the server and the desktop app; keep recordings and settings
#   ./uninstall.sh --purge    also delete ALL recordings, cameras, users and settings
#                             (/var/lib/ipvexa) and the app's saved layouts (~/.config/Ipvexa)
#   ./uninstall.sh --yes      don't ask for confirmation
set -euo pipefail

PURGE=0
YES=0
for a in "$@"; do
  case "$a" in
    --purge) PURGE=1 ;;
    --yes|-y) YES=1 ;;
    -h|--help) sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $a (see --help)" >&2; exit 1 ;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ $EUID -eq 0 ]]; then die "run this as your normal user, not root (it asks for sudo when needed)"; fi
command -v sudo >/dev/null || die "sudo is required"

if [[ $YES == 0 ]]; then
  if [[ $PURGE == 1 ]]; then
    echo "This removes IPvexa AND permanently deletes every recording, camera, user and setting."
    read -r -p "Type DELETE to continue: " answer
    [[ "$answer" == "DELETE" ]] || { echo "Cancelled."; exit 1; }
  else
    read -r -p "Remove IPvexa? Recordings and settings are kept. [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]] || { echo "Cancelled."; exit 1; }
  fi
fi

say "Stopping the server"
if systemctl list-unit-files ipvexa-server.service >/dev/null 2>&1; then
  sudo systemctl disable --now ipvexa-server.service 2>/dev/null || true
fi
pkill -u "$USER" -x ipvexa 2>/dev/null || true # the desktop app, if open

say "Removing the programs"
if command -v dpkg >/dev/null; then
  pkgs=()
  for p in ipvexa-server ipvexa; do
    if dpkg -s "$p" >/dev/null 2>&1; then pkgs+=("$p"); fi
  done
  if [[ ${#pkgs[@]} -gt 0 ]]; then
    if [[ $PURGE == 1 ]]; then sudo apt-get purge -y "${pkgs[@]}"; else sudo apt-get remove -y "${pkgs[@]}"; fi
  fi
elif command -v pacman >/dev/null; then
  for p in ipvexa-server-git ipvexa-git; do
    if pacman -Q "$p" >/dev/null 2>&1; then sudo pacman -Rns --noconfirm "$p"; fi
  done
fi
# Copies installed by hand into /usr/local by older versions of the installer.
for f in /usr/local/bin/ipvexa /usr/local/bin/ipvexa-server /usr/local/share/applications/ipvexa.desktop \
         /usr/local/share/icons/hicolor/scalable/apps/ipvexa.svg /etc/systemd/system/ipvexa-server.service; do
  if [[ -e "$f" ]]; then sudo rm -f "$f"; fi
done
rm -f "$HOME/.local/share/applications/ipvexa.desktop"
sudo systemctl daemon-reload 2>/dev/null || true

if [[ $PURGE == 1 ]]; then
  say "Deleting recordings, settings and the service user"
  sudo rm -rf /var/lib/ipvexa
  if getent passwd ipvexa >/dev/null; then sudo userdel ipvexa 2>/dev/null || true; fi
  if getent group ipvexa >/dev/null; then sudo groupdel ipvexa 2>/dev/null || true; fi
  rm -rf "$HOME/.config/Ipvexa"
  echo "IPvexa and all of its data have been removed."
else
  echo "IPvexa has been removed. Recordings and settings are still in /var/lib/ipvexa;"
  echo "reinstall with ./install.sh to pick them up again, or run ./uninstall.sh --purge to delete them."
fi

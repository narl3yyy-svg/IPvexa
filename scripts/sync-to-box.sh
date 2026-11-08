#!/usr/bin/env bash
# Copy the source tree to a Linux build/test machine over SSH (into ~/ipvexa).
# Usage: scripts/sync-to-box.sh user@host [ssh-key]
#   or set IPVEXA_DEV_HOST (and optionally IPVEXA_DEV_KEY) in your environment.
set -euo pipefail
HOST="${1:-${IPVEXA_DEV_HOST:-}}"
KEY="${2:-${IPVEXA_DEV_KEY:-}}"
if [[ -z "$HOST" ]]; then
  echo "usage: $0 user@host [ssh-key]   (or set IPVEXA_DEV_HOST)" >&2
  exit 1
fi
SSH=(ssh -o BatchMode=yes)
[[ -n "$KEY" ]] && SSH+=(-i "$KEY")
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
tar --exclude='./client/build' --exclude='./server/bin' --exclude='./.git' -czf - . \
  | "${SSH[@]}" "$HOST" 'mkdir -p ~/ipvexa && tar -xzf - -C ~/ipvexa'
echo "synced to $HOST:~/ipvexa"

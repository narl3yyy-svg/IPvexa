#!/usr/bin/env bash
# IPvexa installer: ./install.sh --help for options. The work is done by scripts/install-linux.sh.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/install-linux.sh" "$@"

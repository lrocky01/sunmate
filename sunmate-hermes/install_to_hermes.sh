#!/usr/bin/env bash
# Backward-compatible alias; all behavior belongs to setup_hermes.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/setup_hermes.sh" "$@"

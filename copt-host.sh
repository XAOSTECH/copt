#!/usr/bin/env bash
# ============================================================================
# copt-host — Run copt from host with direct hardware access
# ============================================================================
# This script runs ON THE HOST and uses the containerized FFmpeg.
#
# Setup (one-time):
#   1. Copy this script to your host: cp copt-host.sh ~/bin/copt-host
#   2. Make it executable: chmod +x ~/bin/copt-host
#   3. Ensure you're in video/render groups:
#      sudo usermod -aG video,render $USER
#      (log out and back in)
#
# Usage:
#   copt-host [COPT_OPTIONS]
#
# Example:
#   copt-host --profile 1080p60 -y YOUR_STREAM_KEY
#   copt-host -A -o /tmp/test.mkv
#
# How it works:
#   - Finds your running devcontainer
#   - Bind-mounts host's /dev/dri into a temporary privileged exec
#   - Runs copt with direct host DRI access
#
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================

set -euo pipefail

# Colors
C_GRN='\033[0;32m' C_YEL='\033[0;33m' C_RED='\033[0;31m' C_CYN='\033[0;36m' C_RST='\033[0m'
ok()   { printf "${C_GRN}[OK]${C_RST}  %s\n" "$*"; }
warn() { printf "${C_YEL}[!!]${C_RST}  %s\n" "$*"; }
err()  { printf "${C_RED}[ERR]${C_RST} %s\n" "$*"; }
info() { printf "[${C_CYN}INFO${C_RST}] %s\n" "$*"; }
die()  { err "$@"; exit 1; }

# ============================================================================
# Find the copt devcontainer
# ============================================================================
info "Looking for copt devcontainer..."

CONTAINER_ID=$(podman ps --filter "label=devcontainer.local_folder" --format "{{.ID}}" 2>/dev/null | head -1)

if [[ -z "$CONTAINER_ID" ]]; then
    # Try by workspace mount
    CONTAINER_ID=$(podman ps --format "{{.ID}}" 2>/dev/null | while read -r cid; do
        if podman inspect "$cid" 2>/dev/null | grep -q "/workspaces/copt"; then
            echo "$cid"
            break
        fi
    done)
fi

if [[ -z "$CONTAINER_ID" ]]; then
    die "No copt devcontainer found. Start VS Code devcontainer first."
fi

ok "Found container: $CONTAINER_ID"

# ============================================================================
# Check host DRI access
# ============================================================================
if [[ ! -r /dev/dri/card0 ]] && [[ ! -r /dev/dri/card1 ]]; then
    err "No DRI device access on host. Add your user to video/render groups:"
    err "  sudo usermod -aG video,render \$USER"
    err "Then log out and log back in for changes to take effect."
    exit 1
fi

ok "Host has DRI device access"

# ============================================================================
# Execute copt in container with host's DRI devices
# ============================================================================
# Key technique: Use 'podman exec' with the container that already has
# devices mounted, but the container was started with --privileged so
# the exec inherits proper access.

info "Executing copt..."

exec podman exec \
    --env DISPLAY="${DISPLAY:-:0}" \
    --env WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
    --env XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}" \
    -it \
    "$CONTAINER_ID" \
    sudo bash /workspaces/copt/src/copt.sh "$@"

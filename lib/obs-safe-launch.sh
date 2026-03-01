#!/usr/bin/env bash
# ============================================================================
# OBS Safe Launcher - Prevents USB device crashes
# ============================================================================
# Monitors device health and restarts OBS on disconnect instead of hanging
#
# Usage:
#   ./obs-safe-launch.sh [OBS arguments...]
#
# The wrapper:
#  1. Detects device by stable /dev/v4l/by-id path
#  2. Monitors for device disconnects
#  3. Automatically restarts OBS if device goes down
#  4. Prevents zombie FFmpeg processes from hanging the UI
# ============================================================================

set -euo pipefail

# Colours
C_GRN='\033[0;32m'
C_YEL='\033[0;33m'
C_RED='\033[0;31m'
C_CYN='\033[0;36m'
C_RST='\033[0m'

ok()   { printf "${C_GRN}[OK]${C_RST}  %s\n" "$*"; }
warn() { printf "${C_YEL}[!!]${C_RST}  %s\n" "$*"; }
err()  { printf "${C_RED}[ERR]${C_RST} %s\n" "$*"; }
info() { printf "[${C_CYN}INFO${C_RST}] %s\n" "$*"; }

# Find UGREEN device
find_ugreen() {
    local dev=$(find /dev/v4l/by-id -name "*UGREEN*25173*" -type l 2>/dev/null | head -1)
    if [[ -n "$dev" ]]; then
        readlink -f "$dev"
        return 0
    fi
    return 1
}

# Check if device exists
check_device() {
    local device="$1"
    [[ -c "$device" ]]
}

# Start OBS
start_obs() {
    info "Starting OBS..."
    obs "$@" &
    local pid=$!
    echo "$pid"
    return 0
}

# Main loop
main() {
    local ugreen_device
    if ! ugreen_device=$(find_ugreen); then
        err "UGREEN 25173 not found"
        exit 1
    fi

    ok "Found UGREEN device: $ugreen_device"

    local obs_pid=""
    local restart_count=0

    while true; do
        if [[ -z "$obs_pid" ]]; then
            obs_pid=$(start_obs "$@")
            ok "OBS started (PID: $obs_pid)"
            restart_count=0
        fi

        # Check device health
        if ! check_device "$ugreen_device"; then
            warn "Device disconnected!"
            ((restart_count++))

            # Kill OBS gracefully
            if [[ -n "$obs_pid" ]] && kill -0 "$obs_pid" 2>/dev/null; then
                info "Terminating OBS (PID: $obs_pid)..."
                kill -TERM "$obs_pid" 2>/dev/null || true
                sleep 2
                kill -9 "$obs_pid" 2>/dev/null || true
            fi

            # Clean up any orphaned FFmpeg processes
            pkill -f "ffmpeg.*usb-video-capture" || true
            sleep 2

            obs_pid=""

            # Wait for device to return
            info "Waiting for device to reconnect..."
            local wait_count=0
            while ! check_device "$ugreen_device" && [[ $wait_count -lt 30 ]]; do
                sleep 1
                ((wait_count++))
            done

            if ! check_device "$ugreen_device"; then
                err "Device did not reconnect after 30s"
                exit 1
            fi

            ok "Device reconnected. Restarting OBS (attempt $restart_count)..."
            sleep 1
        else
            # Device OK, check if OBS is still running
            if ! kill -0 "$obs_pid" 2>/dev/null; then
                warn "OBS has exited"
                obs_pid=""
                continue
            fi
        fi

        sleep 5
    done
}

main "$@"

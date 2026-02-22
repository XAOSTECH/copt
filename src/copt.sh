#!/usr/bin/env bash
# ============================================================================
# copt — Capture Operations with auto-restart and container exec support
# ============================================================================
# Main entry point for copt. Handles auto-restart, USB reconnect, container
# exec mode detection, and preview window integration.
#
# Execution mode (auto-detected):
#
#   exec  — On the host: execs into the running devcontainer (DEFAULT).
#            Uses the container's FFmpeg (NVENC SDK 13.0), CUDA, and all
#            streaming tools. USB device must be in devcontainer.json runArgs.
#
#   local — Inside a devcontainer: runs copt-worker.sh directly.
#
#   host  — Host-only mode (--host flag or no container). Direct hardware
#            access with lower latency. Requires FFmpeg + NVIDIA on host.
#
# Default stream: 4K 30fps HDR10 PQ → YouTube Live HLS
#   Profile : usb-capture-4k30-hdr
#   Device  : resolved by VID:PID 3188:1000 (no /dev/videoX index used)
#
# Setup (one-time, on the HOST):
#   sudo usermod -aG video $USER        # then log out / back in
#   sudo apt install v4l-utils          # v4l2-ctl for device discovery
#   cp copt.sh ~/bin/copt && chmod +x ~/bin/copt
#
# Usage:
#   copt --hls --hls-url https://... -y STREAM_KEY   # HDR stream
#   copt --preview --hls -y STREAM_KEY               # with preview window
#   copt -o ~/capture.mkv                            # record to file
#   copt --dry-run -o /tmp/test.mkv                  # 5s test clip
#   copt --profile usb-capture-1080p30 -y KEY        # 1080p stable
#   copt --host -y STREAM_KEY                        # force host execution
#
# Options:
#   --preview             Launch preview window alongside stream
#   --profile NAME        Override default profile (usb-capture-4k30-hdr)
#   --host                Force host execution (skip container, lower latency)
#   (all other args passed to copt-worker.sh)
#
# Environment overrides:
#   COPT_USB_VID_PID      VID:PID of capture card (default: 3188:1000)
#   COPT_CONTAINER        Force container "runtime:id" (e.g. podman:abc123)
#   COPT_RESTART_DELAY    Seconds between restarts (default: 5)
#   COPT_MAX_RETRIES      Max retries, 0=infinite (default: 0)
#
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
C_GRN='\033[0;32m' C_YEL='\033[0;33m' C_RED='\033[0;31m' C_CYN='\033[0;36m' C_RST='\033[0m'
ok()   { printf "${C_GRN}[OK]${C_RST}  %s\n" "$*"; }
warn() { printf "${C_YEL}[!!]${C_RST}  %s\n" "$*"; }
err()  { printf "${C_RED}[ERR]${C_RST} %s\n" "$*"; }
info() { printf "[${C_CYN}INFO${C_RST}] %s\n" "$*"; }
die()  { err "$@"; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────
VID_PID="${COPT_USB_VID_PID:-3188:1000}"
RESTART_DELAY="${COPT_RESTART_DELAY:-5}"
MAX_RETRIES="${COPT_MAX_RETRIES:-0}"
DEFAULT_PROFILE="usb-capture-4k30-hdr"
PREVIEW_ENABLED=0
PREVIEW_PID=""
PREVIEW_SOURCE=""
PREVIEW_ENV_ARGS=()
FORCE_HOST_MODE=0
STOP_REQUESTED=0
CHILD_PID=""
CHILD_PGID=""

USB_DISCONNECT_RE='Device.*disconnected|select timed out|Input/output error|No such device|failed to reset|double free'

# ============================================================================
# Helpers
# ============================================================================

# Start preview window if --preview flag was passed
start_preview() {
    local preview_script=""
    
    # Find copt-preview.sh in the same location as this script
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${script_dir}/copt-preview.sh" ]]; then
        preview_script="${script_dir}/copt-preview.sh"
    elif command -v copt-preview &>/dev/null; then
        preview_script=$(command -v copt-preview)
    else
        warn "copt-preview.sh not found - skipping preview"
        return 1
    fi
    
    info "Starting preview window..."
    local preview_args=(start)
    if [[ -n "$PREVIEW_SOURCE" ]]; then
        preview_args+=(--source "$PREVIEW_SOURCE")
    else
        preview_args+=(--device "$VIDEO_DEV")
    fi
    "$preview_script" "${preview_args[@]}" &>/dev/null &
    sleep 1
    
    # Check if preview started successfully
    if "$preview_script" status &>/dev/null; then
        PREVIEW_PID=$(cat /tmp/copt-preview.pid 2>/dev/null || echo "")
        ok "Preview window opened (PID: ${PREVIEW_PID})"
    else
        warn "Preview failed to start (stream will continue)"
    fi
}

# Stop preview window
stop_preview() {
    if [[ -n "$PREVIEW_PID" ]] || [[ -f /tmp/copt-preview.pid ]]; then
        info "Stopping preview window..."
        local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "${script_dir}/copt-preview.sh" ]]; then
            "${script_dir}/copt-preview.sh" stop &>/dev/null || true
        elif command -v copt-preview &>/dev/null; then
            copt-preview stop &>/dev/null || true
        fi
    fi
}

# Fast exit handler (Ctrl+C)
on_interrupt() {
    STOP_REQUESTED=1
    if [[ -n "$CHILD_PGID" ]]; then
        kill -TERM -- "-$CHILD_PGID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
        CHILD_PID=""
        CHILD_PGID=""
    elif [[ -n "$CHILD_PID" ]]; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
        CHILD_PID=""
    fi
    stop_preview
    exit 0
}
trap on_interrupt INT TERM

# True when this process is running inside a container
in_container() {
    [[ -f /run/.containerenv ]] || [[ -f /.dockerenv ]]
}

# Find the copt devcontainer by image name; prints "runtime:containerid"
# Image: devcontrol/streaming:latest  (set in .devcontainer/devcontainer.json)
# Override: COPT_CONTAINER=podman:ID
find_container() {
    local cid="" runtime
    for runtime in podman docker; do
        command -v "$runtime" &>/dev/null || continue
        cid=$("$runtime" ps \
              --filter "ancestor=devcontrol/streaming:latest" \
              --filter "status=running" \
              --format "{{.ID}}" 2>/dev/null | head -1) || true
        if [[ -n "$cid" ]]; then echo "$runtime:$cid"; return 0; fi
    done
    return 1
}

# Resolve capture device — stable udev symlink preferred, sysfs fallback
find_video_device() {
    # Prefer stable udev symlink (set up by 99-usb-video-capture.rules)
    # The udev rule already filters by VID:PID, so if it exists, use it.
    if [[ -e /dev/usb-video-capture1 ]]; then
        echo "/dev/usb-video-capture1"; return 0
    fi

    local vid="${1%%:*}" pid="${1##*:}" sys_dev
    for sys_dev in /sys/bus/usb/devices/*/; do
        local v p
        v=$(cat "${sys_dev}idVendor"  2>/dev/null) || continue
        p=$(cat "${sys_dev}idProduct" 2>/dev/null) || continue
        if [[ "${v,,}" == "${vid,,}" && "${p,,}" == "${pid,,}" ]]; then
            local node
            node=$(find "$sys_dev" -maxdepth 6 -name "video[0-9]*" \
                       -path "*/video4linux/*" 2>/dev/null \
                   | head -1 | xargs -r basename)
            if [[ -n "$node" && -e "/dev/$node" ]]; then echo "/dev/$node"; return 0; fi
        fi
    done
    # v4l2-ctl fallback
    if command -v v4l2-ctl &>/dev/null; then
        local node
        node=$(v4l2-ctl --list-devices 2>/dev/null \
               | awk '/UGREEN|ITE|25173|'"${vid}"'/{f=1} f && /\/dev\/video/{print $1; exit}')
        if [[ -n "$node" && -e "$node" ]]; then echo "$node"; return 0; fi
    fi
    return 1
}

# Poll until device node + lsusb entry reappear
wait_for_device() {
    local dev="$1" timeout="${COPT_USB_RECONNECT_TIMEOUT:-120}" elapsed=0
    warn "Waiting up to ${timeout}s for ${dev} (${VID_PID}) to reappear..."
    while [[ $elapsed -lt $timeout ]]; do
        if [[ -e "$dev" ]] && lsusb 2>/dev/null | grep -qi "$VID_PID"; then
            sleep "${COPT_USB_SETTLE_DELAY:-2}"
            ok "${dev} ready after ${elapsed}s"
            return 0
        fi
        sleep 2; elapsed=$((elapsed + 2))
    done
    err "${dev} did not reappear within ${timeout}s"; return 1
}

# ============================================================================
# Main
# ============================================================================
echo ""
echo "  copt — USB/Wayland capture with HDR support"
echo "  USB device : ${VID_PID}"
echo "  Profile    : ${DEFAULT_PROFILE} (override with --profile)"
echo ""

# ── Parse flags early (needed for --host) ───────────────────────────────────
USER_ARGS=("$@")
has_profile=0
FILTERED_ARGS=()

# Parse user args: extract --preview, --host, --profile, and streaming flags
STREAMING_HINT=0
for _a in "${USER_ARGS[@]+"${USER_ARGS[@]}"}"; do
    if [[ "$_a" == "--profile" ]]; then
        has_profile=1
        FILTERED_ARGS+=("$_a")
    elif [[ "$_a" == "--preview" ]]; then
        PREVIEW_ENABLED=1
    elif [[ "$_a" == "--host" ]]; then
        FORCE_HOST_MODE=1
    elif [[ "$_a" == "--hls" || "$_a" == "--rtmp" || "$_a" == "-y" || "$_a" == "--youtube-key" || "$_a" == "--hls-url" || "$_a" == "--rtmp-url" ]]; then
        STREAMING_HINT=1
        FILTERED_ARGS+=("$_a")
    else
        FILTERED_ARGS+=("$_a")
    fi
done

# When preview is enabled for streaming, use stream-based preview (no device grab)
if [[ $PREVIEW_ENABLED -eq 1 && $STREAMING_HINT -eq 1 ]]; then
    PREVIEW_SOURCE="udp://127.0.0.1:11000?pkt_size=1316"
    PREVIEW_ENV_ARGS+=("COPT_PREVIEW_OUTPUT=${PREVIEW_SOURCE}")
    PREVIEW_ENV_ARGS+=("COPT_PREVIEW_FORMAT=mpegts")
fi

# ── Determine execution mode and resolve copt-worker.sh path ────────────────
EXEC_MODE=""
RUNTIME=""
CONTAINER_ID=""
COPT_SCRIPT=""

if in_container; then
    # ── local: already inside the devcontainer — run copt-worker.sh directly ──
    EXEC_MODE=local
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    COPT_SCRIPT="${SCRIPT_DIR}/copt-worker.sh"
    [[ -f "$COPT_SCRIPT" ]] || die "copt-worker.sh not found at: ${COPT_SCRIPT}"
    info "In-container mode — running copt-worker.sh directly"
    ok "copt: ${COPT_SCRIPT}"
else
    # ── On the host — check if forced to host-only mode ───────────────────────
    if [[ $FORCE_HOST_MODE -eq 1 ]]; then
        info "Host-only mode forced (--host flag)"
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        HOST_SCRIPT="${SCRIPT_DIR}/copt-worker.sh"
        if [[ ! -f "$HOST_SCRIPT" ]]; then
            for candidate in \
                ~/PRO/WEB/CST/copt/src/copt-worker.sh \
                /workspaces/CST/copt/src/copt-worker.sh \
                /workspaces/copt/src/copt-worker.sh
            do
                [[ -f "$candidate" ]] && { HOST_SCRIPT="$candidate"; break; }
            done
        fi
        [[ -f "$HOST_SCRIPT" ]] || die "copt-worker.sh not found. Try without --host flag."
        EXEC_MODE=host
        COPT_SCRIPT="$HOST_SCRIPT"
        ok "copt (host-only): ${COPT_SCRIPT}"
        info "Lower latency mode - using host FFmpeg/NVENC directly"
    else
        # ── Default: exec into devcontainer (bleeding-edge FFmpeg/CUDA/NVENC) ──
        # Container exec is preferred when available: the devcontainer holds
        # compiled FFmpeg (NVENC SDK 13.0), CUDA, and all streaming tools.
        # Fallback to host-direct only when no container is running.
        CONTAINER_RAW="${COPT_CONTAINER:-}"
        if [[ -z "$CONTAINER_RAW" ]]; then
            CONTAINER_RAW=$(find_container) || true
        fi

        if [[ -n "$CONTAINER_RAW" ]]; then
            RUNTIME="${CONTAINER_RAW%%:*}"
            CONTAINER_ID="${CONTAINER_RAW##*:}"
            ok "Container: ${CONTAINER_ID} (via ${RUNTIME})"

            EXEC_MODE=exec
            for candidate in /workspaces/CST/copt/src/copt-worker.sh /workspaces/copt/src/copt-worker.sh; do
                if "$RUNTIME" exec "$CONTAINER_ID" test -f "$candidate" 2>/dev/null; then
                    COPT_SCRIPT="$candidate"; break
                fi
            done
            [[ -n "$COPT_SCRIPT" ]] \
                || die "copt-worker.sh not found in container. Expected: /workspaces/CST/copt/src/copt-worker.sh"
            info "Container mode — running inside devcontainer (FFmpeg/NVENC/CUDA)"
            ok "copt (in container): ${COPT_SCRIPT}"
        else
            # Fallback: no container running — run directly on host
            warn "No devcontainer found — falling back to host-direct mode"
            warn "Start the VS Code devcontainer for full NVENC/CUDA support"
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            HOST_SCRIPT="${SCRIPT_DIR}/copt-worker.sh"
            if [[ ! -f "$HOST_SCRIPT" ]]; then
                for candidate in \
                    ~/PRO/WEB/CST/copt/src/copt-worker.sh \
                    /workspaces/CST/copt/src/copt-worker.sh \
                    /workspaces/copt/src/copt-worker.sh
                do
                    [[ -f "$candidate" ]] && { HOST_SCRIPT="$candidate"; break; }
                done
            fi
            [[ -f "$HOST_SCRIPT" ]] || die "copt-worker.sh not found on host and no container running."
            EXEC_MODE=host
            COPT_SCRIPT="$HOST_SCRIPT"
            ok "copt (host fallback): ${COPT_SCRIPT}"
        fi
    fi
fi

# ── USB device ────────────────────────────────────────────────────────────────
info "Looking for USB device ${VID_PID}..."
lsusb 2>/dev/null | grep -qi "$VID_PID" \
    || die "USB device ${VID_PID} not on bus. Is UGREEN 25173 plugged in?"
VIDEO_DEV=$(find_video_device "$VID_PID") \
    || die "No /dev/videoX for ${VID_PID}. Try: v4l2-ctl --list-devices"
ok "Video device: ${VIDEO_DEV}"
[[ -r "$VIDEO_DEV" ]] \
    || die "Cannot read ${VIDEO_DEV}.\n  sudo usermod -aG video \$USER  (then log out/in)"

# ── Build copt arg list ───────────────────────────────────────────────────────
rebuild_args() {
    BASE_ARGS=(--capture-mode usb --usb-device "$VIDEO_DEV" --usb-vid-pid "$VID_PID")
    [[ $has_profile -eq 0 ]] && BASE_ARGS+=(--profile "$DEFAULT_PROFILE")
    COPT_ARGS=("${BASE_ARGS[@]}" "${FILTERED_ARGS[@]+"${FILTERED_ARGS[@]}"}")
}
rebuild_args

# ── Autorestart loop ──────────────────────────────────────────────────────────
retry_count=0
start_time=$(date +%s)
tmplog=$(mktemp /tmp/copt-host-XXXXXX.log)
trap 'stop_preview; rm -f "$tmplog"' EXIT

info "Exec mode: ${EXEC_MODE}  |  autorestart: enabled  |  max: ${MAX_RETRIES:-infinite}"
[[ $PREVIEW_ENABLED -eq 1 ]] && info "Preview: enabled (window will open)"
echo ""

# Start preview window if requested
if [[ $PREVIEW_ENABLED -eq 1 ]]; then
    start_preview || warn "Preview unavailable - continuing with stream only"
    echo ""
fi

while true; do
    retry_count=$((retry_count + 1))
    if [[ $MAX_RETRIES -gt 0 && $retry_count -gt $MAX_RETRIES ]]; then
        err "Max retries (${MAX_RETRIES}) reached — giving up."; exit 1
    fi
    [[ $retry_count -eq 1 ]] && ok "Attempt #${retry_count}" \
                              || warn "Restart attempt #${retry_count}"
    : > "$tmplog"

    env_prefix=()
    if [[ ${#PREVIEW_ENV_ARGS[@]} -gt 0 ]]; then
        env_prefix=(env "${PREVIEW_ENV_ARGS[@]}")
    fi

    set +e
    case "$EXEC_MODE" in
        local)
            # Inside container already — run directly
            setsid sudo "${env_prefix[@]}" bash "$COPT_SCRIPT" "${COPT_ARGS[@]}" \
                2> >(tee -a "$tmplog" >&2) &
            CHILD_PID=$!
            CHILD_PGID=$CHILD_PID
            ;;
        host)
            # On host — run directly (USB device natively visible)
            setsid sudo "${env_prefix[@]}" bash "$COPT_SCRIPT" "${COPT_ARGS[@]}" \
                2> >(tee -a "$tmplog" >&2) &
            CHILD_PID=$!
            CHILD_PGID=$CHILD_PID
            ;;
        exec)
            # Exec into container (device must be in devcontainer.json)
            exec_env_args=(
                --env DISPLAY="${DISPLAY:-:0}"
                --env WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
                --env XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
                --env COPT_USB_VID_PID="$VID_PID"
            )
            for env_kv in "${PREVIEW_ENV_ARGS[@]}"; do
                exec_env_args+=(--env "$env_kv")
            done
            setsid "$RUNTIME" exec \
                "${exec_env_args[@]}" \
                -it "$CONTAINER_ID" \
                sudo "${env_prefix[@]}" bash "$COPT_SCRIPT" "${COPT_ARGS[@]}" \
                2> >(tee -a "$tmplog" >&2) &
            CHILD_PID=$!
            CHILD_PGID=$CHILD_PID
            ;;
    esac
    wait "$CHILD_PID"
    exit_code=$?
    CHILD_PID=""
    CHILD_PGID=""
    set -e

    case $exit_code in
        0)
            ok "copt exited cleanly."
            info "Total runtime: $(($(date +%s) - start_time))s"
            exit 0
            ;;
        1)
            err "copt exited with a configuration error — not restarting."
            err "Check the output above for the root cause."
            exit 1
            ;;
        130|143)
            info "Interrupted by user — stopping."
            exit 0
            ;;
        *)
            warn "copt exited with code ${exit_code}"
            ;;
    esac

    # USB disconnect handling — re-resolve device in case index changed
    if grep -qiE "$USB_DISCONNECT_RE" "$tmplog" 2>/dev/null; then
        warn "USB disconnect detected — UGREEN 25173 USB-C instability"
        info "Hardware tip: replace USB-C cable / update BIOS / use USB 3.0 port"
        if wait_for_device "$VIDEO_DEV"; then
            new_dev=$(find_video_device "$VID_PID") || new_dev="$VIDEO_DEV"
            if [[ "$new_dev" != "$VIDEO_DEV" ]]; then
                warn "Device re-enumerated: ${VIDEO_DEV} → ${new_dev}"
                VIDEO_DEV="$new_dev"
                rebuild_args
            fi
        else
            err "Device did not reappear — aborting."; exit 1
        fi
    fi

    info "Waiting ${RESTART_DELAY}s before restart..."
    sleep "$RESTART_DELAY"
    echo ""
done

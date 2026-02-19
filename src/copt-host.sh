#!/usr/bin/env bash
# ============================================================================
# copt-host — launch copt for USB capture with autorestart
# ============================================================================
# Idempotent: works whether called from the HOST or from INSIDE a container.
#
# Execution mode (auto-detected, no flags required):
#
#   exec  — On the host: execs into the running devcontainer (DEFAULT).
#            Uses the container's FFmpeg (NVENC SDK 13.0), CUDA, and all
#            streaming tools. USB device must be in devcontainer.json runArgs.
#
#   local — Inside a devcontainer: runs copt.sh at its local path directly.
#
#   host  — Fallback when no container is running. Warns that NVENC/CUDA
#            support depends on what is installed on the host.
#
# Default stream: 4K 30fps HDR10 PQ → YouTube Live HLS
#   Profile : usb-capture-4k30-hdr
#   Device  : resolved by VID:PID 3188:1000 (no /dev/videoX index used)
#
# Setup (one-time, on the HOST):
#   sudo usermod -aG video $USER        # then log out / back in
#   sudo apt install v4l-utils          # v4l2-ctl for device discovery
#   cp copt-host.sh ~/bin/copt-host && chmod +x ~/bin/copt-host
#
# Usage:
#   copt-host --hls --hls-url https://... -y STREAM_KEY   # HDR stream
#   copt-host -o ~/capture.mkv                            # record to file
#   copt-host --dry-run -o /tmp/test.mkv                  # 5s test clip
#   copt-host --profile usb-capture-1080p30 -y KEY        # 1080p stable
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

USB_DISCONNECT_RE='Device.*disconnected|select timed out|Input/output error|No such device|failed to reset|double free'

# ============================================================================
# Helpers
# ============================================================================

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
    # Numbered to allow future devices: usb-video-capture2, etc.
    local n=1
    while [[ -e "/dev/usb-video-capture${n}" ]]; do
        # Match VID:PID to find the right numbered symlink
        local link_target real_dev real_vid real_pid
        link_target=$(readlink -f "/dev/usb-video-capture${n}" 2>/dev/null) || { n=$((n+1)); continue; }
        real_dev=$(basename "$link_target")
        real_vid=$(cat "/sys/class/video4linux/${real_dev}/device/../../../idVendor" 2>/dev/null | tr -d '\n')
        real_pid=$(cat "/sys/class/video4linux/${real_dev}/device/../../../idProduct" 2>/dev/null | tr -d '\n')
        local want_vid="${1%%:*}" want_pid="${1##*:}"
        if [[ "${real_vid,,}" == "${want_vid,,}" && "${real_pid,,}" == "${want_pid,,}" ]]; then
            echo "/dev/usb-video-capture${n}"; return 0
        fi
        n=$((n+1))
    done

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
echo "  copt-host — USB HDR capture launcher"
echo "  USB device : ${VID_PID}"
echo "  Profile    : ${DEFAULT_PROFILE} (override with --profile)"
echo ""

# ── Determine execution mode and resolve copt.sh path ────────────────────────
EXEC_MODE=""
RUNTIME=""
CONTAINER_ID=""
COPT_SCRIPT=""

if in_container; then
    # ── local: already inside the devcontainer — run copt.sh directly ─────────
    EXEC_MODE=local
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    COPT_SCRIPT="${SCRIPT_DIR}/copt.sh"
    [[ -f "$COPT_SCRIPT" ]] || die "copt.sh not found at: ${COPT_SCRIPT}"
    info "In-container mode — running copt.sh directly"
    ok "copt: ${COPT_SCRIPT}"
else
    # ── On the host — exec into devcontainer (bleeding-edge FFmpeg/CUDA/NVENC) ─
    # Container exec is always preferred: the devcontainer holds the compiled
    # FFmpeg (NVENC SDK 13.0), CUDA, and all streaming tools. Running on the
    # host directly would require duplicating all those installs there.
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
        for candidate in /workspaces/CST/copt/src/copt.sh /workspaces/copt/src/copt.sh; do
            if "$RUNTIME" exec "$CONTAINER_ID" test -f "$candidate" 2>/dev/null; then
                COPT_SCRIPT="$candidate"; break
            fi
        done
        [[ -n "$COPT_SCRIPT" ]] \
            || die "copt.sh not found in container. Expected: /workspaces/CST/copt/src/copt.sh"
        info "Container mode — running inside devcontainer (FFmpeg/NVENC/CUDA)"
        ok "copt (in container): ${COPT_SCRIPT}"
    else
        # Fallback: no container running — run directly on host
        warn "No devcontainer found — falling back to host-direct mode"
        warn "Start the VS Code devcontainer for full NVENC/CUDA support"
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        HOST_SCRIPT="${SCRIPT_DIR}/copt.sh"
        if [[ ! -f "$HOST_SCRIPT" ]]; then
            for candidate in \
                ~/PRO/WEB/CST/copt/src/copt.sh \
                /workspaces/CST/copt/src/copt.sh \
                /workspaces/copt/src/copt.sh
            do
                [[ -f "$candidate" ]] && { HOST_SCRIPT="$candidate"; break; }
            done
        fi
        [[ -f "$HOST_SCRIPT" ]] || die "copt.sh not found on host and no container running."
        EXEC_MODE=host
        COPT_SCRIPT="$HOST_SCRIPT"
        ok "copt (host fallback): ${COPT_SCRIPT}"
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
USER_ARGS=("$@")
has_profile=0
for _a in "${USER_ARGS[@]+"${USER_ARGS[@]}"}"; do
    [[ "$_a" == "--profile" ]] && { has_profile=1; break; }
done

rebuild_args() {
    BASE_ARGS=(--capture-mode usb --usb-device "$VIDEO_DEV" --usb-vid-pid "$VID_PID")
    [[ $has_profile -eq 0 ]] && BASE_ARGS+=(--profile "$DEFAULT_PROFILE")
    COPT_ARGS=("${BASE_ARGS[@]}" "${USER_ARGS[@]+"${USER_ARGS[@]}"}")
}
rebuild_args

# ── Autorestart loop ──────────────────────────────────────────────────────────
retry_count=0
start_time=$(date +%s)
tmplog=$(mktemp /tmp/copt-host-XXXXXX.log)
trap 'rm -f "$tmplog"' EXIT

info "Exec mode: ${EXEC_MODE}  |  autorestart: enabled  |  max: ${MAX_RETRIES:-infinite}"
echo ""

while true; do
    retry_count=$((retry_count + 1))
    if [[ $MAX_RETRIES -gt 0 && $retry_count -gt $MAX_RETRIES ]]; then
        err "Max retries (${MAX_RETRIES}) reached — giving up."; exit 1
    fi
    [[ $retry_count -eq 1 ]] && ok "Attempt #${retry_count}" \
                              || warn "Restart attempt #${retry_count}"
    : > "$tmplog"

    set +e
    case "$EXEC_MODE" in
        local)
            # Inside container already — run directly
            sudo bash "$COPT_SCRIPT" "${COPT_ARGS[@]}" \
                2> >(tee -a "$tmplog" >&2)
            ;;
        host)
            # On host — run directly (USB device natively visible)
            sudo bash "$COPT_SCRIPT" "${COPT_ARGS[@]}" \
                2> >(tee -a "$tmplog" >&2)
            ;;
        exec)
            # Exec into container (device must be in devcontainer.json)
            "$RUNTIME" exec \
                --env DISPLAY="${DISPLAY:-:0}" \
                --env WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
                --env XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
                --env COPT_USB_VID_PID="$VID_PID" \
                -it "$CONTAINER_ID" \
                sudo bash "$COPT_SCRIPT" "${COPT_ARGS[@]}" \
                2> >(tee -a "$tmplog" >&2)
            ;;
    esac
    exit_code=$?
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

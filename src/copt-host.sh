#!/usr/bin/env bash
# ============================================================================
# copt-host — Run copt from host for USB capture (UGREEN 25173 / 3188:1000)
# ============================================================================
# Runs ON THE HOST.  Designed for USB V4L2 capture — no DRI / KMS needed.
#
# Default mode: 4K 30fps HDR10 PQ → YouTube Live via HLS.
#   Profile: usb-capture-4k30-hdr
#   Device:  discovered by VID:PID (3188:1000) — no /dev/videoX index used.
#   Wraps copt with an autorestart loop so USB disconnects restart cleanly.
#
# Setup (one-time, on the HOST):
#   1. Add yourself to the video group (for /dev/videoX access):
#        sudo usermod -aG video $USER   # then log out / back in
#   2. Copy to PATH:
#        cp copt-host.sh ~/bin/copt-host && chmod +x ~/bin/copt-host
#   3. Install v4l2-ctl if not present (used for device discovery):
#        sudo apt install v4l-utils
#
# Usage:
#   # Stream HDR 4K to YouTube via HLS (default mode):
#   copt-host --hls --hls-url https://a.upload.youtube.com/http_upload_hls \
#             -y YOUR_STREAM_KEY
#
#   # Override profile (e.g. stable 1080p30 on USB 3.0 port):
#   copt-host --profile usb-capture-1080p30 -y YOUR_STREAM_KEY
#
#   # Record to file instead of streaming:
#   copt-host -o ~/capture.mkv
#
#   # Dry-run (print ffmpeg command, capture 5s test clip):
#   copt-host --dry-run -o /tmp/test.mkv
#
# Environment overrides:
#   COPT_USB_VID_PID   USB VID:PID  (default: 3188:1000)
#   COPT_CONTAINER     Container name/ID override
#   COPT_RESTART_DELAY Seconds between restarts (default: 5)
#   COPT_MAX_RETRIES   Max restart attempts, 0=infinite (default: 0)
#
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================

set -euo pipefail

# ── Colours ─────────────────────────────────────────────────────────────────
C_GRN='\033[0;32m' C_YEL='\033[0;33m' C_RED='\033[0;31m' C_CYN='\033[0;36m' C_RST='\033[0m'
ok()   { printf "${C_GRN}[OK]${C_RST}  %s\n" "$*"; }
warn() { printf "${C_YEL}[!!]${C_RST}  %s\n" "$*"; }
err()  { printf "${C_RED}[ERR]${C_RST} %s\n" "$*"; }
info() { printf "[${C_CYN}INFO${C_RST}] %s\n" "$*"; }
die()  { err "$@"; exit 1; }

# ── Config ───────────────────────────────────────────────────────────────────
VID_PID="${COPT_USB_VID_PID:-3188:1000}"
RESTART_DELAY="${COPT_RESTART_DELAY:-5}"
MAX_RETRIES="${COPT_MAX_RETRIES:-0}"          # 0 = infinite
DEFAULT_PROFILE="usb-capture-4k30-hdr"

# ── Disconnect log patterns (same set as lib/usb-reconnect.sh) ───────────────
USB_DISCONNECT_RE='Device.*disconnected|select timed out|Input/output error|No such device|failed to reset|double free'

# ============================================================================
# 1. Find the devcontainer (supports both podman and docker, and CST workspace)
# ============================================================================
find_container() {
    local cid=""
    local runtime

    # Prefer podman, fall back to docker
    for runtime in podman docker; do
        command -v "$runtime" &>/dev/null || continue

        # Try devcontainer label first
        cid=$("$runtime" ps \
            --filter "label=devcontainer.local_folder" \
            --format "{{.ID}}" 2>/dev/null | head -1) || true

        # Try by workspace path (handles both /workspaces/CST and /workspaces/copt)
        if [[ -z "$cid" ]]; then
            while IFS= read -r id; do
                if "$runtime" inspect "$id" 2>/dev/null \
                        | grep -qE '"(/workspaces/CST|/workspaces/copt)"'; then
                    cid="$id"
                    break
                fi
            done < <("$runtime" ps --format "{{.ID}}" 2>/dev/null)
        fi

        if [[ -n "$cid" ]]; then
            echo "$runtime:$cid"
            return 0
        fi
    done
    return 1
}

# ============================================================================
# 2. Resolve /dev/videoX from VID:PID — no index hardcoding
# ============================================================================
find_video_device() {
    local vid="${1%%:*}"
    local pid="${1##*:}"

    # Walk sysfs: match idVendor / idProduct, then find the video child node
    local sys_dev
    for sys_dev in /sys/bus/usb/devices/*/; do
        local v p
        v=$(cat "${sys_dev}idVendor"  2>/dev/null) || continue
        p=$(cat "${sys_dev}idProduct" 2>/dev/null) || continue
        if [[ "${v,,}" == "${vid,,}" && "${p,,}" == "${pid,,}" ]]; then
            # Find descendant video node
            local node
            node=$(find "$sys_dev" -maxdepth 6 -name "video[0-9]*" \
                       -path "*/video4linux/*" 2>/dev/null \
                   | head -1 | xargs -r basename)
            if [[ -n "$node" && -e "/dev/$node" ]]; then
                echo "/dev/$node"
                return 0
            fi
        fi
    done

    # Fallback: v4l2-ctl
    if command -v v4l2-ctl &>/dev/null; then
        local node
        node=$(v4l2-ctl --list-devices 2>/dev/null \
               | awk '/UGREEN|ITE|25173|'"${vid}"'/{found=1} found && /\/dev\/video/{print $1; exit}')
        if [[ -n "$node" && -e "$node" ]]; then
            echo "$node"
            return 0
        fi
    fi

    return 1
}

# ============================================================================
# 3. Wait for USB device to reappear
# ============================================================================
wait_for_device() {
    local dev="$1"
    local timeout="${COPT_USB_RECONNECT_TIMEOUT:-120}"
    local elapsed=0
    warn "Waiting up to ${timeout}s for ${dev} (${VID_PID}) to reappear..."
    while [[ $elapsed -lt $timeout ]]; do
        # Device node + USB bus presence
        if [[ -e "$dev" ]] && lsusb 2>/dev/null | grep -qi "$VID_PID"; then
            sleep "${COPT_USB_SETTLE_DELAY:-2}"
            ok "${dev} ready after ${elapsed}s"
            return 0
        fi
        sleep 2; elapsed=$((elapsed + 2))
    done
    err "${dev} did not reappear within ${timeout}s"
    return 1
}

# ============================================================================
# Main
# ============================================================================
echo ""
echo "  copt-host — USB HDR capture launcher"
echo "  USB device : ${VID_PID}"
echo "  Profile    : ${DEFAULT_PROFILE} (override with --profile)"
echo ""

# ── Find container ──────────────────────────────────────────────────────────
info "Locating devcontainer..."
CONTAINER_RAW="${COPT_CONTAINER:-}"
if [[ -z "$CONTAINER_RAW" ]]; then
    CONTAINER_RAW=$(find_container) || die "No devcontainer found. Start VS Code devcontainer first."
fi
RUNTIME="${CONTAINER_RAW%%:*}"
CONTAINER_ID="${CONTAINER_RAW##*:}"
ok "Container: ${CONTAINER_ID} (via ${RUNTIME})"

# Resolve copt path inside container
COPT_SCRIPT_IN_CONTAINER=""
for candidate in \
    /workspaces/CST/copt/src/copt.sh \
    /workspaces/copt/src/copt.sh; do
    if "$RUNTIME" exec "$CONTAINER_ID" test -f "$candidate" 2>/dev/null; then
        COPT_SCRIPT_IN_CONTAINER="$candidate"
        break
    fi
done
[[ -n "$COPT_SCRIPT_IN_CONTAINER" ]] \
    || die "copt.sh not found in container. Expected at /workspaces/CST/copt/src/copt.sh"
ok "copt: ${COPT_SCRIPT_IN_CONTAINER}"

# ── Resolve USB video device ─────────────────────────────────────────────────
info "Looking for USB device ${VID_PID}..."
if ! lsusb 2>/dev/null | grep -qi "$VID_PID"; then
    die "USB device ${VID_PID} not found on bus. Is UGREEN 25173 plugged in?"
fi
VIDEO_DEV=$(find_video_device "$VID_PID") \
    || die "No /dev/videoX found for ${VID_PID}. Try: v4l2-ctl --list-devices"
ok "Video device: ${VIDEO_DEV}"

# Check host access
[[ -r "$VIDEO_DEV" ]] \
    || die "Cannot read ${VIDEO_DEV}. Add user to video group:\n  sudo usermod -aG video \$USER\n  (then log out and back in)"

# ── Build copt invocation ────────────────────────────────────────────────────
# Inject VID:PID and resolved device; user args override everything after.
# Default profile is usb-capture-4k30-hdr; user can pass --profile to change.
USER_ARGS=("$@")

# Check if user passed --profile; if not, prepend the default
has_profile=0
for arg in "${USER_ARGS[@]+"${USER_ARGS[@]}"}"; do
    [[ "$arg" == "--profile" ]] && { has_profile=1; break; }
done

BASE_ARGS=(
    --capture-mode usb
    --usb-device   "$VIDEO_DEV"
    --usb-vid-pid  "$VID_PID"
)
[[ $has_profile -eq 0 ]] && BASE_ARGS+=(--profile "$DEFAULT_PROFILE")

COPT_ARGS=("${BASE_ARGS[@]}" "${USER_ARGS[@]+"${USER_ARGS[@]}"}")

# ── Autorestart loop ─────────────────────────────────────────────────────────
retry_count=0
start_time=$(date +%s)
tmplog=$(mktemp /tmp/copt-host-XXXXXX.log)
trap 'rm -f "$tmplog"' EXIT

info "Starting copt (autorestart enabled, max=${MAX_RETRIES:-infinite})..."
echo ""

while true; do
    retry_count=$((retry_count + 1))

    if [[ $MAX_RETRIES -gt 0 && $retry_count -gt $MAX_RETRIES ]]; then
        err "Max retries (${MAX_RETRIES}) reached — giving up."
        exit 1
    fi

    if [[ $retry_count -eq 1 ]]; then
        ok "Attempt #${retry_count}"
    else
        warn "Restart attempt #${retry_count}"
    fi

    : > "$tmplog"

    set +e
    "$RUNTIME" exec \
        --env DISPLAY="${DISPLAY:-:0}" \
        --env WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
        --env XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
        --env COPT_USB_VID_PID="$VID_PID" \
        -it \
        "$CONTAINER_ID" \
        sudo bash "$COPT_SCRIPT_IN_CONTAINER" "${COPT_ARGS[@]}" \
        2> >(tee -a "$tmplog" >&2)
    exit_code=$?
    set -e

    # ── Exit code handling ────────────────────────────────────────────────
    case $exit_code in
        0)
            ok "copt exited cleanly."
            info "Total runtime: $(($(date +%s) - start_time))s"
            exit 0
            ;;
        1)
            # Exit 1 from copt = configuration / startup error (bad profile,
            # missing device, ffmpeg not found, etc.) — not a transient crash.
            # Don't loop; surface the error immediately.
            err "copt exited with a configuration error (exit 1) — not restarting."
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

    # ── USB disconnect? ───────────────────────────────────────────────────
    if grep -qiE "$USB_DISCONNECT_RE" "$tmplog" 2>/dev/null; then
        warn "USB disconnect pattern detected in output"
        warn "Known issue: UGREEN 25173 USB-C bus instability (ASRock controller)"
        info "Hardware tip: replace USB-C cable / update BIOS / use USB 3.0 port"

        # Re-resolve device node (it may get a new index after re-enumeration)
        info "Waiting for device to reappear..."
        if wait_for_device "$VIDEO_DEV"; then
            # Re-check node — kernel may assign a new index
            new_dev=$(find_video_device "$VID_PID") || new_dev="$VIDEO_DEV"
            if [[ "$new_dev" != "$VIDEO_DEV" ]]; then
                warn "Device re-enumerated as ${new_dev} (was ${VIDEO_DEV})"
                VIDEO_DEV="$new_dev"
                # Update the --usb-device in COPT_ARGS
                COPT_ARGS=("${BASE_ARGS[@]/"--usb-device"*}" \
                    --usb-device "$VIDEO_DEV" \
                    "${USER_ARGS[@]+"${USER_ARGS[@]}"}")
                # Rebuild cleanly
                BASE_ARGS=(
                    --capture-mode usb
                    --usb-device   "$VIDEO_DEV"
                    --usb-vid-pid  "$VID_PID"
                )
                [[ $has_profile -eq 0 ]] && BASE_ARGS+=(--profile "$DEFAULT_PROFILE")
                COPT_ARGS=("${BASE_ARGS[@]}" "${USER_ARGS[@]+"${USER_ARGS[@]}"}")
            fi
        else
            err "Device did not reappear — aborting."
            exit 1
        fi
    fi

    info "Waiting ${RESTART_DELAY}s before restart..."
    sleep "$RESTART_DELAY"
    echo ""
done

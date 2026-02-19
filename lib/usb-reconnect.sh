#!/usr/bin/env bash
# ============================================================================
# copt — USB capture device reconnect logic
# ============================================================================
# Handles UGREEN 25173 (3188:1000) class USB capture device instability:
# the device physically disconnects from the USB-C bus after 7-13 minutes,
# causing FFmpeg to exit with "Device /dev/videoX disconnected".
#
# Strategy: run FFmpeg in the foreground while a log monitor runs in the
# background. On a detected USB disconnect we kill FFmpeg, wait for the
# device to re-enumerate on the bus, then re-launch with the same command.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================

# ----- error patterns that indicate a USB bus disconnect --------------------
# (case-insensitive grep -E extended regexes)
readonly USB_DISCONNECT_PATTERNS=(
    'Device[[:space:]]+/dev/video[0-9]+[[:space:]]+disconnected'
    'select[[:space:]]+timed[[:space:]]+out'
    'Input/output error'
    'No[[:space:]]+such[[:space:]]+device'
    'failed[[:space:]]+to[[:space:]]+reset'
    'double[[:space:]]+free[[:space:]]+or[[:space:]]+corruption'
)

# Build a single grep pattern from the array
_usb_disconnect_regex() {
    local IFS='|'
    echo "${USB_DISCONNECT_PATTERNS[*]}"
}

# ----- detect /dev/videoX path for a USB VID:PID ----------------------------
# Usage: detect_usb_capture_device [VID:PID]
# Sets COPT_USB_DEVICE  (or leaves the existing value untouched if already set)
detect_usb_capture_device() {
    local vid_pid="${1:-${COPT_USB_VID_PID:-}}"

    # If the user already specified a device path, validate it and return.
    if [[ -n "${COPT_USB_DEVICE:-}" ]]; then
        if [[ -e "$COPT_USB_DEVICE" ]]; then
            ok "Using USB capture device: $COPT_USB_DEVICE"
            return 0
        else
            die "USB capture device not found: $COPT_USB_DEVICE"
        fi
    fi

    # Try to match VID:PID via udev / sysfs
    if [[ -n "$vid_pid" ]]; then
        local vid pid
        vid="${vid_pid%%:*}"
        pid="${vid_pid##*:}"

        # Walk /sys/bus/usb/devices looking for idVendor/idProduct match
        local sys_dev
        for sys_dev in /sys/bus/usb/devices/*/; do
            local v p
            v=$(cat "${sys_dev}idVendor" 2>/dev/null | tr '[:upper:]' '[:lower:]') || continue
            p=$(cat "${sys_dev}idProduct" 2>/dev/null | tr '[:upper:]' '[:lower:]') || continue
            if [[ "$v" == "${vid,,}" && "$p" == "${pid,,}" ]]; then
                # Found the USB device.  Now find the video node beneath it.
                local video_node
                video_node=$(find "$sys_dev" -name "video0" -o -name "video[0-9]" 2>/dev/null \
                    | head -1 | xargs -I{} basename {} 2>/dev/null) || true
                if [[ -z "$video_node" ]]; then
                    # Try v4l-subdev path
                    video_node=$(ls /dev/video* 2>/dev/null | head -1 | xargs basename 2>/dev/null) || true
                fi
                if [[ -n "$video_node" && -e "/dev/${video_node}" ]]; then
                    COPT_USB_DEVICE="/dev/${video_node}"
                    ok "USB capture device ${vid_pid} → ${COPT_USB_DEVICE}"
                    return 0
                fi
            fi
        done

        # Fallback: v4l2-ctl enumeration (if available)
        if command -v v4l2-ctl &>/dev/null; then
            local v4l_out
            v4l_out=$(v4l2-ctl --list-devices 2>/dev/null || true)
            # Look for any /dev/videoX that comes after a line matching our device
            # (v4l2-ctl groups devices with their paths)
            local found_dev
            found_dev=$(echo "$v4l_out" | awk '/UGREEN|25173|'"${vid_pid}"'/{found=1} found && /\/dev\/video/{print $1; exit}')
            if [[ -n "$found_dev" && -e "$found_dev" ]]; then
                COPT_USB_DEVICE="$found_dev"
                ok "USB capture device ${vid_pid} → ${COPT_USB_DEVICE} (via v4l2-ctl)"
                return 0
            fi
        fi

        warn "Could not locate /dev/videoX for USB device ${vid_pid}"
    fi

    # Generic fallback: use first available /dev/videoX
    local first_video
    first_video=$(ls /dev/video[0-9]* 2>/dev/null | head -1) || true
    if [[ -n "$first_video" ]]; then
        COPT_USB_DEVICE="$first_video"
        warn "No USB VID:PID specified or matched; using first video device: $COPT_USB_DEVICE"
        return 0
    fi

    die "No V4L2 video device found. Is the USB capture device plugged in?"
}

# ----- wait until the USB capture device is back on the bus -----------------
# Usage: wait_usb_device_ready  DEVICE_PATH  [VID:PID]  [TIMEOUT_SECONDS]
# Returns 0 when ready, 1 on timeout.
wait_usb_device_ready() {
    local dev="$1"
    local vid_pid="${2:-${COPT_USB_VID_PID:-}}"
    local timeout="${3:-${COPT_USB_RECONNECT_TIMEOUT:-120}}"
    local elapsed=0

    warn "USB device lost — waiting up to ${timeout}s for it to reappear..."

    while [[ $elapsed -lt $timeout ]]; do
        # 1. Device node must exist
        if [[ ! -e "$dev" ]]; then
            sleep 1; elapsed=$((elapsed + 1)); continue
        fi

        # 2. If we have a VID:PID, confirm the USB bus enumeration
        if [[ -n "$vid_pid" ]]; then
            if ! lsusb 2>/dev/null | grep -qi "$vid_pid"; then
                sleep 1; elapsed=$((elapsed + 1)); continue
            fi
        fi

        # 3. Attempt a v4l2 capability probe to ensure the driver is settled
        if command -v v4l2-ctl &>/dev/null; then
            if ! v4l2-ctl --device="$dev" --info &>/dev/null; then
                sleep 1; elapsed=$((elapsed + 1)); continue
            fi
        fi

        ok "USB device ${dev} ready after ${elapsed}s"
        # Brief settle pause so the kernel driver finishes init
        sleep "${COPT_USB_SETTLE_DELAY:-2}"
        return 0
    done

    err "USB device ${dev} did not reappear within ${timeout}s"
    return 1
}

# ----- check whether a log file contains a USB disconnect signature ---------
_log_has_disconnect() {
    local logfile="$1"
    [[ -f "$logfile" ]] || return 1
    grep -qiE "$(_usb_disconnect_regex)" "$logfile" 2>/dev/null
}

# ----- main reconnect loop --------------------------------------------------
# Usage: run_with_usb_reconnect
#   Uses globals: FFMPEG_CMD (array), COPT_USB_DEVICE, COPT_USB_VID_PID
#   COPT_USB_MAX_RECONNECTS (0 = infinite), COPT_USB_RECONNECT_DELAY
run_with_usb_reconnect() {
    local max_reconnects="${COPT_USB_MAX_RECONNECTS:-0}"   # 0 = infinite
    local reconnect_delay="${COPT_USB_RECONNECT_DELAY:-5}" # seconds before relaunch
    local reconnect_count=0
    local tmplog

    tmplog=$(mktemp /tmp/copt-usb-XXXXXX.log)
    # ensure cleanup on exit
    # shellcheck disable=SC2064
    trap "rm -f '$tmplog'" EXIT

    while true; do
        reconnect_count=$((reconnect_count + 1))

        if [[ $max_reconnects -gt 0 && $reconnect_count -gt $max_reconnects ]]; then
            err "Maximum USB reconnect attempts ($max_reconnects) reached — giving up."
            rm -f "$tmplog"
            return 1
        fi

        if [[ $reconnect_count -gt 1 ]]; then
            warn "USB reconnect attempt #$((reconnect_count - 1))"
        else
            info "Starting USB capture (reconnect enabled)"
        fi

        # Truncate the log for this run
        : > "$tmplog"

        # Run FFmpeg; stderr goes to both the terminal and the temp log
        set +e
        "${FFMPEG_CMD[@]}" 2> >(tee -a "$tmplog" >&2)
        local rc=$?
        set -e

        # Immediate user interrupt — exit cleanly
        if [[ $rc -eq 130 || $rc -eq 143 ]]; then
            info "Capture interrupted (signal)."
            rm -f "$tmplog"
            return 0
        fi

        # Clean exit (unlikely mid-stream but handle it)
        if [[ $rc -eq 0 ]]; then
            rm -f "$tmplog"
            return 0
        fi

        # Decide whether this was a USB disconnect or another kind of crash
        if _log_has_disconnect "$tmplog"; then
            warn "USB capture device disconnected (exit code: $rc)"
            warn "This is the known UGREEN 25173 USB-C instability issue."
            info "Hardware tip: replace USB-C cable / try USB 3.0 back port / update BIOS."

            if wait_usb_device_ready \
                    "${COPT_USB_DEVICE:-/dev/video0}" \
                    "${COPT_USB_VID_PID:-}" \
                    "${COPT_USB_RECONNECT_TIMEOUT:-120}"; then
                info "Waiting ${reconnect_delay}s before restarting capture…"
                sleep "$reconnect_delay"
                continue   # restart the while loop → re-invoke FFmpeg
            else
                err "Device did not come back — aborting."
                rm -f "$tmplog"
                return 1
            fi
        fi

        # Non-disconnect crash
        warn "FFmpeg exited with code $rc (not identified as a USB disconnect)"
        rm -f "$tmplog"
        return $rc
    done
}

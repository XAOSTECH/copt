#!/usr/bin/env bash
# ============================================================================
# copt-preview — Live preview window for copt streams
# ============================================================================
# Displays a real-time preview window of the encoding stream using ffplay.
# Can be started/stopped independently without affecting the main stream.
#
# Usage:
#   copt-preview start [OPTIONS]   # Launch preview window
#   copt-preview stop              # Close preview window
#   copt-preview restart [OPTIONS] # Restart preview window
#   copt-preview status            # Check if preview is running
#
# OPTIONS:
#   --device PATH         V4L2 device to preview (default: /dev/usb-video-capture1)
#   --size WxH            Preview window size (default: 1280x720)
#   --fullscreen          Open in fullscreen mode
#   --alwaysontop         Keep window on top
#
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================

set -euo pipefail

# Detect copt installation location
if [[ -n "${COPT_ROOT:-}" ]]; then
    # Already set (e.g., by copt-host)
    :
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/../lib/colours.sh" ]]; then
    # Running from source tree
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    COPT_ROOT="$(dirname "$SCRIPT_DIR")"
elif [[ -f "${HOME}/PRO/WEB/CST/copt/lib/colours.sh" ]]; then
    # Installed to ~/bin, use known copt location
    COPT_ROOT="${HOME}/PRO/WEB/CST/copt"
elif [[ -f "/usr/local/share/copt/lib/colours.sh" ]]; then
    # System-wide install
    COPT_ROOT="/usr/local/share/copt"
else
    echo "ERROR: Could not find copt installation" >&2
    echo "Set COPT_ROOT environment variable to copt directory" >&2
    exit 1
fi

readonly COPT_ROOT
readonly COPT_LIB="${COPT_ROOT}/lib"

# shellcheck source=../lib/colours.sh
source "${COPT_LIB}/colours.sh"

# PID file location
readonly PID_FILE="/tmp/copt-preview.pid"

# Default options
PREVIEW_DEVICE="/dev/usb-video-capture1"
PREVIEW_SOURCE=""
PREVIEW_SIZE="1280x720"
PREVIEW_FULLSCREEN=0
PREVIEW_ALWAYSONTOP=0

# ----- functions ------------------------------------------------------------

usage() {
    cat <<EOF
${C_BLD}copt-preview${C_RST} — Live preview window for copt streams

${C_BLD}USAGE${C_RST}
    copt-preview start [OPTIONS]   # Launch preview window
    copt-preview stop              # Close preview window
    copt-preview restart [OPTIONS] # Restart preview
    copt-preview status            # Check preview status

${C_BLD}OPTIONS${C_RST}
    --device PATH         V4L2 device (default: /dev/usb-video-capture1)
    --source URL          Stream source (udp://..., rtmp://..., file)
    --size WxH            Window size (default: 1280x720)
    --fullscreen          Open fullscreen
    --alwaysontop         Keep window on top
    --help                Show this help

${C_BLD}EXAMPLES${C_RST}
    # Start preview of USB capture device
    copt-preview start

    # Start preview from stream source (no device grab)
    copt-preview start --source udp://127.0.0.1:11000

    # Start with custom size
    copt-preview start --size 1920x1080

    # Fullscreen preview
    copt-preview start --fullscreen

    # Stop preview
    copt-preview stop

${C_BLD}NOTES${C_RST}
    - Preview runs independently from main capture/stream
    - Can be closed/reopened without affecting stream
    - Minimal performance impact (direct V4L2 read or stream read)
    - Press 'q' or ESC in preview window to close

EOF
}

is_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        else
            # Stale PID file
            rm -f "$PID_FILE"
            return 1
        fi
    fi
    return 1
}

start_preview() {
    if is_running; then
        warn "Preview already running (PID: $(cat "$PID_FILE"))"
        info "Use 'copt-preview stop' first, or 'copt-preview restart'"
        exit 1
    fi

    # Check if device exists (when using device mode)
    if [[ -z "$PREVIEW_SOURCE" && ! -e "$PREVIEW_DEVICE" ]]; then
        die "Device not found: $PREVIEW_DEVICE"
    fi

    # Check if ffplay is available
    if ! command -v ffplay &>/dev/null; then
        die "ffplay not found. Install: sudo apt install ffmpeg"
    fi

    # Check if DISPLAY is set (X11/Wayland)
    if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
        warn "No DISPLAY or WAYLAND_DISPLAY environment variable set"
        info "This may prevent the preview window from appearing"
    fi

    # Parse size
    local width height
    if [[ "$PREVIEW_SIZE" =~ ^([0-9]+)x([0-9]+)$ ]]; then
        width="${BASH_REMATCH[1]}"
        height="${BASH_REMATCH[2]}"
    else
        die "Invalid size format: $PREVIEW_SIZE (use WIDTHxHEIGHT)"
    fi

    if [[ -n "$PREVIEW_SOURCE" ]]; then
        info "Starting preview: $PREVIEW_SOURCE @ $PREVIEW_SIZE"
    else
        info "Starting preview: $PREVIEW_DEVICE @ $PREVIEW_SIZE"
    fi

    # Build ffplay command
    local ffplay_opts=()
    if [[ -n "$PREVIEW_SOURCE" ]]; then
        ffplay_opts+=(
            -fflags nobuffer
            -flags low_delay
            -probesize 32
            -analyzeduration 0
            -i "$PREVIEW_SOURCE"
        )
    else
        ffplay_opts+=(
            -f v4l2
            -input_format nv12
            -video_size 3840x2160
            -framerate 30
            -i "$PREVIEW_DEVICE"
        )
    fi

    # Window options
    if [[ -n "$PREVIEW_SOURCE" ]]; then
        ffplay_opts+=(-window_title "copt preview — stream")
    else
        ffplay_opts+=(-window_title "copt preview — $PREVIEW_DEVICE")
    fi
    
    if [[ "$PREVIEW_FULLSCREEN" -eq 1 ]]; then
        ffplay_opts+=(-fs)
    else
        ffplay_opts+=(-x "$width" -y "$height")
    fi

    if [[ "$PREVIEW_ALWAYSONTOP" -eq 1 ]]; then
        ffplay_opts+=(-alwaysontop)
    fi

    # Quality options
    ffplay_opts+=(
        -noborder
        -autoexit
        -fast
        -sync video
        -vf "scale=${width}:${height}:flags=fast_bilinear"
    )

    # Launch in background
    info "Command: ffplay ${ffplay_opts[*]}"
    
    # Ensure display environment is set
    export DISPLAY="${DISPLAY:-:0}"
    export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
    
    # SDL video driver selection (Wayland first, then X11)
    if [[ -n "${WAYLAND_DISPLAY}" ]] && [[ -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]]; then
        export SDL_VIDEODRIVER=wayland
    else
        export SDL_VIDEODRIVER=x11
    fi
    
    # SDL hints for ffplay window behaviour
    export SDL_VIDEO_ALLOW_SCREENSAVER=1
    
    info "Using SDL_VIDEODRIVER=${SDL_VIDEODRIVER}"
    
    # Run with display server access (redirect stdin to prevent blocking)
    ffplay "${ffplay_opts[@]}" </dev/null &>/tmp/copt-preview.log &
    local pid=$!

    # Give it a moment to start
    sleep 0.5

    # Check if still running
    if kill -0 "$pid" 2>/dev/null; then
        echo "$pid" > "$PID_FILE"
        ok "Preview started (PID: $pid)"
        info "Press 'q' or ESC in preview window to close"
        info "Or run: copt-preview stop"
        
        # Wait a moment to see if window opens
        sleep 1
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            die "Preview exited immediately. Check log: tail /tmp/copt-preview.log"
        fi
    else
        cat /tmp/copt-preview.log
        die "Preview failed to start. Check log above"
    fi
}

stop_preview() {
    if ! is_running; then
        warn "Preview not running"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")
    info "Stopping preview (PID: $pid)"
    
    if kill "$pid" 2>/dev/null; then
        # Wait for graceful shutdown
        local count=0
        while kill -0 "$pid" 2>/dev/null && [[ $count -lt 10 ]]; do
            sleep 0.1
            ((count++)) || true
        done

        # Force kill if still running
        if kill -0 "$pid" 2>/dev/null; then
            warn "Forcing kill..."
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi

    rm -f "$PID_FILE"
    ok "Preview stopped"
}

restart_preview() {
    info "Restarting preview..."
    stop_preview
    sleep 0.5
    start_preview
}

show_status() {
    if is_running; then
        local pid
        pid=$(cat "$PID_FILE")
        ok "Preview running (PID: $pid)"
        if [[ -n "$PREVIEW_SOURCE" ]]; then
            info "Source: $PREVIEW_SOURCE"
        else
            info "Device: $PREVIEW_DEVICE"
        fi
        
        # Show process info
        if ps -p "$pid" -o comm=,args= 2>/dev/null | grep -q ffplay; then
            info "Process: $(ps -p "$pid" -o args= 2>/dev/null | head -c 80)"
        fi
        exit 0
    else
        warn "Preview not running"
        exit 1
    fi
}

# ----- main -----------------------------------------------------------------

main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    local action="$1"
    shift

    # Parse options for start/restart
    if [[ "$action" == "start" || "$action" == "restart" ]]; then
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --device)
                    PREVIEW_DEVICE="$2"
                    shift 2
                    ;;
                --size)
                    PREVIEW_SIZE="$2"
                    shift 2
                    ;;
                --source)
                    PREVIEW_SOURCE="$2"
                    shift 2
                    ;;
                --fullscreen)
                    PREVIEW_FULLSCREEN=1
                    shift
                    ;;
                --alwaysontop)
                    PREVIEW_ALWAYSONTOP=1
                    shift
                    ;;
                --help)
                    usage
                    exit 0
                    ;;
                *)
                    die "Unknown option: $1"
                    ;;
            esac
        done
    fi

    case "$action" in
        start)
            start_preview
            ;;
        stop)
            stop_preview
            ;;
        restart)
            restart_preview
            ;;
        status)
            show_status
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "Unknown action: $action (use: start|stop|restart|status|--help)"
            ;;
    esac
}

main "$@"

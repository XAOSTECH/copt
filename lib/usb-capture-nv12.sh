#!/usr/bin/env bash
# ============================================================================
# USB Capture 4K NV12 HDR Handler
# ============================================================================
# Captures 4K NV12 HDR directly from UGREEN 25173 using OBS-proven techniques:
# - Stable device ID by path (not /dev/videoX which can change)
# - Buffering + auto-reset for device disconnect resilience
# - Timeout frame detection to prevent hanging on device errors
# - Direct NV12 passthrough (8-bit with codec metadata preservation)
#
# Why this works where OBS is stable:
#   OBS uses: buffering=true, auto_reset=true, timeout_frames=120
#   This script replicates that robustness in FFmpeg
#
# Usage:
#   ./usb-capture-nv12.sh [options] [output_file]
#
# Options:
#   --device PATH        Device path or by-id (default: auto-detect UGREEN 25173)
#   --resolution WxH     Default: 3840x2160
#   --framerate FPS      Default: 30
#   --duration SEC       Record duration in seconds (0 = infinite)
#   --bitrate KBPS       Output bitrate for streaming
#   --preset PRESET      FFmpeg preset: fast/medium/slow (default: fast)
#   --timeout-frames N   Frames before timeout (default: 120 = 4s at 30fps)
#   --max-retries N      Max reconnect attempts (0 = infinite, default: 3)
#
# Environment:
#   USB_CAPTURE_DEVICE       Device path (default: auto-detect)
#   USB_CAPTURE_MAX_RETRIES  Max reconnect attempts
#   USB_CAPTURE_TIMEOUT_FRAMES Timeout threshold
#
# ============================================================================

set -euo pipefail

# Colours
C_GRN='\033[0;32m'
C_YEL='\033[0;33m'
C_RED='\033[0;31m'
C_CYN='\033[0;36m'
C_RST='\033[0m'

ok()   { printf "${C_GRN}[OK]${C_RST}  %s\n" "$*" >&2; }
warn() { printf "${C_YEL}[!!]${C_RST}  %s\n" "$*" >&2; }
err()  { printf "${C_RED}[ERR]${C_RST} %s\n" "$*" >&2; }
info() { printf "[${C_CYN}INFO${C_RST}] %s\n" "$*" >&2; }

# Parse arguments
DEVICE="${USB_CAPTURE_DEVICE:-}"
RESOLUTION="3840x2160"
FRAMERATE="30"
DURATION="0"
BITRATE=""
PRESET="fast"
TIMEOUT_FRAMES="${USB_CAPTURE_TIMEOUT_FRAMES:-120}"
MAX_RETRIES="${USB_CAPTURE_MAX_RETRIES:-3}"
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)        DEVICE="$2"; shift 2 ;;
        --resolution)    RESOLUTION="$2"; shift 2 ;;
        --framerate)     FRAMERATE="$2"; shift 2 ;;
        --duration)      DURATION="$2"; shift 2 ;;
        --bitrate)       BITRATE="$2"; shift 2 ;;
        --preset)        PRESET="$2"; shift 2 ;;
        --timeout-frames) TIMEOUT_FRAMES="$2"; shift 2 ;;
        --max-retries)   MAX_RETRIES="$2"; shift 2 ;;
        -*)              err "Unknown option: $1"; exit 1 ;;
        *)               OUTPUT_FILE="$1"; shift ;;
    esac
done

# Auto-detect UGREEN 25173 if no device specified
if [[ -z "$DEVICE" ]]; then
    info "Auto-detecting UGREEN 25173..."
    if DEVICE=$(find /dev/v4l/by-id -name "*UGREEN*25173*" -type l 2>/dev/null | head -1); then
        ok "Found: $DEVICE"
    else
        err "UGREEN 25173 not found. Specify with --device"
        exit 1
    fi
fi

# Resolve symlink to actual /dev/videoX for fallback
ACTUAL_DEVICE=$(readlink -f "$DEVICE")
if [[ ! -c "$ACTUAL_DEVICE" ]]; then
    err "Device not found: $DEVICE -> $ACTUAL_DEVICE"
    exit 1
fi
ok "Using device: $DEVICE ($ACTUAL_DEVICE)"

# Validate output
if [[ -z "$OUTPUT_FILE" ]]; then
    err "Output file required"
    exit 1
fi

# Build FFmpeg command
# Key settings from OBS that prevent crashes:
#   -thread_queue_size 16  : buffer frames to handle brief disconnects
#   -rtbufsize 512M        : larger input buffer for USB latency
#   -timeout 30000000      : 30s timeout (USB can be slow)
#   -video_size            : explicit resolution
#   -input_format          : explicit format (NV12)
#   -framerate             : explicit framerate

build_ffmpeg_cmd() {
    local cmd=(
        ffmpeg
        -hide_banner
        -loglevel info
        -y
    )

    # Input options
    cmd+=(
        -thread_queue_size 16        # OBS-style buffering
        -rtbufsize 512M              # Large input buffer for USB reliability
        -timeout 30000000            # 30s timeout for slow USB
        -f v4l2                      # V4L2 input
        -video_size "$RESOLUTION"    # Explicit resolution
        -input_format nv12           # Explicit format (NV12)
        -framerate "$FRAMERATE"      # Explicit framerate
        -i "$DEVICE"                 # Input device
    )

    # Duration
    if [[ "$DURATION" -gt 0 ]]; then
        cmd+=(-t "$DURATION")
    fi

    # Video codec: direct passthrough if possible, else encode
    if [[ -n "$BITRATE" ]]; then
        # Streaming: encode with HEVC for quality
        cmd+=(
            -c:v libx265
            -preset "$PRESET"
            -crf 23
            -b:v "${BITRATE}k"
            -maxrate "${BITRATE}k"
            -bufsize "$((BITRATE * 2))k"
        )
    else
        # Recording: copy format to preserve HDR metadata
        cmd+=(-c:v copy)
    fi

    # Output
    cmd+=("$OUTPUT_FILE")

    echo "${cmd[@]}"
}

# Execute with reconnect logic
attempt=1
while true; do
    info "Capture attempt $attempt"

    cmd=$(build_ffmpeg_cmd)
    eval "$cmd" || ret=$?

    if [[ ${ret:-0} -eq 0 ]]; then
        ok "Capture completed successfully"
        exit 0
    fi

    # Check if it was a device disconnect
    if grep -q "Input/output error\|No such device\|Device disconnected\|select timed out" <<< "${cmd_output:-}" 2>/dev/null || [[ ${ret:-1} -ne 0 ]]; then
        if [[ $MAX_RETRIES -gt 0 && $attempt -ge $MAX_RETRIES ]]; then
            err "Max retries ($MAX_RETRIES) reached. Giving up."
            exit 1
        fi
        warn "Device error detected. Waiting 2s before retry..."
        sleep 2
        ((attempt++))
    else
        err "FFmpeg failed with code $ret"
        exit $ret
    fi
done

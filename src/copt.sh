#!/usr/bin/env bash
# ============================================================================
# copt — Capture Operations for Wayland (kmsgrab + FFmpeg)
# ============================================================================
# Low-level screen/region/audio capture on Wayland using KMS grab,
# hardware-accelerated encoding (VAAPI / NVENC), and ALSA audio.
#
# Requires: FFmpeg (with --enable-libx264/x265, kmsgrab, vaapi or nvenc),
#           root access (sudo) for /dev/dri KMS framebuffer reads.
#
# Usage:  copt [OPTIONS]
#         copt --help
#
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================

set -euo pipefail
IFS=$'\n\t'

# ----- version --------------------------------------------------------------
readonly COPT_VERSION="0.1.0"

# ----- determine script and library paths -----------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly COPT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly COPT_LIB="${COPT_ROOT}/lib"
readonly COPT_CFG="${COPT_ROOT}/cfg"

# ----- source modules -------------------------------------------------------
# shellcheck source=../lib/colours.sh
source "${COPT_LIB}/colours.sh"

# Load defaults
if [[ -f "${COPT_CFG}/defaults.conf" ]]; then
    # shellcheck source=../cfg/defaults.conf
    set -a
    source "${COPT_CFG}/defaults.conf"
    set +a
fi

# Load bandwidth limit
if [[ -f "${COPT_CFG}/bandwidth_max.conf" ]]; then
    # shellcheck source=../cfg/bandwidth_max.conf
    set -a
    source "${COPT_CFG}/bandwidth_max.conf"
    set +a
fi

# shellcheck source=../lib/detect.sh
source "${COPT_LIB}/detect.sh"

# shellcheck source=../lib/streaming.sh
source "${COPT_LIB}/streaming.sh"

# shellcheck source=../lib/bandwidth.sh
source "${COPT_LIB}/bandwidth.sh"

# shellcheck source=../lib/ffmpeg.sh
source "${COPT_LIB}/ffmpeg.sh"

# shellcheck source=../lib/probe.sh
source "${COPT_LIB}/probe.sh"

# ----- load config file if present ------------------------------------------
load_config() {
    if [[ -f "$COPT_CONFIG" ]]; then
        info "Loading config: $COPT_CONFIG"
        # shellcheck source=/dev/null
        source "$COPT_CONFIG"
    fi
}

# ----- load profile if specified --------------------------------------------
load_profile() {
    local profile_name="${COPT_PROFILE:-}"
    if [[ -n "$profile_name" ]]; then
        local profile_path="${COPT_CFG}/profiles/${profile_name}.conf"
        if [[ -f "$profile_path" ]]; then
            info "Loading profile: $profile_name"
            # shellcheck source=/dev/null
            set -a
            source "$profile_path"
            set +a
        else
            die "Profile not found: $profile_path"
        fi
    fi
}

# ----- load .env file if present (for environment variables like YT_API_KEY) ---
load_env_file() {
    local env_candidates=(
        ".devcontainer/.env"
        ".env"
        "${HOME}/.copt.env"
    )
    
    for env_file in "${env_candidates[@]}"; do
        if [[ -f "$env_file" ]]; then
            info "Loading environment: $env_file"
            # shellcheck source=/dev/null
            set -a
            source "$env_file"
            set +a
            
            # If YT_API_KEY is set but COPT_YOUTUBE_KEY isn't, use YT_API_KEY
            if [[ -n "${YT_API_KEY:-}" ]] && [[ -z "${COPT_YOUTUBE_KEY:-}" ]]; then
                COPT_YOUTUBE_KEY="$YT_API_KEY"
                ok "Using YouTube API key from environment"
            fi
            return
        fi
    done
}

# ----- usage / help ----------------------------------------------------------
usage() {
    cat <<EOF
${C_BLD}copt${C_RST} v${COPT_VERSION} — Wayland screen capture via KMS grab + FFmpeg

${C_BLD}USAGE${C_RST}
    copt [OPTIONS]

${C_BLD}CAPTURE OPTIONS${C_RST}
    -d, --dri-device PATH    DRI device          (default: auto-detect)
    -W, --screen-width  N    Source screen width  (default: auto-detect)
    -H, --screen-height N    Source screen height (default: auto-detect)
    -w, --out-width     N    Output width         (default: $COPT_OUT_W)
    -h, --out-height    N    Output height        (default: $COPT_OUT_H)
    --crop-x  N              Crop region X offset (default: 0)
    --crop-y  N              Crop region Y offset (default: 0)
    --crop-w  N              Crop region width    (default: screen width)
    --crop-h  N              Crop region height   (default: screen height)
    -r, --framerate     N    Capture framerate    (default: $COPT_FRAMERATE)
    -t, --duration      N    Duration in seconds  (default: unlimited)

${C_BLD}ENCODER OPTIONS${C_RST}
    -e, --encoder  NAME      Encoder: auto|vaapi|nvenc|x264|x265|hevc  (default: auto)
    -q, --quality  N         Quality (CRF/QP)     (default: $COPT_QUALITY)
    -p, --pix-fmt  FMT       Pixel format          (default: $COPT_PIXEL_FMT)
    --profile NAME           Load encoding profile (1080p30|1080p60|4k30|4k60|4kHDR30)

${C_BLD}AUDIO OPTIONS${C_RST}
    -a, --audio-device DEV   ALSA device (e.g. hw:0,6)  (default: auto-detect)
    -A, --no-audio           Disable audio capture
    --audio-codec CODEC      Audio codec: aac|opus|mp3|copy (default: $COPT_AUDIO_CODEC)

${C_BLD}OUTPUT${C_RST}
    -o, --output  FILE       Output file path      (default: $COPT_OUTPUT)

${C_BLD}STREAMING${C_RST}
    -y, --youtube-key KEY    YouTube stream key (enables live streaming)
    --rtmp                   Use RTMP protocol (default)
    --hls                    Use HLS protocol (requires --hls-url)
    --rtmp-url URL           Custom RTMP server URL (default: YouTube)
    --hls-url URL            HLS endpoint URL
    --stream-name NAME       Stream name/key suffix (default: copt-stream)

${C_BLD}GENERAL${C_RST}
    -c, --config  FILE       Config file path
    --probe                  Probe system and show detected devices, then exit
    --dry-run                Print the ffmpeg command without executing
    --version                Show version
    --help                   Show this help

${C_BLD}EXAMPLES${C_RST}
    # Full screen capture with auto-detect
    sudo copt -o ~/recording.mkv

    # Capture at native resolution, no scaling
    sudo copt -W 3456 -H 2160 -w 3456 -h 2160

    # Capture a 1920x1080 region starting at (100,200)
    sudo copt --crop-x 100 --crop-y 200 --crop-w 1920 --crop-h 1080

    # Use NVENC encoder explicitly
    sudo copt -e nvenc -o /tmp/gpu-recording.mkv

    # No audio, 30fps, short recording
    sudo copt -A -r 30 -t 60 -o /tmp/clip.mkv

    # Use 1080p60 encoding profile
    sudo copt --profile 1080p60 -o ~/recording.mkv

    # Use 4K HDR profile for HDR10 streaming/recording
    sudo copt --profile 4kHDR30 -y YOUR_STREAM_KEY

    # Stream to YouTube Live via RTMP (default)
    sudo copt -y YOUR_STREAM_KEY

    # Stream to YouTube Live via HLS
    sudo copt -y YOUR_STREAM_KEY --hls --hls-url https://your-hls-url

${C_BLD}NOTES${C_RST}
    • Requires root (sudo) for KMS framebuffer access.
    • On multi-GPU systems, try --dri-device /dev/dri/card1 if card0 fails.
    • Check audio devices:  cat /proc/asound/cards
    • Mouse cursor capture is not supported by kmsgrab.

EOF
    exit 0
}

# ----- parse CLI args --------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dri-device)   COPT_DRI_DEVICE="$2"; shift 2 ;;
            -W|--screen-width) COPT_SCREEN_W="$2"; shift 2 ;;
            -H|--screen-height)COPT_SCREEN_H="$2"; shift 2 ;;
            -w|--out-width)    COPT_OUT_W="$2"; shift 2 ;;
            -h|--out-height)   COPT_OUT_H="$2"; shift 2 ;;
            --crop-x)          COPT_CROP_X="$2"; shift 2 ;;
            --crop-y)          COPT_CROP_Y="$2"; shift 2 ;;
            --crop-w)          COPT_CROP_W="$2"; shift 2 ;;
            --crop-h)          COPT_CROP_H="$2"; shift 2 ;;
            -r|--framerate)    COPT_FRAMERATE="$2"; shift 2 ;;
            -t|--duration)     COPT_DURATION="$2"; shift 2 ;;
            -e|--encoder)      COPT_ENCODER="$2"; shift 2 ;;
            -q|--quality)      COPT_QUALITY="$2"; shift 2 ;;
            -p|--pix-fmt)      COPT_PIXEL_FMT="$2"; shift 2 ;;
            -a|--audio-device) COPT_AUDIO_DEVICE="$2"; shift 2 ;;
            -A|--no-audio)     COPT_AUDIO=0; shift ;;
            --audio-codec)     COPT_AUDIO_CODEC="$2"; shift 2 ;;
            -o|--output)       COPT_OUTPUT="$2"; shift 2 ;;
            -y|--youtube-key)  COPT_YOUTUBE_KEY="$2"; shift 2 ;;
            --rtmp)            COPT_STREAM_TYPE="rtmp"; shift ;;
            --hls)             COPT_STREAM_TYPE="hls"; shift ;;
            --rtmp-url)        COPT_RTMP_URL="$2"; shift 2 ;;
            --hls-url)         COPT_HLS_URL="$2"; shift 2 ;;
            --stream-name)     COPT_STREAM_NAME="$2"; shift 2 ;;
            --profile)         COPT_PROFILE="$2"; shift 2 ;;
            -c|--config)       COPT_CONFIG="$2"; shift 2 ;;
            --probe)           probe_system ;;
            --dry-run)         DRY_RUN=1; shift ;;
            --version)         echo "copt v${COPT_VERSION}"; exit 0 ;;
            --help)            usage ;;
            -*)                die "Unknown option: $1  (try --help)" ;;
            *)                 COPT_OUTPUT="$1"; shift ;;   # positional = output
        esac
    done
}

# ----- signal handling -------------------------------------------------------
cleanup() {
    echo ""
    info "Capture stopped."
    if [[ "${COPT_IS_STREAMING:-0}" -eq 1 ]]; then
        ok "YouTube Live stream closed."
    elif [[ -f "$COPT_OUTPUT" ]]; then
        local size
        size=$(stat --printf='%s' "$COPT_OUTPUT" 2>/dev/null || echo 0)
        if [[ "$size" -gt 0 ]]; then
            ok "Output saved: $COPT_OUTPUT ($(numfmt --to=iec "$size" 2>/dev/null || echo "${size} bytes"))"
        else
            warn "Output file is empty — capture may have failed."
        fi
    fi
}
trap cleanup EXIT

# ----- main ------------------------------------------------------------------
main() {
    DRY_RUN="${DRY_RUN:-0}"

    load_env_file
    load_config
    
    # Parse args once to check for --profile flag
    for arg in "$@"; do
        if [[ "$arg" == "--profile" ]]; then
            shift
            COPT_PROFILE="$1"
            break
        fi
    done
    
    load_profile
    parse_args "$@"

    # Ensure running with privileges (kmsgrab needs root)
    if [[ $EUID -ne 0 ]]; then
        die "KMS grab requires root. Run with:  sudo copt $*"
    fi

    # Check ffmpeg
    command -v ffmpeg &>/dev/null || die "ffmpeg not found in PATH."

    info "copt v${COPT_VERSION} — Wayland KMS screen capture"

    detect_screen_resolution
    detect_dri_device
    detect_audio_device
    detect_encoder
    setup_streaming
    adapt_profile_to_bandwidth

    build_ffmpeg_cmd

    echo ""
    printf "${C_CYN}Capture config:${C_RST}\n"
    printf "  DRI device  : %s\n" "$COPT_DRI_DEVICE"
    printf "  Screen      : %sx%s\n" "$COPT_SCREEN_W" "$COPT_SCREEN_H"
    printf "  Crop region : x=%s y=%s w=%s h=%s\n" \
        "$COPT_CROP_X" "$COPT_CROP_Y" \
        "$([[ ${COPT_CROP_W} -eq 0 ]] && echo "$COPT_SCREEN_W" || echo "$COPT_CROP_W")" \
        "$([[ ${COPT_CROP_H} -eq 0 ]] && echo "$COPT_SCREEN_H" || echo "$COPT_CROP_H")"
    printf "  Output res  : %sx%s\n" "$COPT_OUT_W" "$COPT_OUT_H"
    printf "  Encoder     : %s\n" "$COPT_ENCODER"
    printf "  Framerate   : %s fps\n" "$COPT_FRAMERATE"
    printf "  Quality     : %s\n" "$COPT_QUALITY"
    if [[ "$COPT_AUDIO" -eq 1 ]]; then
        printf "  Audio       : %s (%s)\n" "$COPT_AUDIO_DEVICE" "$COPT_AUDIO_CODEC"
    else
        printf "  Audio       : disabled\n"
    fi
    if [[ "${COPT_IS_STREAMING:-0}" -eq 1 ]]; then
        printf "  ${C_GRN}Output      : YouTube Live (%s)${C_RST}\n" "${COPT_STREAM_TYPE^^}"
    else
        printf "  Output file : %s\n" "$COPT_OUTPUT"
    fi
    if [[ "$COPT_DURATION" -gt 0 ]]; then
        printf "  Duration    : %ss\n" "$COPT_DURATION"
    else
        printf "  Duration    : until Ctrl-C\n"
    fi
    echo ""

    # Print the command
    printf "${C_CYN}ffmpeg command:${C_RST}\n"
    local cmd_str=""
    for arg in "${FFMPEG_CMD[@]}"; do
        if [[ "$arg" == *" "* ]]; then
            cmd_str+=" '${arg}'"
        else
            cmd_str+=" ${arg}"
        fi
    done
    printf "  %s\n\n" "${cmd_str# }"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry run mode — testing FFmpeg command with 5-second capture to /tmp"
        
        # Override duration for dry-run test
        local test_cmd=("${FFMPEG_CMD[@]}")
        
        # Find and replace output file or add -t flag
        local has_duration=0
        for i in "${!test_cmd[@]}"; do
            if [[ "${test_cmd[$i]}" == "-t" ]]; then
                test_cmd[$((i+1))]="5"
                has_duration=1
                break
            fi
        done
        
        # Add -t 5 if not present (insert before output)
        if [[ $has_duration -eq 0 ]]; then
            local out_idx=$((${#test_cmd[@]} - 1))
            test_cmd=("${test_cmd[@]:0:$out_idx}" "-t" "5" "${test_cmd[$out_idx]}")
        fi
        
        # For streaming, ensure output goes to /tmp
        if [[ "${COPT_IS_STREAMING:-0}" -eq 1 ]]; then
            test_cmd[$((${#test_cmd[@]} - 1))]="${COPT_OUTPUT}"
        fi
        
        echo ""
        info "Executing test capture for 5 seconds…"
        "${test_cmd[@]}" && ok "Dry-run test successful!" || warn "Dry-run test failed (exit code: $?)"
        
        if [[ "${COPT_IS_STREAMING:-0}" -eq 1 && -f "${COPT_OUTPUT}" ]]; then
            local size=$(stat --printf='%s' "${COPT_OUTPUT}" 2>/dev/null || echo 0)
            ok "Test output: ${COPT_OUTPUT} ($(numfmt --to=iec "$size" 2>/dev/null || echo "${size} bytes"))"
            info "Review output with: ffplay ${COPT_OUTPUT}"
        fi
        
        exit 0
    fi

    info "Starting capture… press Ctrl-C to stop."
    echo ""

    # Create output directory if needed (only for file output)
    if [[ "${COPT_IS_STREAMING:-0}" -eq 0 ]]; then
        mkdir -p "$(dirname "$COPT_OUTPUT")"
    fi

    # Execute
    exec "${FFMPEG_CMD[@]}"
}

main "$@"

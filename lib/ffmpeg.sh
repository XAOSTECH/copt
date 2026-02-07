#!/usr/bin/env bash
# ============================================================================
# copt — FFmpeg command builder
# ============================================================================
# Constructs the ffmpeg command array based on configuration
# ============================================================================

# ----- build ffmpeg command -------------------------------------------------
build_ffmpeg_cmd() {
    local cmd=()
    cmd+=(ffmpeg -hide_banner -loglevel info -y)

    # -- Audio input --
    if [[ "$COPT_AUDIO" -eq 1 && -n "${COPT_AUDIO_DEVICE:-}" ]]; then
        cmd+=(-f alsa -i "$COPT_AUDIO_DEVICE")
    fi

    # -- Video input (kmsgrab) --
    cmd+=(-device "$COPT_DRI_DEVICE" -f kmsgrab -framerate "$COPT_FRAMERATE" -i -)

    # -- Duration --
    if [[ "$COPT_DURATION" -gt 0 ]]; then
        cmd+=(-t "$COPT_DURATION")
    fi

    # Resolve crop dimensions
    local cw="${COPT_CROP_W}"
    local ch="${COPT_CROP_H}"
    [[ "$cw" -eq 0 ]] && cw="$COPT_SCREEN_W"
    [[ "$ch" -eq 0 ]] && ch="$COPT_SCREEN_H"

    # -- Build filter + encoder per backend --
    case "$COPT_ENCODER" in
        vaapi)
            local vf="hwmap=derive_device=vaapi"
            vf+=",crop=x=${COPT_CROP_X}:y=${COPT_CROP_Y}:w=${cw}:h=${ch}"
            vf+=",scale_vaapi=${COPT_OUT_W}:${COPT_OUT_H}:${COPT_PIXEL_FMT}"
            cmd+=(-vf "$vf")
            cmd+=(-c:v h264_vaapi -qp "$COPT_QUALITY")
            ;;
        nvenc)
            local vf="hwmap=derive_device=cuda"
            vf+=",crop=x=${COPT_CROP_X}:y=${COPT_CROP_Y}:w=${cw}:h=${ch}"
            vf+=",scale_cuda=${COPT_OUT_W}:${COPT_OUT_H}:${COPT_PIXEL_FMT}"
            cmd+=(-vf "$vf")
            cmd+=(-c:v h264_nvenc -preset p4 -qp "$COPT_QUALITY" -bf 0)
            ;;
        x264)
            # Software path: download from GPU then filter on CPU
            local vf="hwdownload,format=bgr0"
            vf+=",crop=${cw}:${ch}:${COPT_CROP_X}:${COPT_CROP_Y}"
            vf+=",scale=${COPT_OUT_W}:${COPT_OUT_H}"
            cmd+=(-vf "$vf")
            cmd+=(-c:v libx264 -preset fast -crf "$COPT_QUALITY" -pix_fmt yuv420p)
            ;;
        x265)
            local vf="hwdownload,format=bgr0"
            vf+=",crop=${cw}:${ch}:${COPT_CROP_X}:${COPT_CROP_Y}"
            vf+=",scale=${COPT_OUT_W}:${COPT_OUT_H}"
            cmd+=(-vf "$vf")
            cmd+=(-c:v libx265 -preset fast -crf "$COPT_QUALITY" -pix_fmt yuv420p)
            ;;
        *)
            die "Unknown encoder: $COPT_ENCODER"
            ;;
    esac

    # -- Audio codec --
    if [[ "$COPT_AUDIO" -eq 1 && -n "${COPT_AUDIO_DEVICE:-}" ]]; then
        case "$COPT_AUDIO_CODEC" in
            aac)   cmd+=(-c:a aac -b:a 192k) ;;
            opus)  cmd+=(-c:a libopus -b:a 128k) ;;
            mp3)   cmd+=(-c:a libmp3lame -b:a 192k) ;;
            copy)  cmd+=(-c:a copy) ;;
            *)     die "Unknown audio codec: $COPT_AUDIO_CODEC" ;;
        esac
    fi

    # -- Output --
    cmd+=("$COPT_OUTPUT")

    # Return as a joined string for display, but we'll use the array to exec
    FFMPEG_CMD=("${cmd[@]}")
}

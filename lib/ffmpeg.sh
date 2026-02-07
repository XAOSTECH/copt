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
            
            # Add bitrate control if specified (streaming)
            if [[ -n "${COPT_BITRATE_VIDEO:-}" ]]; then
                cmd+=(-b:v "$COPT_BITRATE_VIDEO" -maxrate "$COPT_BITRATE_VIDEO")
                [[ -n "${COPT_BUFFER_SIZE:-}" ]] && cmd+=(-bufsize "$COPT_BUFFER_SIZE")
            fi
            [[ -n "${COPT_GOP_SIZE:-}" ]] && cmd+=(-g "$COPT_GOP_SIZE")
            ;;
        nvenc)
            local vf="hwmap=derive_device=cuda"
            vf+=",crop=x=${COPT_CROP_X}:y=${COPT_CROP_Y}:w=${cw}:h=${ch}"
            vf+=",scale_cuda=${COPT_OUT_W}:${COPT_OUT_H}:${COPT_PIXEL_FMT}"
            cmd+=(-vf "$vf")
            cmd+=(-c:v h264_nvenc -preset p4 -qp "$COPT_QUALITY" -bf 0)
            
            # Add bitrate control if specified
            if [[ -n "${COPT_BITRATE_VIDEO:-}" ]]; then
                cmd+=(-b:v "$COPT_BITRATE_VIDEO" -maxrate "$COPT_BITRATE_VIDEO")
                [[ -n "${COPT_BUFFER_SIZE:-}" ]] && cmd+=(-bufsize "$COPT_BUFFER_SIZE")
            fi
            [[ -n "${COPT_GOP_SIZE:-}" ]] && cmd+=(-g "$COPT_GOP_SIZE")
            ;;
        hevc)
            # HEVC for HDR (NVENC or VAAPI)
            local encoders
            encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null || true)
            
            if echo "$encoders" | grep -q hevc_nvenc; then
                local vf="hwmap=derive_device=cuda"
                vf+=",crop=x=${COPT_CROP_X}:y=${COPT_CROP_Y}:w=${cw}:h=${ch}"
                vf+=",scale_cuda=${COPT_OUT_W}:${COPT_OUT_H}:${COPT_PIXEL_FMT}"
                cmd+=(-vf "$vf")
                cmd+=(-c:v hevc_nvenc -preset p4 -qp "$COPT_QUALITY" -profile:v main10)
                
                # HDR metadata
                if [[ -n "${COPT_COLORSPACE:-}" ]]; then
                    cmd+=(-colorspace "${COPT_COLORSPACE}")
                    cmd+=(-color_primaries "${COPT_COLOR_PRIMARIES:-bt2020}")
                    cmd+=(-color_trc "${COPT_COLOR_TRC:-smpte2084}")
                    cmd+=(-color_range "${COPT_COLOR_RANGE:-tv}")
                fi
                if [[ -n "${COPT_HDR_MASTER_DISPLAY:-}" ]]; then
                    cmd+=(-sei hdr10)
                    cmd+=(-master_display "${COPT_HDR_MASTER_DISPLAY}")
                    [[ -n "${COPT_HDR_MAX_CLL:-}" ]] && cmd+=(-max_cll "${COPT_HDR_MAX_CLL}")
                fi
            elif echo "$encoders" | grep -q hevc_vaapi; then
                local vf="hwmap=derive_device=vaapi"
                vf+=",crop=x=${COPT_CROP_X}:y=${COPT_CROP_Y}:w=${cw}:h=${ch}"
                vf+=",scale_vaapi=${COPT_OUT_W}:${COPT_OUT_H}:${COPT_PIXEL_FMT}"
                cmd+=(-vf "$vf")
                cmd+=(-c:v hevc_vaapi -qp "$COPT_QUALITY")
                
                # HDR metadata for VAAPI
                if [[ -n "${COPT_COLORSPACE:-}" ]]; then
                    cmd+=(-colorspace "${COPT_COLORSPACE}")
                    cmd+=(-color_primaries "${COPT_COLOR_PRIMARIES:-bt2020}")
                    cmd+=(-color_trc "${COPT_COLOR_TRC:-smpte2084}")
                fi
            else
                die "HEVC encoder not available. Install FFmpeg with hevc_nvenc or hevc_vaapi support."
            fi
            
            # Add bitrate control
            if [[ -n "${COPT_BITRATE_VIDEO:-}" ]]; then
                cmd+=(-b:v "$COPT_BITRATE_VIDEO" -maxrate "$COPT_BITRATE_VIDEO")
                [[ -n "${COPT_BUFFER_SIZE:-}" ]] && cmd+=(-bufsize "$COPT_BUFFER_SIZE")
            fi
            [[ -n "${COPT_GOP_SIZE:-}" ]] && cmd+=(-g "$COPT_GOP_SIZE")
            ;;
        x264)
            # Software path: download from GPU then filter on CPU
            local vf="hwdownload,format=bgr0"
            vf+=",crop=${cw}:${ch}:${COPT_CROP_X}:${COPT_CROP_Y}"
            vf+=",scale=${COPT_OUT_W}:${COPT_OUT_H}"
            cmd+=(-vf "$vf")
            cmd+=(-c:v libx264 -preset fast -crf "$COPT_QUALITY" -pix_fmt yuv420p)
            
            # Add bitrate control if specified
            if [[ -n "${COPT_BITRATE_VIDEO:-}" ]]; then
                cmd+=(-b:v "$COPT_BITRATE_VIDEO" -maxrate "$COPT_BITRATE_VIDEO")
                [[ -n "${COPT_BUFFER_SIZE:-}" ]] && cmd+=(-bufsize "$COPT_BUFFER_SIZE")
            fi
            [[ -n "${COPT_GOP_SIZE:-}" ]] && cmd+=(-g "$COPT_GOP_SIZE")
            ;;
        x265)
            local vf="hwdownload,format=bgr0"
            vf+=",crop=${cw}:${ch}:${COPT_CROP_X}:${COPT_CROP_Y}"
            vf+=",scale=${COPT_OUT_W}:${COPT_OUT_H}"
            cmd+=(-vf "$vf")
            cmd+=(-c:v libx265 -preset fast -crf "$COPT_QUALITY" -pix_fmt yuv420p)
            
            # Add bitrate control if specified
            if [[ -n "${COPT_BITRATE_VIDEO:-}" ]]; then
                cmd+=(-b:v "$COPT_BITRATE_VIDEO" -maxrate "$COPT_BITRATE_VIDEO")
                [[ -n "${COPT_BUFFER_SIZE:-}" ]] && cmd+=(-bufsize "$COPT_BUFFER_SIZE")
            fi
            [[ -n "${COPT_GOP_SIZE:-}" ]] && cmd+=(-g "$COPT_GOP_SIZE")
            ;;
        *)
            die "Unknown encoder: $COPT_ENCODER"
            ;;
    esac

    # -- Audio codec --
    if [[ "$COPT_AUDIO" -eq 1 && -n "${COPT_AUDIO_DEVICE:-}" ]]; then
        case "$COPT_AUDIO_CODEC" in
            aac)
                cmd+=(-c:a aac)
                if [[ -n "${COPT_BITRATE_AUDIO:-}" ]]; then
                    cmd+=(-b:a "$COPT_BITRATE_AUDIO")
                else
                    cmd+=(-b:a 192k)
                fi
                ;;
            opus)
                cmd+=(-c:a libopus)
                if [[ -n "${COPT_BITRATE_AUDIO:-}" ]]; then
                    cmd+=(-b:a "$COPT_BITRATE_AUDIO")
                else
                    cmd+=(-b:a 128k)
                fi
                ;;
            mp3)
                cmd+=(-c:a libmp3lame)
                if [[ -n "${COPT_BITRATE_AUDIO:-}" ]]; then
                    cmd+=(-b:a "$COPT_BITRATE_AUDIO")
                else
                    cmd+=(-b:a 192k)
                fi
                ;;
            copy)  cmd+=(-c:a copy) ;;
            *)     die "Unknown audio codec: $COPT_AUDIO_CODEC" ;;
        esac
    fi

    # -- Output --
    cmd+=("$COPT_OUTPUT")

    # Return as a joined string for display, but we'll use the array to exec
    FFMPEG_CMD=("${cmd[@]}")
}

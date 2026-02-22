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
    if [[ -n "${COPT_PREVIEW_OUTPUT:-}" && "${COPT_IS_STREAMING:-0}" -eq 1 && "${DRY_RUN:-0}" -eq 0 ]]; then
        local main_fmt=""
        case "${COPT_STREAM_TYPE:-}" in
            rtmp) main_fmt="flv" ;;
            hls)  main_fmt="hls:method=PUT:hls_time=2:hls_list_size=6:hls_flags=delete_segments+omit_endlist" ;;
        esac
        local preview_fmt="${COPT_PREVIEW_FORMAT:-mpegts}"
        local tee_outputs=""
        if [[ -n "$main_fmt" ]]; then
            tee_outputs="[f=${main_fmt}]${COPT_OUTPUT}|[f=${preview_fmt}]${COPT_PREVIEW_OUTPUT}"
        else
            tee_outputs="${COPT_OUTPUT}|[f=${preview_fmt}]${COPT_PREVIEW_OUTPUT}"
        fi
        cmd+=(-f tee "$tee_outputs")
    else
        cmd+=("$COPT_OUTPUT")
    fi

    # Return as a joined string for display, but we'll use the array to exec
    FFMPEG_CMD=("${cmd[@]}")
}

# ----- build ffmpeg command for USB V4L2 capture device ---------------------
# Used for USB capture cards such as the UGREEN 25173 (VID:PID 3188:1000).
# Input comes from a V4L2 node (/dev/videoX) rather than KMS grab.
build_ffmpeg_usb_cmd() {
    local cmd=()

    # Core flags – nobuffer + genpts keep stream alive through micro-stalls
    cmd+=(ffmpeg -hide_banner -loglevel info -y)
    cmd+=(-fflags +genpts+discardcorrupt)
    cmd+=(-use_wallclock_as_timestamps 1)

    # -- Audio input (before video so audio stream index is 0) --
    if [[ "$COPT_AUDIO" -eq 1 && -n "${COPT_AUDIO_DEVICE:-}" ]]; then
        cmd+=(-thread_queue_size 512)
        cmd+=(-f alsa -i "$COPT_AUDIO_DEVICE")
    fi

    # -- V4L2 video input --
    # UGREEN 25173 provides MJPEG at 4K, YUYV422 at lower resolutions.
    # Default to mjpeg (best bandwidth efficiency through USB-C).
    local input_fmt="${COPT_USB_INPUT_FORMAT:-mjpeg}"
    local input_w="${COPT_USB_INPUT_W:-${COPT_OUT_W}}"
    local input_h="${COPT_USB_INPUT_H:-${COPT_OUT_H}}"

    cmd+=(-thread_queue_size 512)
    cmd+=(-f v4l2)
    cmd+=(-input_format "$input_fmt")
    cmd+=(-video_size "${input_w}x${input_h}")
    cmd+=(-framerate "$COPT_FRAMERATE")
    cmd+=(-i "${COPT_USB_DEVICE:-/dev/video0}")

    # -- Duration --
    if [[ "$COPT_DURATION" -gt 0 ]]; then
        cmd+=(-t "$COPT_DURATION")
    fi

    # -- Map streams explicitly (audio first if present) --
    if [[ "$COPT_AUDIO" -eq 1 && -n "${COPT_AUDIO_DEVICE:-}" ]]; then
        cmd+=(-map 1:v:0 -map 0:a:0)
    else
        cmd+=(-map 0:v:0)
    fi

    # -- Logo detection filter (prepended to video filter chain) --
    local logo_filter=""
    if [[ "${COPT_LOGO_DETECT:-0}" -eq 1 && -n "${COPT_LOGO_COORDS:-}" ]]; then
        local x y w h
        IFS=: read -r x y w h <<< "$COPT_LOGO_COORDS"
        
        case "${COPT_LOGO_METHOD:-drawbox}" in
            drawbox)
                # Black box over logo (simple, clean)
                logo_filter="drawbox=x=${x}:y=${y}:w=${w}:h=${h}:colour=black@1:t=fill"
                ;;
            delogo)
                # Blur/interpolate logo area (FFmpeg delogo filter)
                logo_filter="delogo=x=${x}:y=${y}:w=${w}:h=${h}:show=0"
                ;;
        esac
        info "Logo detection enabled: ${logo_filter}"
    fi

    # -- Video filter + encoder --
    # For USB capture cards the input is already decoded (MJPEG→raw or YUYV).
    # We upload to GPU or keep software for encoding.
    case "$COPT_ENCODER" in
        vaapi)
            local vf=""
            [[ -n "$logo_filter" ]] && vf="${logo_filter},"
            vf+="format=nv12,hwupload=extra_hw_frames=64"
            # Scale only when output differs from input size
            if [[ "$COPT_OUT_W" != "$input_w" || "$COPT_OUT_H" != "$input_h" ]]; then
                vf+=",scale_vaapi=${COPT_OUT_W}:${COPT_OUT_H}"
            fi
            cmd+=(-vf "$vf")
            cmd+=(-c:v h264_vaapi -qp "$COPT_QUALITY")
            if [[ -n "${COPT_BITRATE_VIDEO:-}" ]]; then
                cmd+=(-b:v "$COPT_BITRATE_VIDEO" -maxrate "$COPT_BITRATE_VIDEO")
                [[ -n "${COPT_BUFFER_SIZE:-}" ]] && cmd+=(-bufsize "$COPT_BUFFER_SIZE")
            fi
            [[ -n "${COPT_GOP_SIZE:-}" ]] && cmd+=(-g "$COPT_GOP_SIZE")
            ;;
        nvenc)
            local vf=""
            [[ -n "$logo_filter" ]] && vf="${logo_filter},"
            vf+="format=nv12,hwupload"
            if [[ "$COPT_OUT_W" != "$input_w" || "$COPT_OUT_H" != "$input_h" ]]; then
                vf+=",scale_cuda=${COPT_OUT_W}:${COPT_OUT_H}"
            fi
            cmd+=(-vf "$vf")
            cmd+=(-c:v h264_nvenc -preset p4 -qp "$COPT_QUALITY" -bf 0)
            if [[ -n "${COPT_BITRATE_VIDEO:-}" ]]; then
                cmd+=(-b:v "$COPT_BITRATE_VIDEO" -maxrate "$COPT_BITRATE_VIDEO")
                [[ -n "${COPT_BUFFER_SIZE:-}" ]] && cmd+=(-bufsize "$COPT_BUFFER_SIZE")
            fi
            [[ -n "${COPT_GOP_SIZE:-}" ]] && cmd+=(-g "$COPT_GOP_SIZE")
            ;;
        x264)
            local vf=""
            [[ -n "$logo_filter" ]] && vf="${logo_filter},"
            vf+="format=yuv420p"
            if [[ "$COPT_OUT_W" != "$input_w" || "$COPT_OUT_H" != "$input_h" ]]; then
                vf+=",scale=${COPT_OUT_W}:${COPT_OUT_H}"
            fi
            cmd+=(-vf "$vf")
            cmd+=(-c:v libx264 -preset fast -crf "$COPT_QUALITY" -pix_fmt yuv420p)
            if [[ -n "${COPT_BITRATE_VIDEO:-}" ]]; then
                cmd+=(-b:v "$COPT_BITRATE_VIDEO" -maxrate "$COPT_BITRATE_VIDEO")
                [[ -n "${COPT_BUFFER_SIZE:-}" ]] && cmd+=(-bufsize "$COPT_BUFFER_SIZE")
            fi
            [[ -n "${COPT_GOP_SIZE:-}" ]] && cmd+=(-g "$COPT_GOP_SIZE")
            ;;
        x265)
            local vf=""
            [[ -n "$logo_filter" ]] && vf="${logo_filter},"
            vf+="format=yuv420p"
            if [[ "$COPT_OUT_W" != "$input_w" || "$COPT_OUT_H" != "$input_h" ]]; then
                vf+=",scale=${COPT_OUT_W}:${COPT_OUT_H}"
            fi
            cmd+=(-vf "$vf")
            cmd+=(-c:v libx265 -preset fast -crf "$COPT_QUALITY" -pix_fmt yuv420p)
            if [[ -n "${COPT_BITRATE_VIDEO:-}" ]]; then
                cmd+=(-b:v "$COPT_BITRATE_VIDEO" -maxrate "$COPT_BITRATE_VIDEO")
                [[ -n "${COPT_BUFFER_SIZE:-}" ]] && cmd+=(-bufsize "$COPT_BUFFER_SIZE")
            fi
            [[ -n "${COPT_GOP_SIZE:-}" ]] && cmd+=(-g "$COPT_GOP_SIZE")
            ;;
        hevc)
            # HEVC for HDR10 — input is 8-bit yuv420p with HDR already encoded by device.
            # V4L2 reports Rec.709 tags but HDR-capable capture cards encode 10-bit HDR
            # in 8-bit stream with LUT/codec. Just expand to p010le and tag OUTPUT as HDR.
            # No setparams needed - device handles HDR encoding, we just tag the output.
            local encoders
            encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null || true)

            if echo "$encoders" | grep -q hevc_nvenc; then
                # hevc_nvenc handles CPU→GPU upload internally - no hwupload needed
                local vf=""
                [[ -n "$logo_filter" ]] && vf="${logo_filter},"
                vf+="format=yuv420p,hwupload_cuda,scale_cuda=${COPT_OUT_W}:${COPT_OUT_H}:format=p010le"
                cmd+=(-vf "$vf")
                cmd+=(-c:v hevc_nvenc -preset p4 -profile:v main10 -pix_fmt p010le -bf 0)
                cmd+=(-qp "$COPT_QUALITY")
                # HDR10 static metadata via SEI
                cmd+=(-color_primaries "${COPT_COLOR_PRIMARIES:-bt2020}")
                cmd+=(-color_trc "${COPT_COLOR_TRC:-smpte2084}")
                cmd+=(-colorspace "${COPT_COLORSPACE:-bt2020nc}")
                cmd+=(-color_range "${COPT_COLOR_RANGE:-tv}")
            elif echo "$encoders" | grep -q hevc_vaapi; then
                local vf=""
                [[ -n "$logo_filter" ]] && vf="${logo_filter},"
                vf+="format=p010le,hwupload=extra_hw_frames=64"
                if [[ "$COPT_OUT_W" != "$input_w" || "$COPT_OUT_H" != "$input_h" ]]; then
                    vf+=",scale_vaapi=${COPT_OUT_W}:${COPT_OUT_H}:p010le"
                fi
                cmd+=(-vf "$vf")
                cmd+=(-c:v hevc_vaapi -profile:v main10 -pix_fmt p010le)
                cmd+=(-qp "$COPT_QUALITY")
                cmd+=(-color_primaries "${COPT_COLOR_PRIMARIES:-bt2020}")
                cmd+=(-color_trc "${COPT_COLOR_TRC:-smpte2084}")
                cmd+=(-colorspace "${COPT_COLORSPACE:-bt2020nc}")
                cmd+=(-color_range "${COPT_COLOR_RANGE:-tv}")
            else
                # Software fallback: libx265 can encode Main10 from p010le
                local vf=""
                [[ -n "$logo_filter" ]] && vf="${logo_filter},"
                vf+="format=p010le"
                if [[ "$COPT_OUT_W" != "$input_w" || "$COPT_OUT_H" != "$input_h" ]]; then
                    vf+=",scale=${COPT_OUT_W}:${COPT_OUT_H}"
                fi
                cmd+=(-vf "$vf")
                cmd+=(-c:v libx265 -preset fast -crf "$COPT_QUALITY" -pix_fmt yuv420p10le)
                cmd+=(-x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc")
                [[ -n "${COPT_HDR_MASTER_DISPLAY:-}" ]] && \
                    cmd+=(-x265-params "master-display=${COPT_HDR_MASTER_DISPLAY}:max-cll=${COPT_HDR_MAX_CLL:-1000,400}")
                warn "No hardware HEVC encoder found — using libx265 (CPU, slow for 4K)"
            fi

            if [[ -n "${COPT_BITRATE_VIDEO:-}" ]]; then
                cmd+=(-b:v "$COPT_BITRATE_VIDEO" -maxrate "$COPT_BITRATE_VIDEO")
                [[ -n "${COPT_BUFFER_SIZE:-}" ]] && cmd+=(-bufsize "$COPT_BUFFER_SIZE")
            fi
            [[ -n "${COPT_GOP_SIZE:-}" ]] && cmd+=(-g "$COPT_GOP_SIZE")
            ;;
        *)
            die "Unknown encoder for USB capture: $COPT_ENCODER (use vaapi|nvenc|hevc|x264|x265)"
            ;;
    esac

    # -- Audio codec --
    if [[ "$COPT_AUDIO" -eq 1 && -n "${COPT_AUDIO_DEVICE:-}" ]]; then
        case "$COPT_AUDIO_CODEC" in
            aac)
                cmd+=(-c:a aac)
                cmd+=(-b:a "${COPT_BITRATE_AUDIO:-192k}")
                ;;
            opus)
                cmd+=(-c:a libopus)
                cmd+=(-b:a "${COPT_BITRATE_AUDIO:-128k}")
                ;;
            mp3)
                cmd+=(-c:a libmp3lame)
                cmd+=(-b:a "${COPT_BITRATE_AUDIO:-192k}")
                ;;
            copy) cmd+=(-c:a copy) ;;
            *)    die "Unknown audio codec: $COPT_AUDIO_CODEC" ;;
        esac
    fi

    # -- Output --
    if [[ -n "${COPT_PREVIEW_OUTPUT:-}" && "${COPT_IS_STREAMING:-0}" -eq 1 && "${DRY_RUN:-0}" -eq 0 ]]; then
        local main_fmt=""
        case "${COPT_STREAM_TYPE:-}" in
            rtmp) main_fmt="flv" ;;
            hls)  main_fmt="hls:method=PUT:hls_time=2:hls_list_size=6:hls_flags=delete_segments+omit_endlist" ;;
        esac
        local preview_fmt="${COPT_PREVIEW_FORMAT:-mpegts}"
        local tee_outputs=""
        if [[ -n "$main_fmt" ]]; then
            tee_outputs="[f=${main_fmt}]${COPT_OUTPUT}|[f=${preview_fmt}]${COPT_PREVIEW_OUTPUT}"
        else
            tee_outputs="${COPT_OUTPUT}|[f=${preview_fmt}]${COPT_PREVIEW_OUTPUT}"
        fi
        cmd+=(-f tee "$tee_outputs")
    else
        cmd+=("$COPT_OUTPUT")
    fi

    FFMPEG_CMD=("${cmd[@]}")
}

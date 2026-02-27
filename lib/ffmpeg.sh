#!/usr/bin/env bash
# ============================================================================
# copt — FFmpeg command builder
# ============================================================================
# Constructs the ffmpeg command array based on configuration
# ============================================================================

# ----- build ffmpeg command -------------------------------------------------
build_ffmpeg_cmd() {
    local cmd=()
    local ffmpeg_bin="${COPT_FFMPEG_BIN:-ffmpeg}"
    [[ -x "$HOME/.local/bin/ffmpeg" ]] && ffmpeg_bin="$HOME/.local/bin/ffmpeg"
    cmd+=("$ffmpeg_bin" -hide_banner -loglevel info -y)

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
            cmd+=(-c:v hevc_vaapi -qp "$COPT_QUALITY")
            
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
            cmd+=(-c:v hevc_nvenc -preset p4 -qp "$COPT_QUALITY" -bf 0)
            
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
            encoders=$("$ffmpeg_bin" -hide_banner -encoders 2>/dev/null || true)
            
            if echo "$encoders" | grep -q hevc_nvenc; then
                local vf="hwmap=derive_device=cuda"
                vf+=",crop=x=${COPT_CROP_X}:y=${COPT_CROP_Y}:w=${cw}:h=${ch}"
                vf+=",scale_cuda=${COPT_OUT_W}:${COPT_OUT_H}:${COPT_PIXEL_FMT}"
                cmd+=(-vf "$vf")
                cmd+=(-c:v hevc_nvenc -preset p4 -qp "$COPT_QUALITY" -profile:v main10)
                
                # RTX-optimized encoding settings
                cmd+=(-rc vbr -surfaces 32 -b_ref_mode each -aq-strength 15 -rc-lookahead 32)
                
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

    # -- Output with streaming --
    # Note: When using tee muxer, format-specific options are set in the format string, not globally
    if [[ -n "${COPT_PREVIEW_OUTPUT:-}" && "${COPT_IS_STREAMING:-0}" -eq 1 && "${DRY_RUN:-0}" -eq 0 ]]; then
        local main_fmt=""
        case "${COPT_STREAM_TYPE:-}" in
            rtmp) main_fmt="flv" ;;
            hls)  main_fmt="hls:method=PUT:hls_time=2:hls_list_size=6:hls_flags=delete_segments+omit_endlist+independent_segments" ;;
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
        # Direct output (no preview) - apply HLS options globally for non-tee output
        if [[ "${COPT_STREAM_TYPE:-}" == "hls" ]]; then
            cmd+=(-f hls)
            cmd+=(-hls_time 4)
            cmd+=(-hls_list_size 5)
            cmd+=(-hls_flags delete_segments+omit_endlist+independent_segments)
            cmd+=(-hls_playlist_type event)
            cmd+=(-method PUT)
            cmd+=(-http_persistent 1)
            cmd+=(-timeout 300)
        fi
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
    local ffmpeg_bin="${COPT_FFMPEG_BIN:-ffmpeg}"
    [[ -x "$HOME/.local/bin/ffmpeg" ]] && ffmpeg_bin="$HOME/.local/bin/ffmpeg"
    local encoders
    encoders=$("$ffmpeg_bin" -hide_banner -encoders 2>/dev/null || true)

    # Absolute minimum: ffmpeg + inputs + encoder. Nothing else.
    cmd+=("$ffmpeg_bin")

    # -- Audio input --
    if [[ "$COPT_AUDIO" -eq 1 && -n "${COPT_AUDIO_DEVICE:-}" ]]; then
        cmd+=(-f alsa -i "$COPT_AUDIO_DEVICE")
    fi

    # -- V4L2 video input --
    local input_fmt="${COPT_USB_INPUT_FORMAT:-nv12}"
    local input_w="${COPT_USB_INPUT_W:-${COPT_OUT_W}}"
    local input_h="${COPT_USB_INPUT_H:-${COPT_OUT_H}}"

    cmd+=(-f v4l2 -thread_queue_size 1024)
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
            cmd+=(-c:v hevc_vaapi -qp "$COPT_QUALITY")
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
            cmd+=(-c:v hevc_nvenc -preset p4 -qp "$COPT_QUALITY" -bf 0)
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
            # HEVC encoding — NVIDIA NVENC GPU encoder (no filter chain, direct encode)
            if echo "$encoders" | grep -q hevc_nvenc; then
                # Direct encoding: nv12 input -> hevc_nvenc converts to p010le internally
                # No filter chain needed - OBS-style direct encode
                
                # NVIDIA NVENC h265 — GPU-only encoding with minimal CPU preprocessing
                cmd+=(-c:v hevc_nvenc)
                cmd+=(-pix_fmt "${COPT_PIXEL_FMT:-p010le}")  # Encoder converts nv12 -> p010le
                cmd+=(-preset "${COPT_NVENC_PRESET:-p4}")    # p4=low latency (pure GPU), p5=balanced
                cmd+=(-tune "${COPT_NVENC_TUNE:-ll}")        # ll=low latency (GPU-only pipeline)
                cmd+=(-profile:v main10)                      # HDR10 Main10 profile
                cmd+=(-tag:v hvc1)                            # HLS compatibility tag
                
                # Pure GPU encoding settings (minimal CPU)
                cmd+=(-rc vbr)                               # Variable bitrate
                cmd+=(-delay 0)                              # No frame delay (pure GPU pipeline)
                cmd+=(-zerolatency 1)                        # Zero latency mode (no CPU buffering)
                cmd+=(-rc-lookahead 0)                       # Disable CPU lookahead analysis (GPU decides in real-time)
                cmd+=(-b_ref_mode 0)                         # Disable (reduces complexity)
                cmd+=(-spatial-aq 1)                         # GPU spatial AQ only
                cmd+=(-temporal-aq 1)                        # GPU temporal AQ
                
                # HDR metadata (for YouTube and HDR displays)
                cmd+=(-color_range 1)                        # 1=video range (required for HDR), not pc range
                cmd+=(-colorspace bt2020nc)                  # BT.2020 color space (HDR standard)
                cmd+=(-color_primaries bt2020)               # BT.2020 primaries
                cmd+=(-color_trc smpte2084)                  # PQ (Perceptual Quantization) for HDR
                # Note: -master_display and -max_cll are mov/mp4 options, not supported by HLS muxer
                # HDR information is embedded in HEVC bitstream via pix_fmt and color settings above
            else
                # CPU fallback
                cmd+=(-c:v libx265 -preset fast -crf "$COPT_QUALITY" -pix_fmt yuv420p)
            fi

            # Bitrate control (for streaming)
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

    # -- Output with streaming --
    # For HLS streaming: write to local /tmp/hls/, relay uploads asynchronously
    # This decouples encoding from network uploads (like OBS does internally)
    if [[ "${COPT_STREAM_TYPE:-}" == "hls" ]]; then
        # Create local HLS output directory
        mkdir -p /tmp/hls
        
        # Write to local disk (no network blocking on encoder)
        local hls_output="/tmp/hls/stream.m3u8"
        
        if [[ -n "${COPT_PREVIEW_OUTPUT:-}" && "${COPT_IS_STREAMING:-0}" -eq 1 && "${DRY_RUN:-0}" -eq 0 ]]; then
            # With preview: use tee to split streams
            local preview_fmt="${COPT_PREVIEW_FORMAT:-mpegts}"
            local hls_fmt="hls:hls_time=4:hls_list_size=5:hls_flags=delete_segments+omit_endlist+independent_segments:hls_playlist_type=event"
            local tee_outputs="[f=${hls_fmt}]${hls_output}|[f=${preview_fmt}]${COPT_PREVIEW_OUTPUT}"
            cmd+=(-f tee "$tee_outputs")
        else
            # No preview: direct HLS output to local disk
            cmd+=(-f hls)
            cmd+=(-hls_time 4)
            cmd+=(-hls_list_size 5)
            cmd+=(-hls_flags delete_segments+omit_endlist+independent_segments)
            cmd+=(-hls_playlist_type event)
            cmd+=("$hls_output")
        fi
    elif [[ -n "${COPT_PREVIEW_OUTPUT:-}" && "${COPT_IS_STREAMING:-0}" -eq 1 && "${DRY_RUN:-0}" -eq 0 ]]; then
        # Non-HLS with preview: use tee
        local main_fmt=""
        case "${COPT_STREAM_TYPE:-}" in
            rtmp) main_fmt="flv" ;;
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
        # Direct output (no preview)
        cmd+=("$COPT_OUTPUT")
    fi

    FFMPEG_CMD=("${cmd[@]}")
}

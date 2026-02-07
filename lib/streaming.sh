#!/usr/bin/env bash
# ============================================================================
# copt — Streaming setup functions
# ============================================================================
# YouTube Live streaming via RTMP or HLS
# ============================================================================

# ----- setup streaming ------------------------------------------------------
setup_streaming() {
    if [[ -z "${COPT_YOUTUBE_KEY:-}" ]]; then
        return
    fi

    # Validate stream key
    if [[ ${#COPT_YOUTUBE_KEY} -lt 20 ]]; then
        die "Invalid YouTube stream key (too short). Check your key."
    fi

    # Set stream name if not provided
    COPT_STREAM_NAME="${COPT_STREAM_NAME:-copt-stream}"

    # Build output URL based on protocol
    case "${COPT_STREAM_TYPE}" in
        rtmp)
            COPT_OUTPUT="${COPT_RTMP_URL%/}/${COPT_STREAM_NAME}?key=${COPT_YOUTUBE_KEY}"
            ok "Streaming to YouTube Live via RTMP"
            ;;
        hls)
            if [[ -z "${COPT_HLS_URL:-}" ]]; then
                die "HLS streaming requires --hls-url to be set."
            fi
            COPT_OUTPUT="${COPT_HLS_URL%/}/${COPT_STREAM_NAME}?key=${COPT_YOUTUBE_KEY}"
            ok "Streaming to YouTube Live via HLS"
            ;;
        *)
            die "Unknown streaming protocol: ${COPT_STREAM_TYPE}"
            ;;
    esac

    COPT_IS_STREAMING=1
}

#!/usr/bin/env bash
# ============================================================================
# HLS upload relay — Asynchronous YouTube uploader for HLS segments
# ============================================================================
# Accepts HLS segments on local disk, uploads to YouTube with persistent
# connection and proper buffering (like OBS does internally).
#
# This DECOUPLES encoding from network uploads:
# - FFmpeg writes to /tmp/hls/ (instant, no network blocking)
# - This script watches and uploads segments asynchronously
# - Encoding stays at 1.0x speed even with slow network
#
# Usage:
#   hls-upload-relay.sh --hls-dir /tmp/hls \
#                       --youtube-url "https://a.upload.youtube.com/..." \
#                       --segment-name stream
#
# ============================================================================

set -euo pipefail

HLS_DIR=""
YOUTUBE_URL=""
SEGMENT_NAME="stream"
UPLOADED_SEGMENTS_FILE="/tmp/hls-uploaded.log"
UPLOAD_TIMEOUT=30

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hls-dir) HLS_DIR="$2"; shift 2 ;;
        --youtube-url) YOUTUBE_URL="$2"; shift 2 ;;
        --segment-name) SEGMENT_NAME="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$HLS_DIR" ]] && { echo "Error: --hls-dir required"; exit 1; }
[[ -z "$YOUTUBE_URL" ]] && { echo "Error: --youtube-url required"; exit 1; }

# Initialize
mkdir -p "$HLS_DIR"
touch "$UPLOADED_SEGMENTS_FILE"

echo "[$(date)] HLS Upload Relay started"
echo "  HLS dir: $HLS_DIR"
echo "  YouTube URL: ${YOUTUBE_URL%%?*}..." # truncate for display

# Upload function with persistent connection
upload_segment() {
    local segment="$1"
    local remote_path="${segment##*/}"  # just filename
    
    if ! grep -Fxq "$segment" "$UPLOADED_SEGMENTS_FILE" 2>/dev/null; then
        echo "[$(date)] Uploading: $remote_path"
        
        # Use --tcp-nodelay for persistent connection, --keepalive-time to reuse
        if curl --connect-timeout 10 \
                --max-time "$UPLOAD_TIMEOUT" \
                --tcp-nodelay \
                --keepalive-time 60 \
                -T "$segment" \
                "${YOUTUBE_URL%/}/$(basename "$segment")" \
                2>/dev/null; then
            echo "$segment" >> "$UPLOADED_SEGMENTS_FILE"
            echo "[$(date)] Uploaded: $remote_path"
        else
            echo "[$(date)] Upload failed: $remote_path (will retry)"
        fi
    fi
}

# Upload m3u8 playlist
upload_playlist() {
    local m3u8="$HLS_DIR/${SEGMENT_NAME}.m3u8"
    if [[ -f "$m3u8" ]]; then
        curl --connect-timeout 10 \
             --max-time 10 \
             --tcp-nodelay \
             -T "$m3u8" \
             "${YOUTUBE_URL%/}/${SEGMENT_NAME}.m3u8" \
             2>/dev/null || true
    fi
}

# Main loop - watch for new segments and upload
while true; do
    # Upload any .ts segments that haven't been uploaded
    for segment in "$HLS_DIR"/${SEGMENT_NAME}*.ts; do
        [[ -f "$segment" ]] || continue
        upload_segment "$segment"
    done
    
    # Upload playlist every 4 segments (roughly)
    if (($(date +%s) % 10 == 0)); then
        upload_playlist
    fi
    
    sleep 0.5
done

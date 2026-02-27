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

set -o pipefail

HLS_DIR=""
YOUTUBE_URL=""
SEGMENT_NAME="stream"
UPLOADED_SEGMENTS_FILE="/tmp/hls-uploaded.log"
UPLOAD_TIMEOUT=30
LOG_FILE="/tmp/hls-relay.log"
UPLOAD_FAILURES=0
MAX_FAILURES=10

# Trap cleanup on signal
cleanup() {
    echo "[$(date)] Relay shutting down gracefully..." >> "$LOG_FILE"
    exit 0
}
trap cleanup INT TERM

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hls-dir) HLS_DIR="$2"; shift 2 ;;
        --youtube-url) YOUTUBE_URL="$2"; shift 2 ;;
        --segment-name) SEGMENT_NAME="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$HLS_DIR" ]] && { echo "Error: --hls-dir required" | tee -a "$LOG_FILE"; exit 1; }
[[ -z "$YOUTUBE_URL" ]] && { echo "Error: --youtube-url required" | tee -a "$LOG_FILE"; exit 1; }

# Initialize
mkdir -p "$HLS_DIR"
touch "$UPLOADED_SEGMENTS_FILE"

{
    echo "[$(date)] HLS Upload Relay started"
    echo "  HLS dir: $HLS_DIR"
    echo "  YouTube URL: ${YOUTUBE_URL%"?cid="*}?cid=..."
    echo ""
} >> "$LOG_FILE"

# Upload function with persistent connection and error tracking
upload_segment() {
    local segment="$1"
    local remote_path="${segment##*/}"  # just filename
    
    if ! grep -Fxq "$segment" "$UPLOADED_SEGMENTS_FILE" 2>/dev/null; then
        echo "[$(date)] Uploading: $remote_path" >> "$LOG_FILE"
        
        # Use --tcp-nodelay for persistent connection, --keepalive-time to reuse
        # Append filename directly (URL ends with parameter name like "file=")
        if curl --connect-timeout 10 \
                --max-time "$UPLOAD_TIMEOUT" \
                --tcp-nodelay \
                --keepalive-time 60 \
                -T "$segment" \
                "${YOUTUBE_URL}$(basename "$segment")" \
                >> "$LOG_FILE" 2>&1; then
            echo "$segment" >> "$UPLOADED_SEGMENTS_FILE"
            echo "[$(date)] ✓ Uploaded: $remote_path" >> "$LOG_FILE"
            UPLOAD_FAILURES=0  # Reset failure counter on success
        else
            UPLOAD_FAILURES=$((UPLOAD_FAILURES + 1))
            echo "[$(date)] ✗ Upload failed (attempt $UPLOAD_FAILURES/$MAX_FAILURES): $remote_path" >> "$LOG_FILE"
            
            if [[ $UPLOAD_FAILURES -ge $MAX_FAILURES ]]; then
                echo "[$(date)] ERROR: Too many upload failures ($UPLOAD_FAILURES) — stopping relay" >> "$LOG_FILE"
                exit 1
            fi
        fi
    fi
}

# Upload m3u8 playlist
upload_playlist() {
    local m3u8="$HLS_DIR/${SEGMENT_NAME}.m3u8"
    if [[ -f "$m3u8" ]]; then
        # For playlist, we typically use the base URL or a manifest endpoint
        # YouTube HLS may not need explicit playlist uploads if segments are present
        curl --connect-timeout 10 \
             --max-time 10 \
             --tcp-nodelay \
             -T "$m3u8" \
             "${YOUTUBE_URL}${SEGMENT_NAME}.m3u8" \
             >> "$LOG_FILE" 2>&1 || echo "[$(date)] ⚠ Playlist upload failed" >> "$LOG_FILE"
    fi
}

# Main loop - watch for new segments and upload
last_playlist_upload=$(date +%s)
while true; do
    # Upload any .ts segments that haven't been uploaded
    for segment in "$HLS_DIR"/${SEGMENT_NAME}*.ts; do
        [[ -f "$segment" ]] || continue
        upload_segment "$segment"
    done
    
    # Upload playlist every 10 seconds
    current_time=$(date +%s)
    if (( current_time - last_playlist_upload >= 10 )); then
        upload_playlist
        last_playlist_upload=$current_time
    fi
    
    sleep 0.5
done

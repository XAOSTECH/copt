#!/usr/bin/env bash
# ============================================================================
# extract-logo-reference — Capture UGREEN idle logo for detection
# ============================================================================
# Captures one frame of the UGREEN logo that appears when no input connected.
# This reference frame is used by smart logo detection to hide the logo only
# when it's actually showing (not during real content).
#
# Usage: sudo ./extract-logo-reference.sh [device]
#        sudo ./extract-logo-reference.sh /dev/usb-video-capture1
#
# Output: cfg/ugreen-logo-reference.png
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COPT_ROOT="$(dirname "$SCRIPT_DIR")"
COPT_CFG="${COPT_ROOT}/cfg"

DEVICE="${1:-/dev/usb-video-capture1}"
OUTPUT="${COPT_CFG}/ugreen-logo-reference.png"

# Colours
C_GRN='\033[0;32m' C_YEL='\033[0;33m' C_RED='\033[0;31m' C_RST='\033[0m'
ok()   { printf "${C_GRN}[OK]${C_RST}  %s\n" "$*"; }
warn() { printf "${C_YEL}[!!]${C_RST}  %s\n" "$*"; }
err()  { printf "${C_RED}[ERR]${C_RST} %s\n" "$*"; }
die()  { err "$@"; exit 1; }

echo ""
echo "  UGREEN Logo Reference Extractor"
echo "  ================================"
echo ""

[[ -c "$DEVICE" ]] || die "Device not found: ${DEVICE}"
ok "Device: ${DEVICE}"

# Check if input is connected
warn "DISCONNECT all inputs from UGREEN capture card now!"
warn "The device should show only the UGREEN logo/idle screen."
echo ""
read -p "Press ENTER when ready (logo visible on preview)... "

echo ""
echo "Capturing reference frame..."
ffmpeg -hide_banner -loglevel error -y \
    -f v4l2 -input_format yuv420p -video_size 3840x2160 -framerate 30 \
    -i "$DEVICE" \
    -frames:v 1 \
    "$OUTPUT" || die "Failed to capture frame"

if [[ -f "$OUTPUT" ]]; then
    size=$(stat --printf='%s' "$OUTPUT")
    ok "Reference saved: ${OUTPUT} ($(numfmt --to=iec "$size"))"
    echo ""
    echo "Now you can enable smart logo detection in profiles:"
    echo "  COPT_LOGO_DETECT=1"
    echo "  COPT_LOGO_REFERENCE=${OUTPUT}"
    echo "  COPT_LOGO_COORDS=x:y:w:h  # coordinates of logo region"
    echo ""
    echo "Or run pick-logo-coords.sh to select the region visually."
else
    die "Failed to create ${OUTPUT}"
fi

#!/usr/bin/env bash
# ============================================================================
# pick-logo-coords — Interactively select UGREEN logo region
# ============================================================================
# Launches live preview and lets you select the logo area to hide.
# Works with 'slop' (visual selection) or manual coordinate entry.
#
# Usage: sudo ./pick-logo-coords.sh [device]
#        sudo ./pick-logo-coords.sh /dev/usb-video-capture1
#
# Output: Prints coordinates to add to your profile config
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE="${1:-/dev/usb-video-capture1}"

# Colours
C_GRN='\033[0;32m' C_CYN='\033[0;36m' C_RED='\033[0;31m' C_RST='\033[0m'
ok()   { printf "${C_GRN}[OK]${C_RST}  %s\n" "$*"; }
info() { printf "[${C_CYN}INFO${C_RST}] %s\n" "$*"; }
die()  { printf "${C_RED}[ERR]${C_RST} %s\n" "$*"; exit 1; }

echo ""
echo "  UGREEN Logo Region Selector"
echo "  ============================"
echo ""

[[ -c "$DEVICE" ]] || die "Device not found: ${DEVICE}"
ok "Device: ${DEVICE}"

if command -v slop &>/dev/null; then
    info "slop detected — visual selection available"
    read -rp "Use visual selection? (Y/n): " choice
    choice="${choice:-y}"
else
    info "slop not installed — manual coordinate entry only"
    echo "  Install: sudo apt install slop"
    choice="n"
fi

if [[ "$choice" =~ ^[Yy]$ ]]; then
    info "Launching ffplay preview..."
    info "1. Wait for UGREEN logo to appear in preview"
    info "2. Click and drag in the ffplay window to select logo region"
    info "3. Selection tool will capture the rectangle"
    echo ""
    
    # Launch preview in background
    ffplay -noborder -autoexit -x 1280 -y 720 \
        -f v4l2 -input_format yuv420p -video_size 3840x2160 -framerate 30 \
        -i "$DEVICE" &>/dev/null &
    FF_PID=$!
    
    sleep 2  # Let preview initialize
    
    info "Preview running (PID: ${FF_PID})"
    info "Use slop to select the logo rectangle..."
    
    # Capture selection
    if RECT=$(slop -f "%x:%y:%w:%h" 2>/dev/null); then
        kill "$FF_PID" 2>/dev/null || true
        wait "$FF_PID" 2>/dev/null || true
        
        X=$(echo "$RECT" | cut -d: -f1)
        Y=$(echo "$RECT" | cut -d: -f2)
        W=$(echo "$RECT" | cut -d: -f3)
        H=$(echo "$RECT" | cut -d: -f4)
        
        # Scale from preview (1280x720) to native (3840x2160) — 3x multiplier
        X=$((X * 3))
        Y=$((Y * 3))
        W=$((W * 3))
        H=$((H * 3))
    else
        kill "$FF_PID" 2>/dev/null || true
        die "No selection captured"
    fi
else
    # Manual entry
    info "Enter logo coordinates (at 3840x2160 resolution):"
    read -rp "  X (left edge): " X
    read -rp "  Y (top edge): " Y
    read -rp "  Width: " W
    read -rp "  Height: " H
fi

# Validate numbers
[[ "$X" =~ ^[0-9]+$ ]] || die "Invalid X coordinate"
[[ "$Y" =~ ^[0-9]+$ ]] || die "Invalid Y coordinate"
[[ "$W" =~ ^[0-9]+$ ]] || die "Invalid width"
[[ "$H" =~ ^[0-9]+$ ]] || die "Invalid height"

echo ""
ok "Logo region captured:"
echo "  X=$X Y=$Y W=$W H=$H"
echo ""
echo "Add to your profile (e.g., cfg/profiles/usb-capture-4k30-hdr.conf):"
echo ""
echo "  # Smart logo detection"
echo "  COPT_LOGO_DETECT=1"
echo "  COPT_LOGO_COORDS=\"${X}:${Y}:${W}:${H}\""
echo "  COPT_LOGO_METHOD=drawbox     # or 'delogo' for blur"
echo ""

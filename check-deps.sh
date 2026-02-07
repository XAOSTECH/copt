#!/usr/bin/env bash
# ============================================================================
# check-deps.sh — Check and install copt dependencies
# ============================================================================
# Verifies required and optional dependencies are installed.
# Required: FFmpeg (with KMS grab, hardware encoders)
# Optional: xdotool (window capture), ALSA utils (audio), FFtools
#
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================

set -euo pipefail

# Colours
C_GRN='\033[0;32m' C_YEL='\033[0;33m' C_RED='\033[0;31m' C_CYN='\033[0;36m' C_RST='\033[0m'
ok()   { printf "${C_GRN}[OK]${C_RST}  %s\n" "$*"; }
warn() { printf "${C_YEL}[!!]${C_RST}  %s\n" "$*"; }
err()  { printf "${C_RED}[ERR]${C_RST} %s\n" "$*"; }
info() { printf "[${C_CYN}INFO${C_RST}]  %s\n" "$*"; }

# Track status
missing_required=0
missing_optional=0

info "Checking copt dependencies…"
echo ""

# ----- Check Required Dependencies -----
printf "${C_CYN}=== REQUIRED ===${C_RST}\n"

# FFmpeg
if command -v ffmpeg &>/dev/null; then
    ffmpeg_version=$(ffmpeg -version 2>/dev/null | head -n1 | awk '{print $3}')
    ok "FFmpeg: $ffmpeg_version"
    
    # Check for kmsgrab support
    if ffmpeg -hide_banner -formats 2>/dev/null | grep -q kmsgrab; then
        ok "  ↳ KMS grab support: YES"
    else
        warn "  ↳ KMS grab support: NO (needed for Wayland capture)"
        missing_required=$((missing_required + 1))
    fi
    
    # Check for hardware encoders
    encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null || true)
    has_nvenc=0
    has_vaapi=0
    has_x264=0
    
    [[ $(echo "$encoders" | grep -c "h264_nvenc\|hevc_nvenc" || true) -gt 0 ]] && has_nvenc=1
    [[ $(echo "$encoders" | grep -c "h264_vaapi\|hevc_vaapi" || true) -gt 0 ]] && has_vaapi=1
    [[ $(echo "$encoders" | grep -c "libx264\|libx265" || true) -gt 0 ]] && has_x264=1
    
    if [[ $((has_nvenc + has_vaapi + has_x264)) -gt 0 ]]; then
        encoders_found=""
        [[ $has_nvenc -eq 1 ]] && encoders_found="NVENC "
        [[ $has_vaapi -eq 1 ]] && encoders_found+="VAAPI "
        [[ $has_x264 -eq 1 ]] && encoders_found+="libx264/x265"
        ok "  ↳ Video encoders: $encoders_found"
    else
        err "  ↳ Video encoders: NONE (install FFmpeg with at least libx264)"
        missing_required=$((missing_required + 1))
    fi
else
    err "FFmpeg: NOT FOUND"
    missing_required=$((missing_required + 1))
fi

echo ""

# ----- Check Optional Dependencies -----
printf "${C_CYN}=== OPTIONAL ===${C_RST}\n"

# xdotool (preferred for window detection)
if command -v xdotool &>/dev/null; then
    xdotool_version=$(xdotool --version 2>/dev/null | awk '{print $1}')
    ok "xdotool: $xdotool_version (window capture)"
else
    warn "xdotool: NOT FOUND (needed for --window flag)"
    missing_optional=$((missing_optional + 1))
fi

# wmctrl (fallback for window detection)
if command -v wmctrl &>/dev/null; then
    ok "wmctrl: installed (window detection fallback)"
else
    warn "wmctrl: NOT FOUND (fallback window detection)"
    missing_optional=$((missing_optional + 1))
fi

# ALSA utils (audio)
if command -v arecord &>/dev/null; then
    ok "ALSA: installed (audio capture)"
else
    warn "ALSA utilities: NOT FOUND (audio capture will fail)"
    missing_optional=$((missing_optional + 1))
fi

# FFtools
if command -v ffprobe &>/dev/null; then
    ok "ffprobe: installed (diagnostics)"
else
    warn "ffprobe: NOT FOUND (optional diagnostics)"
    missing_optional=$((missing_optional + 1))
fi

echo ""

# ----- Summary -----
if [[ $missing_required -eq 0 ]]; then
    ok "All required dependencies installed!"
else
    err "$missing_required required dependencies missing."
fi

if [[ $missing_optional -gt 0 ]]; then
    if [[ $missing_required -eq 0 ]]; then
        warn "$missing_optional optional dependencies missing (may limit features)."
    else
        warn "Also $missing_optional optional dependencies missing."
    fi
fi

echo ""

# ----- Install Missing -----
if [[ $missing_required -gt 0 || $missing_optional -gt 0 ]]; then
    read -p "Install missing packages? (requires sudo) [y/N] " -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        apt_packages=()
        
        # Add xdotool if missing
        [[ ! -x "$(command -v xdotool)" ]] && apt_packages+=(xdotool)
        
        # Add wmctrl if missing
        [[ ! -x "$(command -v wmctrl)" ]] && apt_packages+=(wmctrl)
        
        # Add ALSA if missing
        [[ ! -x "$(command -v arecord)" ]] && apt_packages+=(alsa-utils)
        
        # Add ffmpeg tools if missing
        [[ ! -x "$(command -v ffprobe)" ]] && apt_packages+=(ffmpeg)
        
        if [[ ${#apt_packages[@]} -gt 0 ]]; then
            info "Installing: ${apt_packages[*]}"
            sudo apt-get update
            sudo apt-get install -y "${apt_packages[@]}"
            ok "Installation complete!"
        else
            info "All installable packages already present."
        fi
    else
        warn "Skipped installation. Some features may not work."
    fi
fi

echo ""
info "Run 'copt --help' to get started."

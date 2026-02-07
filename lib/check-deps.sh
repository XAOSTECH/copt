#!/usr/bin/env bash
# ============================================================================
# check-deps.sh — Check and install copt dependencies
# ============================================================================
# Verifies required and optional dependencies are installed.
# Required: FFmpeg (with KMS grab, hardware encoders)
# Optional: xdotool (window capture), ALSA utils (audio), FFtools
#
# Usage:
#   check-deps.sh                    # Check all dependencies
#   check-deps.sh --install          # Check and install missing packages
#   check-deps.sh --install-window   # Install only window capture tools
#   check-deps.sh --help             # Show this help
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
usage() {
    cat << 'EOF'
check-deps — Check and install copt dependencies

USAGE:
    check-deps.sh                    Check all dependencies
    check-deps.sh --install          Check and install missing packages
    check-deps.sh --install-window   Install only window capture tools
    check-deps.sh --help             Show this help

DEPENDENCIES:
  Required:
    - FFmpeg (with kmsgrab for Wayland capture)
    - Hardware encoder support (NVENC, VAAPI, or libx264/x265)
  
  Optional:
    - xdotool or wmctrl (window capture via --window flag)
    - ALSA utilities (audio capture)
    - ffprobe (diagnostics)

EXAMPLES:
    sudo check-deps.sh                 # Check what's missing
    sudo check-deps.sh --install       # Install everything missing
    sudo check-deps.sh --install-window # Just install window tools

EOF
}

# ============================================================================
# Detect package manager
# ============================================================================
detect_package_manager() {
    if command -v apt-get &>/dev/null; then
        export PKG_MGR="apt-get"
        export PKG_UPDATE="apt-get update"
        export PKG_INSTALL="apt-get install -y"
        export XDOTOOL_PKG="xdotool"
        export WMCTRL_PKG="wmctrl"
        export ALSA_PKG="alsa-utils"
        export FFMPEG_PKG="ffmpeg"
        return 0
    elif command -v dnf &>/dev/null; then
        export PKG_MGR="dnf"
        export PKG_UPDATE="dnf makecache"
        export PKG_INSTALL="dnf install -y"
        export XDOTOOL_PKG="xdotool"
        export WMCTRL_PKG="wmctrl"
        export ALSA_PKG="alsa-utils"
        export FFMPEG_PKG="ffmpeg"
        return 0
    elif command -v pacman &>/dev/null; then
        export PKG_MGR="pacman"
        export PKG_UPDATE="pacman -Sy"
        export PKG_INSTALL="pacman -S --noconfirm"
        export XDOTOOL_PKG="xdotool"
        export WMCTRL_PKG="wmctrl"
        export ALSA_PKG="alsa-utils"
        export FFMPEG_PKG="ffmpeg"
        return 0
    elif command -v brew &>/dev/null; then
        export PKG_MGR="brew"
        export PKG_UPDATE="brew update"
        export PKG_INSTALL="brew install"
        export XDOTOOL_PKG="xdotool"
        export WMCTRL_PKG="wmctrl"
        export ALSA_PKG="portaudio"
        export FFMPEG_PKG="ffmpeg"
        return 0
    else
        err "No supported package manager found (apt, dnf, pacman, brew)"
        return 1
    fi
}

# ============================================================================
# Check dependencies
# ============================================================================
check_dependencies() {
    local missing_required=0
    local missing_optional=0

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
    return $((missing_required + missing_optional))
}

# ============================================================================
# Install dependencies
# ============================================================================
install_dependencies() {
    local apt_packages=()

    info "Installing missing dependencies…"
    echo ""

    # Add packages to install
    [[ ! -x "$(command -v xdotool)" ]] && apt_packages+=(xdotool)
    [[ ! -x "$(command -v wmctrl)" ]] && apt_packages+=(wmctrl)
    [[ ! -x "$(command -v arecord)" ]] && apt_packages+=(alsa-utils)
    [[ ! -x "$(command -v ffprobe)" ]] && apt_packages+=(ffmpeg)

    if [[ ${#apt_packages[@]} -eq 0 ]]; then
        ok "All dependencies already installed!"
        return 0
    fi

    # Update package manager
    info "Updating package lists…"
    $PKG_UPDATE || warn "Failed to update (non-fatal)"
    echo ""

    # Install packages
    info "Installing: ${apt_packages[*]}"
    if $PKG_INSTALL "${apt_packages[@]}"; then
        ok "Installation successful!"
    else
        err "Installation failed. Some packages may already be installed."
        return 1
    fi

    echo ""
    return 0
}

# ============================================================================
# Install only window capture tools
# ============================================================================
install_window_tools() {
    local apt_packages=()

    info "Installing window capture tools…"
    echo ""

    [[ ! -x "$(command -v xdotool)" ]] && apt_packages+=(xdotool)
    [[ ! -x "$(command -v wmctrl)" ]] && apt_packages+=(wmctrl)

    if [[ ${#apt_packages[@]} -eq 0 ]]; then
        ok "Window capture tools already installed!"
        return 0
    fi

    # Update package manager
    info "Updating package lists…"
    $PKG_UPDATE || warn "Failed to update (non-fatal)"
    echo ""

    # Install packages
    info "Installing: ${apt_packages[*]}"
    if $PKG_INSTALL "${apt_packages[@]}"; then
        ok "Installation successful!"
    else
        err "Installation failed."
        return 1
    fi

    echo ""
    return 0
}

# ============================================================================
# Main
# ============================================================================
main() {
    local mode="${1:-check}"

    case "$mode" in
        --help|-h)
            usage
            exit 0
            ;;
        --install-window)
            [[ $EUID -ne 0 ]] && { err "Installation requires root. Run: sudo $0 $mode"; exit 1; }
            detect_package_manager || exit 1
            install_window_tools
            exit 0
            ;;
        --install)
            [[ $EUID -ne 0 ]] && { err "Installation requires root. Run: sudo $0 $mode"; exit 1; }
            detect_package_manager || exit 1
            check_dependencies
            local status=$?
            echo ""
            if [[ $status -gt 0 ]]; then
                read -p "Install missing packages? [y/N] " -r
                echo ""
                [[ $REPLY =~ ^[Yy]$ ]] && install_dependencies || warn "Skipped installation."
            fi
            exit 0
            ;;
        check|"")
            detect_package_manager || exit 1
            check_dependencies
            exit $?
            ;;
        *)
            err "Unknown mode: $mode"
            usage
            exit 1
            ;;
    esac
}

main "$@"

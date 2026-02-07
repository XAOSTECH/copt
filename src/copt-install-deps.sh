#!/usr/bin/env bash
# ============================================================================
# copt-install-deps — Install optional dependencies for copt
# ============================================================================
# Installs recommended packages for full copt functionality:
# - xdotool: Window detection and geometry tracking
# - wmctrl: Alternative window management
#
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================

set -euo pipefail

# Colours
C_GRN='\033[0;32m' C_YEL='\033[0;33m' C_RED='\033[0;31m' C_RST='\033[0m'
ok()   { printf "${C_GRN}[OK]${C_RST}  %s\n" "$*"; }
warn() { printf "${C_YEL}[!!]${C_RST}  %s\n" "$*"; }
err()  { printf "${C_RED}[ERR]${C_RST} %s\n" "$*"; }
info() { printf "[INFO]  %s\n" "$*"; }

# Check for root
if [[ $EUID -ne 0 ]]; then
    err "Installation requires root. Run with: sudo $0"
    exit 1
fi

info "Installing copt optional dependencies..."
echo ""

# Detect package manager
if command -v apt-get &>/dev/null; then
    info "Detected: apt (Debian/Ubuntu)"
    PKG_MGR="apt-get"
    XDOTOOL_PKG="xdotool"
    WMCTRL_PKG="wmctrl"
    UPDATE_CMD="apt-get update"
    INSTALL_CMD="apt-get install -y"
elif command -v dnf &>/dev/null; then
    info "Detected: dnf (Fedora/RHEL)"
    PKG_MGR="dnf"
    XDOTOOL_PKG="xdotool"
    WMCTRL_PKG="wmctrl"
    UPDATE_CMD="dnf makecache"
    INSTALL_CMD="dnf install -y"
elif command -v pacman &>/dev/null; then
    info "Detected: pacman (Arch/Manjaro)"
    PKG_MGR="pacman"
    XDOTOOL_PKG="xdotool"
    WMCTRL_PKG="wmctrl"
    UPDATE_CMD="pacman -Sy"
    INSTALL_CMD="pacman -S --noconfirm"
elif command -v brew &>/dev/null; then
    info "Detected: brew (macOS)"
    PKG_MGR="brew"
    XDOTOOL_PKG="xdotool"
    WMCTRL_PKG="wmctrl"
    UPDATE_CMD="brew update"
    INSTALL_CMD="brew install"
else
    err "No supported package manager found (apt, dnf, pacman, brew)"
    err "Please install xdotool or wmctrl manually for window capture."
    exit 1
fi

echo ""

# Update package lists
info "Updating package lists..."
$UPDATE_CMD || warn "Failed to update package lists (non-fatal)"

echo ""

# Install xdotool (preferred)
info "[1/2] Installing xdotool (preferred for window capture)..."
if $INSTALL_CMD $XDOTOOL_PKG; then
    ok "xdotool installed successfully"
    has_xdotool=1
else
    warn "Failed to install xdotool"
    has_xdotool=0
fi

echo ""

# Install wmctrl (fallback)
info "[2/2] Installing wmctrl (fallback for window capture)..."
if $INSTALL_CMD $WMCTRL_PKG; then
    ok "wmctrl installed successfully"
    has_wmctrl=1
else
    warn "Failed to install wmctrl"
    has_wmctrl=0
fi

echo ""

# Verify installation
xdotool_check=$(command -v xdotool >/dev/null 2>&1 && echo "yes" || echo "no")
wmctrl_check=$(command -v wmctrl >/dev/null 2>&1 && echo "yes" || echo "no")

printf "Installation status:\n"
printf "  xdotool : %s\n" "$([[ $xdotool_check == "yes" ]] && echo -e "${C_GRN}installed${C_RST}" || echo -e "${C_RED}not available${C_RST}")"
printf "  wmctrl  : %s\n" "$([[ $wmctrl_check == "yes" ]] && echo -e "${C_GRN}installed${C_RST}" || echo -e "${C_RED}not available${C_RST}")"

echo ""

# Test functionality
if [[ $xdotool_check == "yes" ]]; then
    info "Testing xdotool..."
    if xdotool search --name "." >/dev/null 2>&1; then
        ok "xdotool is working correctly"
        echo ""
        info "Available windows:"
        xdotool search --name "." | while read -r wid; do
            wname=$(xdotool getwindowname "$wid" 2>/dev/null || echo "unknown")
            printf "  - %s\n" "$wname"
        done | head -10
    fi
    echo ""
fi

if [[ $wmctrl_check == "yes" ]]; then
    info "Testing wmctrl..."
    if wmctrl -l >/dev/null 2>&1; then
        ok "wmctrl is working correctly"
        echo ""
        info "Available windows:"
        wmctrl -l | awk '{print $NF}' | head -10 | while read -r wname; do
            printf "  - %s\n" "$wname"
        done
    fi
    echo ""
fi

# Final summary
echo ""
if [[ $xdotool_check == "yes" || $wmctrl_check == "yes" ]]; then
    ok "Window capture dependencies installed!"
    echo ""
    info "You can now use window capture with copt:"
    info "  sudo copt --window \"Window Name\" -o output.mkv"
    info "  sudo copt-autorestart --window \"Game Name\" -y STREAM_KEY"
    echo ""
    info "Find window names with:"
    if [[ $xdotool_check == "yes" ]]; then
        info "  xdotool search --name \"partial name\""
    fi
    if [[ $wmctrl_check == "yes" ]]; then
        info "  wmctrl -l"
    fi
else
    err "No window capture tools installed!"
    err "Please install xdotool or wmctrl manually."
    exit 1
fi

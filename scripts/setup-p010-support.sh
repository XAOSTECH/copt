#!/bin/bash
###############################################################################
# Setup P010 HDR Kernel Module for Linux v4l2
#
# Enables native 10-bit P010 format support for UVC devices (UGREEN 25173, etc)
# on Linux systems using DKMS (Dynamic Kernel Module Support).
#
# Credit: @awawa-dev (https://github.com/awawa-dev/P010_for_V4L2)
#
# Usage:
#   sudo ./setup-p010-support.sh          # Interactive (detects OS)
#   sudo ./setup-p010-support.sh rpi      # Force Raspberry Pi OS
#   sudo ./setup-p010-support.sh ubuntu   # Force Debian/Ubuntu x64
#   sudo ./setup-p010-support.sh check    # Check if already installed
###############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P010_DIR="$(dirname "$SCRIPT_DIR")/P010_for_V4L2"
LOG_FILE="/tmp/p010-install-$(date +%s).log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

###############################################################################
# Helper Functions
###############################################################################

log_info() {
    echo -e "${BLUE}[*]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[✗]${NC} $*" | tee -a "$LOG_FILE"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root. Try: sudo $0"
        exit 1
    fi
}

check_submodule() {
    if [ ! -d "$P010_DIR" ]; then
        log_error "P010_for_V4L2 submodule not found at: $P010_DIR"
        log_error "Make sure to initialize git submodules: git submodule update --init"
        exit 1
    fi
    log_success "P010_for_V4L2 submodule found"
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" == "raspbian" ]] || grep -q "Raspberry Pi" /boot/cmdline.txt 2>/dev/null; then
            echo "rpi"
        elif [[ "$ID" == "ubuntu" ]] || [[ "$ID_LIKE" == *"debian"* ]]; then
            echo "ubuntu"
        else
            echo "unknown"
        fi
    else
        echo "unknown"
    fi
}

check_installed() {
    if dkms status v4l2-p010 2>/dev/null | grep -q "installed"; then
        log_success "P010 kernel module is already installed"
        v4l2-ctl -d /dev/video0 --list-formats-ext 2>/dev/null | grep -i p010 && \
            log_success "P010 format recognized by v4l2" || \
            log_warning "P010 module installed but not recognized - may need reboot"
        return 0
    else
        return 1
    fi
}

check_secure_boot() {
    local sb_status=""
    
    # Try mokutil first
    if command -v mokutil &> /dev/null; then
        sb_status=$(mokutil --sb-state 2>/dev/null || echo "")
        if echo "$sb_status" | grep -qi "SecureBoot enabled"; then
            return 0  # Secure Boot is enabled
        elif echo "$sb_status" | grep -qi "SecureBoot disabled"; then
            return 1  # Secure Boot is disabled
        fi
    fi
    
    # Fallback: check EFI vars
    if [ -f /sys/firmware/efi/efivars/SecureBoot-* ] || [ -f /sys/firmware/efi/vars/SecureBoot-* ]; then
        return 0  # Likely enabled
    fi
    
    return 1  # Assume disabled or not applicable
}

warn_secure_boot() {
    log_warning "═══════════════════════════════════════════════════════════"
    log_warning "  SECURE BOOT DETECTED"
    log_warning "═══════════════════════════════════════════════════════════"
    log_error "The P010 kernel module will NOT work with Secure Boot enabled!"
    log_error ""
    log_error "The patched uvcvideo module is unsigned and will be rejected"
    log_error "by the kernel, causing your USB capture device to stop working."
    log_error ""
    log_info "Choose one option before proceeding:"
    log_info ""
    log_info "Option 1 - Disable Secure Boot (RECOMMENDED):"
    log_info "  1. Reboot into BIOS/UEFI (F2, F12, Del, or Esc at boot)"
    log_info "  2. Find Security settings"
    log_info "  3. Disable Secure Boot"
    log_info "  4. Save and reboot"
    log_info "  5. Run this script again"
    log_info ""
    log_info "Option 2 - Sign the module (ADVANCED):"
    log_info "  After installation, sign with Machine Owner Key (MOK)"
    log_info "  See: https://ubuntu.com/blog/how-to-sign-things-for-secure-boot"
    log_info ""
    log_warning "═══════════════════════════════════════════════════════════"
    log_error "Installation ABORTED to protect your device"
    log_warning "═══════════════════════════════════════════════════════════"
    return 1
}

install_prerequisites() {
    log_info "Installing build prerequisites..."
    apt-get update >> "$LOG_FILE" 2>&1
    apt-get install -y --no-install-recommends \
        dkms \
        build-essential \
        bc \
        wget \
        ca-certificates \
        linux-headers-"$(uname -r)" \
        >> "$LOG_FILE" 2>&1 || {
        log_error "Failed to install prerequisites"
        return 1
    }
    log_success "Prerequisites installed"
    return 0
}

install_dkms() {
    local os_type
    if [ "$1" == "auto" ]; then
        os_type=$(detect_os)
    else
        os_type="$1"
    fi

    log_info "Detected OS: $os_type"

    case "$os_type" in
        rpi)
            log_info "Running DKMS installer for Raspberry Pi OS..."
            bash "$P010_DIR/dkms-installer.sh" 1 >> "$LOG_FILE" 2>&1 || {
                log_error "DKMS installation failed"
                return 1
            }
            ;;
        ubuntu)
            log_info "Running DKMS installer for Debian/Ubuntu..."
            bash "$P010_DIR/dkms-installer.sh" 2 >> "$LOG_FILE" 2>&1 || {
                log_error "DKMS installation failed"
                return 1
            }
            ;;
        unknown)
            log_error "Could not detect OS type"
            log_error "Please manually run: sudo $P010_DIR/dkms-installer.sh"
            return 1
            ;;
    esac

    log_success "DKMS installation complete"
    return 0
}

verify_installation() {
    log_info "Verifying installation..."

    if ! dkms status v4l2-p010 2>/dev/null | grep -q "installed"; then
        log_warning "P010 module not found in dkms - this may require a reboot"
        return 0
    fi

    log_success "P010 module installed via DKMS"

    # Try to detect with v4l2-ctl if available
    if command -v v4l2-ctl &> /dev/null; then
        if v4l2-ctl -d /dev/video0 --list-formats-ext 2>/dev/null | grep -q -i "p010\|P010"; then
            log_success "P010 format detected in v4l2!"
            return 0
        else
            log_warning "P010 format not yet visible - may need reboot to load module"
            log_info "Test after reboot with: v4l2-ctl -d /dev/video0 --list-formats-ext | grep -i p010"
            return 0
        fi
    fi

    return 0
}

uninstall_p010() {
    log_info "Uninstalling P010 kernel module..."
    
    if ! dkms status v4l2-p010 2>/dev/null | grep -q "installed"; then
        log_warning "P010 module is not installed"
        return 0
    fi
    
    # Unload the module if it's loaded
    if lsmod | grep -q uvcvideo; then
        log_info "Unloading uvcvideo module..."
        modprobe -r uvcvideo >> "$LOG_FILE" 2>&1 || log_warning "Could not unload uvcvideo"
    fi
    
    # Remove from DKMS
    log_info "Removing P010 module from DKMS..."
    dkms remove v4l2-p010/1.0 --all >> "$LOG_FILE" 2>&1 || {
        log_error "Failed to remove DKMS module"
        return 1
    }
    
    # Rebuild module dependencies
    log_info "Rebuilding kernel module dependencies..."
    depmod -a >> "$LOG_FILE" 2>&1
    
    # Reload original uvcvideo
    log_info "Loading original uvcvideo driver..."
    modprobe uvcvideo >> "$LOG_FILE" 2>&1 || {
        log_warning "Could not load uvcvideo - may need reboot"
    }
    
    # Give it a moment to initialize
    sleep 2
    
    # Verify device is back
    if v4l2-ctl --list-devices 2>/dev/null | grep -q "video"; then
        log_success "USB video device restored successfully!"
    else
        log_warning "No video devices found - reboot may be required"
    fi
    
    log_success "P010 module uninstalled"
    log_info "Run 'v4l2-ctl --list-devices' to verify your device"
    return 0
}

show_usage() {
    cat <<EOF
${BLUE}P010 HDR Kernel Support Installer${NC}

Usage: sudo $0 [OPTION]

Options:
  (none)     Interactive mode - auto-detect OS
  check      Check if P010 is already installed
  uninstall  Remove P010 module and restore original driver
  rpi        Force Raspberry Pi OS installation
  ubuntu     Force Debian/Ubuntu x64 installation
  help       Show this help message

Examples:
  sudo $0                  # Auto-detect and install
  sudo $0 check            # Check installation status
  sudo $0 uninstall        # Remove P010 and restore original
  sudo $0 rpi              # Install for Raspberry Pi OS
  sudo $0 ubuntu           # Install for Ubuntu/Debian

Requirements:
  - Root/sudo access
  - Git submodule initialized (at ../P010_for_V4L2)
  - Internet connection
  - gcc, make, bc
  - Linux headers for current kernel
  - Secure Boot DISABLED (or module signing configured)

${YELLOW}IMPORTANT - Secure Boot:${NC}
  This module patches the kernel's uvcvideo driver. If Secure Boot is
  enabled, the unsigned module will be REJECTED and your USB capture
  device will STOP WORKING. Disable Secure Boot before installation!

After Installation:
  1. Reboot system: sudo reboot
  2. Verify P010 format is available:
     v4l2-ctl -d /dev/video0 --list-formats-ext | grep -i p010
  3. Test capture with FFmpeg:
     ffmpeg -f v4l2 -input_format p010 -video_size 3840x2160 -framerate 30 -i /dev/video0 -t 5 test.mp4

${RED}Recovery (if device stops working):${NC}
  1. Remove patched module:
     sudo dkms remove v4l2-p010/1.0 --all
  2. Rebuild dependencies:
     sudo depmod -a
  3. Load original driver:
     sudo modprobe uvcvideo
  4. Verify device returns:
     v4l2-ctl --list-devices

Troubleshooting:
  - Check logs: tail -f /tmp/p010-install-*.log
  - Manual DKMS: $P010_DIR/dkms-installer.sh [1|2]
  - Full rebuild: dkms remove v4l2-p010/1.0 && dkms add -m v4l2-p010 -v 1.0

Credit: @awawa-dev (https://github.com/awawa-dev/P010_for_V4L2)
EOF
}

###############################################################################
# Main Script
###############################################################################

main() {
    log_info "P010 HDR Kernel Module Installer"
    log_info "Logging to: $LOG_FILE"

    check_root
    check_submodule

    case "${1:-auto}" in
        check)
            if check_installed; then
                exit 0
            else
                log_error "P010 module not installed"
                exit 1
            fi
            ;;
        uninstall)
            if ! uninstall_p010; then
                log_error "Uninstallation failed - see logs in $LOG_FILE"
                exit 1
            fi
            exit 0
            ;;
        help)
            show_usage
            exit 0
            ;;
        rpi|ubuntu|auto)
            if check_installed; then
                log_info "P010 already installed, skipping installation"
                verify_installation
                exit 0
            fi

            log_warning "This will modify kernel modules"
            log_warning "Ensure system is fully updated before proceeding"

            # Check for Secure Boot before proceeding
            if check_secure_boot; then
                warn_secure_boot
                exit 1
            fi

            if ! install_prerequisites; then
                log_error "Failed to install prerequisites"
                exit 1
            fi

            if ! install_dkms "${1:-auto}"; then
                log_error "Installation failed - see logs in $LOG_FILE"
                exit 1
            fi

            verify_installation

            log_success "Installation complete!"
            log_info ""
            log_info "IMPORTANT: Reboot required for changes to take effect"
            log_info "         sudo reboot"
            log_info ""
            log_info "After reboot, verify P010 support:"
            log_info "  v4l2-ctl -d /dev/video0 --list-formats-ext | grep -i p010"
            ;;
        *)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"

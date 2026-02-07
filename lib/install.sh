#!/usr/bin/env bash
# ============================================================================
# copt installer — Install binaries and verify dependencies
# ============================================================================
set -euo pipefail

readonly PREFIX="${PREFIX:-/usr/local}"
readonly BINDIR="${PREFIX}/bin"
readonly LIBDIR="${PREFIX}/lib/copt"
readonly CONFDIR="${XDG_CONFIG_HOME:-$HOME/.config}/copt"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(dirname "$SCRIPT_DIR")"

C_GRN='\033[0;32m' C_YEL='\033[0;33m' C_RED='\033[0;31m' C_CYN='\033[0;36m' C_RST='\033[0m'
ok()   { printf "${C_GRN}[OK]${C_RST}  %s\n" "$*"; }
warn() { printf "${C_YEL}[!!]${C_RST}  %s\n" "$*"; }
err()  { printf "${C_RED}[ERR]${C_RST} %s\n" "$*"; }
info() { printf "[${C_CYN}INFO${C_RST}] %s\n" "$*"; }

# Parse args
INSTALL_MISSING=0
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install) INSTALL_MISSING=1; shift ;;
        --check)   CHECK_ONLY=1; shift ;;
        --help|-h)
            cat << 'EOF'
copt installer — Install binaries and verify dependencies

USAGE:
    install.sh           Install copt and check dependencies
    install.sh --check   Only check dependencies (no install)
    install.sh --install Install copt and auto-install missing packages

DEPENDENCIES:
  Required:
    - FFmpeg (with kmsgrab for Wayland KMS capture)
    - Hardware encoder (NVENC, VAAPI, or libx264/x265)
  
  Optional:
    - ALSA utilities (audio capture)
    - ffprobe (diagnostics)

EXAMPLES:
    sudo bash install.sh              # Install and check
    sudo bash install.sh --install    # Install + auto-fix dependencies
    bash install.sh --check           # Just check dependencies

EOF
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ============================================================================
# Check Dependencies
# ============================================================================
check_dependencies() {
    local missing_required=0
    local missing_optional=0
    local packages_needed=()

    info "Checking dependencies…"
    echo ""

    # FFmpeg (required)
    if command -v ffmpeg &>/dev/null; then
        ffmpeg_ver=$(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}')
        ok "FFmpeg: $ffmpeg_ver"
        
        # Check KMS grab support
        if ffmpeg -hide_banner -formats 2>/dev/null | grep -q kmsgrab; then
            ok "  ↳ KMS grab: YES"
        else
            err "  ↳ KMS grab: NO (required for Wayland capture)"
            missing_required=$((missing_required + 1))
        fi
        
        # Check for hardware encoders
        has_encoder=0
        if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_nvenc\|h264_vaapi\|libx264"; then
            has_encoder=1
            ok "  ↳ Hardware encoders: YES"
        else
            warn "  ↳ Hardware encoders: NO"
        fi
    else
        err "FFmpeg: NOT FOUND"
        missing_required=$((missing_required + 1))
    fi

    # ALSA (optional but recommended)
    if command -v arecord &>/dev/null; then
        ok "ALSA: installed"
    else
        warn "ALSA: not found (audio capture disabled)"
        packages_needed+=(alsa-utils)
        missing_optional=$((missing_optional + 1))
    fi

    # ffprobe (optional)
    if command -v ffprobe &>/dev/null; then
        ok "ffprobe: installed"
    else
        warn "ffprobe: not found (optional)"
        missing_optional=$((missing_optional + 1))
    fi

    echo ""
    
    # Summary
    if [[ $missing_required -eq 0 ]]; then
        ok "All required dependencies satisfied!"
    else
        err "$missing_required required dependencies missing"
        return 1
    fi
    
    if [[ $missing_optional -gt 0 ]]; then
        warn "$missing_optional optional dependencies missing"
    fi
    
    # Install missing packages if requested
    if [[ ${#packages_needed[@]} -gt 0 ]] && [[ $INSTALL_MISSING -eq 1 ]]; then
        echo ""
        info "Installing missing packages: ${packages_needed[*]}"
        
        if command -v apt-get &>/dev/null; then
            apt-get update -qq
            apt-get install -y "${packages_needed[@]}"
            ok "Packages installed"
        elif command -v dnf &>/dev/null; then
            dnf install -y "${packages_needed[@]}"
            ok "Packages installed"
        elif command -v pacman &>/dev/null; then
            pacman -S --noconfirm "${packages_needed[@]}"
            ok "Packages installed"
        else
            warn "No known package manager. Install manually: ${packages_needed[*]}"
        fi
    elif [[ ${#packages_needed[@]} -gt 0 ]]; then
        echo ""
        info "To install missing packages, run: sudo bash install.sh --install"
    fi
    
    return 0
}

# ============================================================================
# Install binaries
# ============================================================================
if [[ $CHECK_ONLY -eq 1 ]]; then
    check_dependencies
    exit $?
fi

echo "Installing copt to ${PREFIX} …"
echo ""

# Install binaries
sudo install -Dm755 "${SCRIPT_DIR}/../src/copt.sh" "${BINDIR}/copt"
ok "Installed ${BINDIR}/copt"

sudo install -Dm755 "${SCRIPT_DIR}/../src/copt-autorestart.sh" "${BINDIR}/copt-autorestart"
ok "Installed ${BINDIR}/copt-autorestart"

# Install libraries and config
sudo mkdir -p "${LIBDIR}/lib" "${LIBDIR}/cfg"
sudo cp -r "${ROOT_DIR}/lib/"* "${LIBDIR}/lib/" 2>/dev/null || true
sudo cp -r "${ROOT_DIR}/cfg/"* "${LIBDIR}/cfg/" 2>/dev/null || true
ok "Installed libraries to ${LIBDIR}"

# Install user config (don't overwrite if exists)
mkdir -p "$CONFDIR"
if [[ ! -f "${CONFDIR}/copt.conf" ]] && [[ -f "${ROOT_DIR}/copt.conf.example" ]]; then
    cp "${ROOT_DIR}/copt.conf.example" "${CONFDIR}/copt.conf"
    ok "Installed config ${CONFDIR}/copt.conf"
elif [[ -f "${CONFDIR}/copt.conf" ]]; then
    warn "Config already exists at ${CONFDIR}/copt.conf"
fi

echo ""

# Check dependencies
check_dependencies

echo ""
ok "Done!  Run:  sudo copt --help"

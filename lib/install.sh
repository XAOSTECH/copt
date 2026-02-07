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

# ============================================================================
# Check Dependencies
# ============================================================================
info "Checking dependencies…"
echo ""

missing=0

# FFmpeg (required)
if command -v ffmpeg &>/dev/null; then
    ffmpeg_ver=$(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}')
    ok "FFmpeg: $ffmpeg_ver"
    
    # Check KMS grab support
    if ffmpeg -hide_banner -formats 2>/dev/null | grep -q kmsgrab; then
        ok "  ↳ KMS grab: YES"
    else
        err "  ↳ KMS grab: NO (required for Wayland capture)"
        missing=$((missing + 1))
    fi
else
    err "FFmpeg: NOT FOUND (required for video capture)"
    missing=$((missing + 1))
fi

# ALSA (optional but recommended for audio)
if command -v arecord &>/dev/null; then
    ok "ALSA: installed"
else
    warn "ALSA: not found (audio capture disabled)"
fi

# ffprobe (optional diagnostics)
if command -v ffprobe &>/dev/null; then
    ok "ffprobe: installed"
else
    warn "ffprobe: not found (optional)"
fi

echo ""
if [[ $missing -eq 0 ]]; then
    ok "All required dependencies satisfied!"
else
    err "$missing required dependencies missing"
fi

echo ""
ok "Done!  Run:  sudo copt --help"
fi

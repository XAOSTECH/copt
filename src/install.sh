#!/usr/bin/env bash
# ============================================================================
# copt installer
# ============================================================================
set -euo pipefail

readonly PREFIX="${PREFIX:-/usr/local}"
readonly BINDIR="${PREFIX}/bin"
readonly LIBDIR="${PREFIX}/lib/copt"
readonly CONFDIR="${XDG_CONFIG_HOME:-$HOME/.config}/copt"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(dirname "$SCRIPT_DIR")"

C_GRN='\033[0;32m' C_YEL='\033[0;33m' C_RST='\033[0m'
ok()   { printf "${C_GRN}[OK]${C_RST}  %s\n" "$*"; }
warn() { printf "${C_YEL}[!!]${C_RST}  %s\n" "$*"; }

echo "Installing copt to ${PREFIX} …"

# Install binary
sudo install -Dm755 "${SCRIPT_DIR}/copt.sh" "${BINDIR}/copt"
ok "Installed ${BINDIR}/copt"

# Install autorestart wrapper
sudo install -Dm755 "${SCRIPT_DIR}/copt-autorestart.sh" "${BINDIR}/copt-autorestart"
ok "Installed ${BINDIR}/copt-autorestart"

# Install library modules
sudo mkdir -p "${LIBDIR}/lib" "${LIBDIR}/cfg"
sudo cp -r "${ROOT_DIR}/lib/"* "${LIBDIR}/lib/"
sudo cp -r "${ROOT_DIR}/cfg/"* "${LIBDIR}/cfg/"
ok "Installed libraries to ${LIBDIR}"

# Install example config (don't overwrite existing)
mkdir -p "$CONFDIR"
if [[ ! -f "${CONFDIR}/copt.conf" ]]; then
    cp "${ROOT_DIR}/copt.conf.example" "${CONFDIR}/copt.conf"
    ok "Installed config ${CONFDIR}/copt.conf"
else
    warn "Config already exists at ${CONFDIR}/copt.conf — skipping."
    warn "See copt.conf.example for new options."
fi

echo ""
ok "Done!  Run:  sudo copt --help"
echo ""

# Quick system check
if ! command -v ffmpeg &>/dev/null; then
    warn "ffmpeg not found in PATH — you need FFmpeg with kmsgrab support."
fi

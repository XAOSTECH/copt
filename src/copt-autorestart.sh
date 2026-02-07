#!/usr/bin/env bash
# ============================================================================
# copt-autorestart — Auto-restart wrapper for copt
# ============================================================================
# Monitors copt and automatically restarts it on crash or OOM kill.
# Useful for long-running streams that need reliability.
#
# Usage:  sudo copt-autorestart [COPT_OPTIONS]
# Example:  sudo copt-autorestart -y STREAM_KEY
#
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================

set -euo pipefail

# Colours for logging
C_GRN='\033[0;32m' C_YEL='\033[0;33m' C_RED='\033[0;31m' C_RST='\033[0m'
ok()   { printf "${C_GRN}[OK]${C_RST}  %s\n" "$*"; }
warn() { printf "${C_YEL}[!!]${C_RST}  %s\n" "$*"; }
err()  { printf "${C_RED}[ERR]${C_RST} %s\n" "$*"; }
info() { printf "[INFO]  %s\n" "$*"; }

# Check for root privileges early
if [[ $EUID -ne 0 ]]; then
    err "copt requires root access for KMS framebuffer."
    err "Run with: sudo copt-autorestart [OPTIONS]"
    exit 1
fi

# Configuration
readonly MAX_RETRIES="${COPT_MAX_RETRIES:-0}"        # 0 = infinite
readonly RESTART_DELAY="${COPT_RESTART_DELAY:-5}"   # seconds between restarts
# Use /var/log if writable (system install) or /tmp with unique name
if [[ -w /var/log ]]; then
    readonly LOG_FILE="${COPT_LOG_FILE:-/var/log/copt-autorestart.log}"
else
    readonly LOG_FILE="${COPT_LOG_FILE:-/tmp/copt-autorestart-${USER}.log}"
fi

# State
retry_count=0
start_time=$(date +%s)

# Find copt binary
COPT_BIN="${COPT_BIN:-}"
if [[ -z "$COPT_BIN" ]]; then
    # Check multiple locations in order
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    copt_root=$(dirname "$script_dir")
    
    if [[ -x "/usr/local/bin/copt" ]]; then
        COPT_BIN="/usr/local/bin/copt"
    elif [[ -x "${copt_root}/src/copt.sh" ]]; then
        COPT_BIN="${copt_root}/src/copt.sh"
    elif [[ -x "./src/copt.sh" ]]; then
        COPT_BIN="./src/copt.sh"
    elif [[ -x "./copt.sh" ]]; then
        COPT_BIN="./copt.sh"
    elif [[ -x "/workspaces/copt/src/copt.sh" ]]; then
        COPT_BIN="/workspaces/copt/src/copt.sh"
    else
        err "copt binary not found. Checked:"
        err "  /usr/local/bin/copt"
        err "  ${copt_root}/src/copt.sh"
        err "  ./src/copt.sh"
        err "  ./copt.sh"
        err "  /workspaces/copt/src/copt.sh"
        err ""
        err "Set COPT_BIN to the full path: COPT_BIN=/path/to/copt sudo copt-autorestart"
        exit 1
    fi
fi

info "Auto-restart wrapper for copt"
info "Binary: $COPT_BIN"
info "Max retries: $([[ $MAX_RETRIES -eq 0 ]] && echo "infinite" || echo "$MAX_RETRIES")"
info "Restart delay: ${RESTART_DELAY}s"
info "Log file: $LOG_FILE"

# Ensure log file is writable
touch "$LOG_FILE" 2>/dev/null || {
    err "Cannot write to log file: $LOG_FILE"
    err "Set COPT_LOG_FILE to a writable location."
    exit 1
}

echo ""

# Signal handling for graceful shutdown
trap 'info "Shutting down auto-restart wrapper..."; exit 0' SIGINT SIGTERM

# Main restart loop
while true; do
    retry_count=$((retry_count + 1))
    
    # Check max retries
    if [[ $MAX_RETRIES -gt 0 && $retry_count -gt $MAX_RETRIES ]]; then
        err "Max retries ($MAX_RETRIES) reached. Giving up."
        exit 1
    fi
    
    # Log attempt
    echo "==================== Attempt #${retry_count} at $(date) ====================" >> "$LOG_FILE"
    
    if [[ $retry_count -eq 1 ]]; then
        ok "Starting copt (attempt #${retry_count})"
    else
        warn "Restarting copt (attempt #${retry_count})"
    fi
    
    # Run copt and capture exit code
    set +e
    "$COPT_BIN" "$@" 2>&1 | tee -a "$LOG_FILE"
    exit_code=$?
    set -e
    
    # Analyse exit code
    case $exit_code in
        0)
            ok "copt exited normally (exit code 0)"
            info "Total runtime: $(($(date +%s) - start_time)) seconds"
            exit 0
            ;;
        137)
            warn "copt killed by SIGKILL (exit 137) — likely OOM (out of memory)"
            warn "Consider reducing quality, resolution, or bitrate"
            ;;
        130)
            info "copt interrupted by user (Ctrl-C)"
            exit 0
            ;;
        143)
            info "copt terminated by SIGTERM"
            exit 0
            ;;
        *)
            warn "copt crashed with exit code: $exit_code"
            ;;
    esac
    
    # Wait before restart
    info "Waiting ${RESTART_DELAY} seconds before restart..."
    sleep "$RESTART_DELAY"
    echo ""
done

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
# SPDX-Licence-Identifier: GPL-3.0-or-later
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
readonly USB_AWARE="${COPT_USB_AUTORESTART:-1}"     # 1 = log USB disconnect patterns
readonly USB_VID_PID="${COPT_USB_VID_PID:-3188:1000}"  # USB device to watch for (UGREEN 25173)
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
    
    # Run copt; stdout+stderr go to terminal AND the log file
    set +e
    "$COPT_BIN" "$@" 2>&1 | tee -a "$LOG_FILE"
    exit_code=$?
    set -e

    # --- USB disconnect detection (from log tail) ---
    # copt's built-in run_with_usb_reconnect handles device-level reconnects,
    # but if it exhausts COPT_USB_MAX_RECONNECTS the whole process exits.
    # Detect that here so we can give a targeted message and wait longer.
    usb_disconnect=0
    if [[ "${USB_AWARE}" -eq 1 ]]; then
        if tail -200 "$LOG_FILE" 2>/dev/null | grep -qiE \
            'Device.*disconnected|select timed out|No such device|USB.*lost|Maximum USB reconnect'; then
            usb_disconnect=1
        fi
    fi

    if [[ $usb_disconnect -eq 1 ]]; then
        warn "USB capture device disconnect detected in log"
        warn "Device: ${USB_VID_PID} — waiting for it to reappear before restarting..."
        # Poll lsusb until the device shows up (or 120s max)
        usb_elapsed=0
        while [[ $usb_elapsed -lt 120 ]]; do
            if lsusb 2>/dev/null | grep -qi "$USB_VID_PID"; then
                ok "USB device ${USB_VID_PID} found on bus — proceeding to restart"
                sleep 3   # settle delay
                break
            fi
            sleep 2; usb_elapsed=$((usb_elapsed + 2))
        done
        if [[ $usb_elapsed -ge 120 ]]; then
            err "USB device ${USB_VID_PID} did not reappear in 120s"
        fi
    fi
    
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
        7)
            # SIGBUS — can occur when the USB device is yanked mid-DMA
            warn "copt terminated by SIGBUS (exit 7) — possible hardware/USB fault"
            [[ $usb_disconnect -eq 1 ]] && warn "Consistent with USB-C bus instability"
            ;;
        11)
            # SIGSEGV — the 'double free or corruption' crash
            warn "copt segfaulted (exit 11) — possible 'double free or corruption' from USB disconnect"
            [[ $usb_disconnect -eq 1 ]] && warn "Consistent with UGREEN 25173 USB-C instability"
            warn "Hardware tip: replace USB-C cable / update motherboard BIOS / use USB 3.0 port"
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

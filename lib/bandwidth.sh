#!/usr/bin/env bash
# ============================================================================
# lib/bandwidth.sh — Bandwidth-adaptive profile adjustment
# ============================================================================
# Automatically adjusts encoding parameters to fit within a maximum bandwidth
# limit by reducing resolution, framerate, or bitrate.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================

# ----- bandwidth adaptation logic -------------------------------------------
adapt_profile_to_bandwidth() {
    local max_mbps="${COPT_BANDWIDTH_MAX_MBPS:-0}"
    
    # Skip adaptation if no limit set
    if [[ "$max_mbps" -le 0 ]]; then
        return 0
    fi
    
    # Calculate total required bitrate (video + audio) in kbps
    local video_kbps=0
    local audio_kbps=0
    
    # Extract numeric value from video bitrate (e.g., "25000k" -> 25000)
    if [[ -n "${COPT_BITRATE_VIDEO:-}" ]]; then
        video_kbps=$(echo "${COPT_BITRATE_VIDEO}" | sed 's/[^0-9]//g')
    fi
    
    # Extract numeric value from audio bitrate (default 192k if not set)
    if [[ -n "${COPT_BITRATE_AUDIO:-}" ]]; then
        audio_kbps=$(echo "${COPT_BITRATE_AUDIO}" | sed 's/[^0-9]//g')
    else
        audio_kbps=192
    fi
    
    local total_kbps=$((video_kbps + audio_kbps))
    local total_mbps=$((total_kbps / 1000))
    local max_kbps=$((max_mbps * 1000))
    
    info "Bandwidth check: ${total_mbps}Mbps required, ${max_mbps}Mbps available"
    
    # If within limits, no adjustment needed
    if [[ $total_kbps -le $max_kbps ]]; then
        ok "Profile fits within bandwidth limit"
        return 0
    fi
    
    warn "Profile exceeds bandwidth limit (${total_mbps}Mbps > ${max_mbps}Mbps)"
    info "Adapting encoding parameters..."
    
    # Strategy: reduce in this order:
    # 1. Framerate (60fps -> 30fps)
    # 2. Resolution (4K -> 1080p)
    # 3. Bitrate proportionally
    
    # Step 1: Reduce framerate if 60fps
    if [[ "${COPT_FRAMERATE:-30}" -eq 60 ]]; then
        COPT_FRAMERATE=30
        video_kbps=$((video_kbps * 75 / 100))  # -25% for 30fps
        COPT_BITRATE_VIDEO="${video_kbps}k"
        [[ -n "${COPT_GOP_SIZE:-}" ]] && COPT_GOP_SIZE=60
        info "→ Reduced framerate: 60fps → 30fps"
        
        total_kbps=$((video_kbps + audio_kbps))
        total_mbps=$((total_kbps / 1000))
        
        if [[ $total_kbps -le $max_kbps ]]; then
            ok "Adapted profile fits bandwidth: ${total_mbps}Mbps"
            return 0
        fi
    fi
    
    # Step 2: Reduce resolution if 4K
    if [[ "${COPT_OUT_W:-1920}" -ge 3840 ]]; then
        COPT_OUT_W=1920
        COPT_OUT_H=1080
        video_kbps=$((video_kbps * 30 / 100))  # 4K->1080p ~70% reduction
        COPT_BITRATE_VIDEO="${video_kbps}k"
        info "→ Reduced resolution: 4K → 1080p"
        
        total_kbps=$((video_kbps + audio_kbps))
        total_mbps=$((total_kbps / 1000))
        
        if [[ $total_kbps -le $max_kbps ]]; then
            ok "Adapted profile fits bandwidth: ${total_mbps}Mbps"
            return 0
        fi
    fi
    
    # Step 3: Reduce bitrate proportionally to fit
    local target_video_kbps=$((max_kbps - audio_kbps - 500))  # Reserve 500kbps overhead
    
    if [[ $target_video_kbps -lt 1000 ]]; then
        die "Bandwidth too low for streaming (min 2Mbps required, ${max_mbps}Mbps available)"
    fi
    
    COPT_BITRATE_VIDEO="${target_video_kbps}k"
    info "→ Reduced bitrate: ${video_kbps}k → ${target_video_kbps}k"
    
    total_kbps=$((target_video_kbps + audio_kbps))
    total_mbps=$((total_kbps / 1000))
    ok "Adapted profile fits bandwidth: ${total_mbps}Mbps"
}

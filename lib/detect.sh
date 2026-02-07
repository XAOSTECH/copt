#!/usr/bin/env bash
# ============================================================================
# copt — System detection functions
# ============================================================================
# Auto-detection for screen resolution, DRI devices, audio, and encoders
# ============================================================================

# ----- detect screen resolution ---------------------------------------------
detect_screen_resolution() {
    # Try multiple methods to detect native screen resolution
    local detected_w detected_h

    # Method 1: xrandr (works on X11 and some Wayland)
    if command -v xrandr &>/dev/null; then
        local xrandr_out
        xrandr_out=$(xrandr 2>/dev/null | grep -E "^[^ ].*connected" | head -1)
        if [[ -n "$xrandr_out" ]]; then
            # Extract resolution like "1920x1080" from xrandr output
            if [[ $xrandr_out =~ ([0-9]+)x([0-9]+) ]]; then
                detected_w="${BASH_REMATCH[1]}"
                detected_h="${BASH_REMATCH[2]}"
                if [[ -n "$detected_w" && -n "$detected_h" ]]; then
                    COPT_SCREEN_W="$detected_w"
                    COPT_SCREEN_H="$detected_h"
                    ok "Auto-detected screen resolution: ${COPT_SCREEN_W}x${COPT_SCREEN_H}"
                    return
                fi
            fi
        fi
    fi

    # Method 2: weston-info (Wayland-specific)
    if command -v weston-info &>/dev/null; then
        local weston_out
        weston_out=$(weston-info 2>/dev/null | grep "geometry:" | head -1)
        if [[ -n "$weston_out" ]]; then
            # Extract from "geometry: 0, 0, 1920, 1080"
            if [[ $weston_out =~ ([0-9]+),\ ([0-9]+)$ ]]; then
                detected_w="${BASH_REMATCH[1]}"
                detected_h="${BASH_REMATCH[2]}"
                if [[ -n "$detected_w" && -n "$detected_h" ]]; then
                    COPT_SCREEN_W="$detected_w"
                    COPT_SCREEN_H="$detected_h"
                    ok "Auto-detected screen resolution: ${COPT_SCREEN_W}x${COPT_SCREEN_H}"
                    return
                fi
            fi
        fi
    fi

    # Fallback: keep defaults (user can override with -W/-H)
    warn "Could not auto-detect screen resolution. Using defaults: ${COPT_SCREEN_W}x${COPT_SCREEN_H}"
    warn "To override, use: -W WIDTH -H HEIGHT"
}

# ----- detect DRI device ----------------------------------------------------
detect_dri_device() {
    if [[ -n "$COPT_DRI_DEVICE" ]]; then
        [[ -e "$COPT_DRI_DEVICE" ]] || die "DRI device not found: $COPT_DRI_DEVICE"
        return
    fi
    # Prefer card1 (often the discrete GPU), fall back to card0
    for card in /dev/dri/card{1,0}; do
        if [[ -e "$card" ]]; then
            COPT_DRI_DEVICE="$card"
            ok "Auto-detected DRI device: $COPT_DRI_DEVICE"
            return
        fi
    done
    die "No DRI device found in /dev/dri/. Is the GPU driver loaded?"
}

# ----- detect audio device --------------------------------------------------
detect_audio_device() {
    [[ "$COPT_AUDIO" -eq 0 ]] && return
    if [[ -n "$COPT_AUDIO_DEVICE" ]]; then return; fi

    # Try to find a usable ALSA capture/playback device
    if [[ -r /proc/asound/cards ]]; then
        local card_num
        card_num=$(awk '/^ *[0-9]/ {print $1; exit}' /proc/asound/cards)
        if [[ -n "$card_num" ]]; then
            # Find the first digital or analogue output subdevice
            if [[ -r /proc/asound/devices ]]; then
                local dev_line
                dev_line=$(grep -E "audio (capture|playback)" /proc/asound/devices | head -1)
                if [[ -n "$dev_line" ]]; then
                    local raw
                    raw=$(echo "$dev_line" | grep -oP '\[\s*\K[0-9]+-\s*[0-9]+' | tr -d ' ')
                    if [[ -n "$raw" ]]; then
                        local c d
                        c="${raw%%-*}"
                        d="${raw##*-}"
                        COPT_AUDIO_DEVICE="hw:${c},${d}"
                        ok "Auto-detected ALSA device: $COPT_AUDIO_DEVICE"
                        return
                    fi
                fi
            fi
            COPT_AUDIO_DEVICE="hw:${card_num},0"
            ok "Fallback ALSA device: $COPT_AUDIO_DEVICE"
            return
        fi
    fi

    warn "Could not auto-detect audio device. Disabling audio."
    warn "List devices with:  cat /proc/asound/cards && cat /proc/asound/devices"
    COPT_AUDIO=0
}

# ----- detect encoder -------------------------------------------------------
detect_encoder() {
    if [[ "$COPT_ENCODER" != "auto" ]]; then return; fi

    local encoders
    encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null || true)

    # Check VAAPI
    if echo "$encoders" | grep -q h264_vaapi; then
        if [[ -e /dev/dri/renderD128 ]]; then
            COPT_ENCODER="vaapi"
            ok "Auto-selected encoder: VAAPI (h264_vaapi)"
            return
        fi
    fi

    # Check NVENC
    if echo "$encoders" | grep -q h264_nvenc; then
        COPT_ENCODER="nvenc"
        ok "Auto-selected encoder: NVENC (h264_nvenc)"
        return
    fi

    # Fallback to software x264
    if echo "$encoders" | grep -q libx264; then
        COPT_ENCODER="x264"
        warn "No hardware encoder found. Falling back to libx264 (CPU)."
        return
    fi

    die "No usable H.264 encoder found. Install FFmpeg with libx264, VAAPI, or NVENC support."
}

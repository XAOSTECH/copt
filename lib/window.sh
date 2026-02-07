#!/usr/bin/env bash
# ============================================================================
# lib/window.sh — Window detection and geometry tracking
# ============================================================================
# Detects X11/XWayland windows by name and tracks their geometry for
# targeted screen capture instead of full-screen KMS grab.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================

# ----- window detection -----------------------------------------------------
detect_window() {
    local window_name="${COPT_WINDOW_NAME:-}"
    
    # Skip if no window specified
    if [[ -z "$window_name" ]]; then
        return 0
    fi
    
    info "Searching for window: $window_name"
    
    # Try xdotool first (most reliable for window search)
    if command -v xdotool &>/dev/null; then
        detect_window_xdotool "$window_name"
        return $?
    fi
    
    # Fallback to wmctrl
    if command -v wmctrl &>/dev/null; then
        detect_window_wmctrl "$window_name"
        return $?
    fi
    
    # Fallback to xwininfo (requires exact window ID)
    if command -v xwininfo &>/dev/null; then
        warn "xwininfo available but requires window ID. Install xdotool or wmctrl for name-based search."
        warn "Falling back to full-screen capture."
        COPT_WINDOW_NAME=""
        return 0
    fi
    
    warn "No window detection tools found (xdotool, wmctrl). Install xdotool for window capture."
    warn "Falling back to full-screen capture."
    COPT_WINDOW_NAME=""
    return 0
}

# ----- xdotool-based window detection ---------------------------------------
detect_window_xdotool() {
    local window_name="$1"
    local window_id
    
    # Search for window by name (case-insensitive, partial match)
    window_id=$(xdotool search --name "$window_name" 2>/dev/null | head -n1)
    
    if [[ -z "$window_id" ]]; then
        die "Window not found: '$window_name'. Check window name with: wmctrl -l"
    fi
    
    # Get window geometry
    local geom_output
    geom_output=$(xdotool getwindowgeometry "$window_id" 2>/dev/null)
    
    if [[ -z "$geom_output" ]]; then
        die "Failed to get window geometry for window ID: $window_id"
    fi
    
    # Parse geometry: Position: X,Y and Geometry: WxH
    local pos_x pos_y win_w win_h
    pos_x=$(echo "$geom_output" | grep "Position:" | awk '{print $2}' | cut -d',' -f1)
    pos_y=$(echo "$geom_output" | grep "Position:" | awk '{print $2}' | cut -d',' -f2)
    win_w=$(echo "$geom_output" | grep "Geometry:" | awk '{print $2}' | cut -d'x' -f1)
    win_h=$(echo "$geom_output" | grep "Geometry:" | awk '{print $2}' | cut -d'x' -f2)
    
    # Validate geometry
    if [[ -z "$pos_x" || -z "$pos_y" || -z "$win_w" || -z "$win_h" ]]; then
        die "Failed to parse window geometry from xdotool output"
    fi
    
    # Store window info
    COPT_WINDOW_ID="$window_id"
    COPT_CROP_X="$pos_x"
    COPT_CROP_Y="$pos_y"
    COPT_CROP_W="$win_w"
    COPT_CROP_H="$win_h"
    
    # Default output size to window size (can be overridden)
    if [[ "${COPT_OUT_W:-0}" -eq 0 || "${COPT_OUT_W}" -eq 1920 ]]; then
        COPT_OUT_W="$win_w"
    fi
    if [[ "${COPT_OUT_H:-0}" -eq 0 || "${COPT_OUT_H}" -eq 1080 ]]; then
        COPT_OUT_H="$win_h"
    fi
    
    ok "Found window '$window_name' (ID: $window_id) at ${pos_x},${pos_y} - ${win_w}x${win_h}"
}

# ----- wmctrl-based window detection ----------------------------------------
detect_window_wmctrl() {
    local window_name="$1"
    local window_line
    
    # Search for window by name (case-insensitive grep)
    window_line=$(wmctrl -lG 2>/dev/null | grep -i "$window_name" | head -n1)
    
    if [[ -z "$window_line" ]]; then
        die "Window not found: '$window_name'. Available windows:\n$(wmctrl -l)"
    fi
    
    # Parse wmctrl output: ID DESKTOP X Y W H HOSTNAME TITLE
    local window_id desktop pos_x pos_y win_w win_h
    read -r window_id desktop pos_x pos_y win_w win_h _ <<< "$window_line"
    
    # Validate geometry
    if [[ -z "$pos_x" || -z "$pos_y" || -z "$win_w" || -z "$win_h" ]]; then
        die "Failed to parse window geometry from wmctrl output"
    fi
    
    # Store window info
    COPT_WINDOW_ID="$window_id"
    COPT_CROP_X="$pos_x"
    COPT_CROP_Y="$pos_y"
    COPT_CROP_W="$win_w"
    COPT_CROP_H="$win_h"
    
    # Default output size to window size (can be overridden)
    if [[ "${COPT_OUT_W:-0}" -eq 0 || "${COPT_OUT_W}" -eq 1920 ]]; then
        COPT_OUT_W="$win_w"
    fi
    if [[ "${COPT_OUT_H:-0}" -eq 0 || "${COPT_OUT_H}" -eq 1080 ]]; then
        COPT_OUT_H="$win_h"
    fi
    
    ok "Found window '$window_name' (ID: $window_id) at ${pos_x},${pos_y} - ${win_w}x${win_h}"
}

# ----- window tracking (detect movement/resize) -----------------------------
track_window_geometry() {
    local window_id="${COPT_WINDOW_ID:-}"
    
    # Skip if no window tracking
    if [[ -z "$window_id" ]]; then
        return 0
    fi
    
    # Only track if xdotool is available
    if ! command -v xdotool &>/dev/null; then
        return 0
    fi
    
    # Get current geometry
    local geom_output
    geom_output=$(xdotool getwindowgeometry "$window_id" 2>/dev/null || echo "")
    
    if [[ -z "$geom_output" ]]; then
        warn "Window $window_id no longer exists or is not visible"
        return 1
    fi
    
    # Parse current position
    local new_x new_y new_w new_h
    new_x=$(echo "$geom_output" | grep "Position:" | awk '{print $2}' | cut -d',' -f1)
    new_y=$(echo "$geom_output" | grep "Position:" | awk '{print $2}' | cut -d',' -f2)
    new_w=$(echo "$geom_output" | grep "Geometry:" | awk '{print $2}' | cut -d'x' -f1)
    new_h=$(echo "$geom_output" | grep "Geometry:" | awk '{print $2}' | cut -d'x' -f2)
    
    # Check if window moved or resized
    if [[ "$new_x" != "${COPT_CROP_X}" || "$new_y" != "${COPT_CROP_Y}" || \
          "$new_w" != "${COPT_CROP_W}" || "$new_h" != "${COPT_CROP_H}" ]]; then
        warn "Window geometry changed: ${new_x},${new_y} - ${new_w}x${new_h}"
        return 1
    fi
    
    return 0
}

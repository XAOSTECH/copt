#!/usr/bin/env bash
# ============================================================================
# copt — System probe functions
# ============================================================================
# Inspects hardware and displays available devices and encoders
# ============================================================================

# ----- probe system ---------------------------------------------------------
probe_system() {
    echo ""
    printf "${C_BLD}=== copt system probe ===${C_RST}\n\n"

    printf "${C_CYN}DRI devices:${C_RST}\n"
    if ls /dev/dri/card* 2>/dev/null; then true; else echo "  (none found)"; fi
    echo ""

    printf "${C_CYN}Render nodes:${C_RST}\n"
    if ls /dev/dri/render* 2>/dev/null; then true; else echo "  (none found)"; fi
    echo ""

    printf "${C_CYN}ALSA cards:${C_RST}\n"
    if [[ -r /proc/asound/cards ]]; then cat /proc/asound/cards; else echo "  (none found)"; fi
    echo ""

    printf "${C_CYN}ALSA devices:${C_RST}\n"
    if [[ -r /proc/asound/devices ]]; then cat /proc/asound/devices; else echo "  (none found)"; fi
    echo ""

    printf "${C_CYN}FFmpeg HW encoders:${C_RST}\n"
    ffmpeg -hide_banner -encoders 2>/dev/null | grep -E '(vaapi|nvenc|qsv|amf)' || echo "  (none found)"
    echo ""

    printf "${C_CYN}Kernel:${C_RST}\n"
    uname -r
    echo ""

    printf "${C_CYN}GPU info:${C_RST}\n"
    if command -v lspci &>/dev/null; then
        lspci | grep -iE '(vga|3d|display)' 2>/dev/null || echo "  (none found)"
    else
        echo "  (lspci not available)"
    fi
    echo ""

    exit 0
}

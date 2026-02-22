# USB Capture Setup (UGREEN 25173 & Similar)

## Quick Setup

### 1. Install udev rule for stable device naming

```bash
# Install the udev rule (run on HOST, not in container)
sudo cp udev/99-usb-video-capture.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=video4linux

# Verify the symlink was created
ls -la /dev/usb-video-capture1
# Should show: /dev/usb-video-capture1 -> video0 (or video1, etc.)
```

This creates `/dev/usb-video-capture1` → stable symlink that survives USB re-enumeration.
Numbered (N=1) to allow additional devices as `usb-video-capture2`, etc.

### 2. Add user to video group

```bash
sudo usermod -aG video $USER
# Log out and back in for group change to take effect
```

### 3. Test capture

```bash
# From source directory
WEB/CST/copt/src/copt-host.sh --dry-run -o /tmp/test.mkv

# Or from installed symlink
copt-host --dry-run -o /tmp/test.mkv
```

### 4. Stream to YouTube (with HDR)

```bash
# Set your HLS endpoint in cfg/.env
echo "YT_HLS_URL=https://a.upload.youtube.com/http_upload_hls" >> cfg/.env
echo "YT_API_KEY=your-stream-key-here" >> cfg/.env

# Start streaming
copt-host --hls -y YOUR_STREAM_KEY
```

---

## HDR Capture Explained

### How HDR-Capable Capture Cards Work

The UGREEN 25173 and similar devices encode 10-bit HDR into an 8-bit YUV 4:2:0 stream:

- **V4L2 reports**: sRGB/Rec.709 colorspace (Standard Dynamic Range tags)
- **Actual content**: HDR signal with LUT/codec embedded in 8-bit values
- **ffmpeg pipeline**: Extract 8-bit → expand to p010le (10-bit) → tag output as BT.2020/PQ

The device handles HDR encoding internally. No colorspace reinterpretation needed - we just:
1. Read 8-bit yuv420p from V4L2
2. Expand to p010le (10-bit, left-shift only)
3. Tag OUTPUT stream with HDR metadata (BT.2020/SMPTE 2084/PQ)

### Verification

```bash
# Check device colorspace
v4l2-ctl -d /dev/usb-video-capture1 --all | grep -i "color\|transfer\|primaries"

# Expected output:
#   Colorspace: sRGB
#   Transfer Function: Rec. 709
# (This is normal for HDR-capable cards - ignore these tags)
```

---

## Logo Detection (Optional)

Hide the UGREEN idle screen logo when no input is connected:

### Pick logo coordinates

```bash
# Visual selection (requires slop)
sudo apt install slop
cd /workspaces/CST/copt
sudo ./scripts/pick-logo-coords.sh /dev/usb-video-capture1
```

Or use pre-extracted coordinates for UGREEN 25173:
```
x=576, y=980, w=2688, h=200
```

### Enable in profile

Edit `cfg/profiles/usb-capture-4k30-hdr.conf`:
```bash
COPT_LOGO_DETECT=1                    # Enable logo hiding
COPT_LOGO_COORDS="576:980:2688:200"   # Already configured!
COPT_LOGO_METHOD=drawbox              # Black box (cleanest)
```

---

## Troubleshooting

### Device not found errors

```bash
# Check USB device is detected
lsusb | grep 3188:1000

# Check video node exists
ls -la /dev/video* /dev/usb-video-capture*

# Reload udev rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=video4linux
```

### Container exec mode fails

If you see "Exec mode: exec" but want "Host mode":

```bash
# Run from source directory (not symlink)
cd ~/PRO/WEB/CST/copt
./src/copt-host.sh --dry-run -o /tmp/test.mkv

# Or update symlink to point to source
ln -sf ~/PRO/WEB/CST/copt/src/copt-host.sh ~/bin/copt-host
```

### USB disconnect/reconnect loop

The UGREEN 25173 has USB-C instability issues. See hardware fixes:
- Replace USB-C cable with high-quality one
- Update motherboard BIOS/UEFI
- Use USB 3.0 port instead of USB-C
- Enable USB power management in BIOS

Software mitigation is automatic (auto-reconnect enabled by default).

---

## File Paths

```
cfg/
  .env                              # Secrets (YT_HLS_URL, stream keys)
  defaults.conf                     # Default variables
  profiles/
    usb-capture-4k30-hdr.conf       # 4K 30fps HDR10 PQ (recommended)
    usb-capture-4k30.conf           # 4K 30fps SDR
    usb-capture-1080p30.conf        # 1080p 30fps (stable)

src/
  copt.sh                           # Main capture script
  copt-host.sh                      # Host launcher with auto-restart
  copt-autorestart.sh               # Process-level restart wrapper

lib/
  usb-reconnect.sh                  # USB disconnect detection
  ffmpeg.sh                         # FFmpeg command builder (HDR support)
  detect.sh                         # Device auto-detection

scripts/
  pick-logo-coords.sh               # Interactive logo region selector
  extract-logo-reference.sh         # Capture logo reference frame

udev/
  99-usb-video-capture.rules         # Udev rule for stable symlink (/dev/usb-video-captureN)
```

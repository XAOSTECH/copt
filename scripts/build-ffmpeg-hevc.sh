#!/usr/bin/env bash
# Build FFmpeg with HEVC/NVENC support
# Requirements: NVIDIA driver installed (no CUDA toolkit needed)

set -e

VERSION="7.1.1"
INSTALL_PREFIX="${1:-$HOME/.local}"

echo "[*] Building FFmpeg $VERSION with HEVC/NVENC support"
echo "[*] Install prefix: $INSTALL_PREFIX"
echo ""

# Check for NVIDIA driver
if ! nvidia-smi &>/dev/null; then
    echo "[!] NVIDIA driver not found. Install driver first."
    exit 1
fi

echo "[+] NVIDIA driver detected"
NVIDIA_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
echo "    Driver version: $NVIDIA_VERSION"
echo ""

# Install dependencies
echo "[+] Installing build dependencies..."
sudo apt-get update
sudo apt-get install -y \
    build-essential pkg-config git \
    libx265-dev libx264-dev libvpx-dev \
    libopus-dev libvorbis-dev libtheora-dev \
    libssl-dev libfreetype-dev libfontconfig1-dev \
    libharfbuzz-dev libaom-dev libdav1d-dev \
    libass-dev libbluray-dev libbs2b-dev \
    libfribidi-dev \
    libgme-dev libgsm1-dev \
    libmp3lame-dev libmysofa-dev \
    libopenjp2-7-dev libopenmpt-dev \
    librubberband-dev libshine-dev \
    libsnappy-dev libsoxr-dev libspeex-dev \
    libssh-dev \
    libwebp-dev libxml2-dev libzimg-dev \
    libxvidcore-dev \
    yasm nasm

echo ""
echo "[+] Installing NVIDIA ffnvcodec headers..."
cd /tmp
if [ -d nv-codec-headers ]; then
    rm -rf nv-codec-headers
fi
git clone https://github.com/FFmpeg/nv-codec-headers.git
cd nv-codec-headers
make
sudo make install
cd /tmp

echo ""
echo "[+] Downloading FFmpeg $VERSION source..."
cd /tmp
if [ -d ffmpeg-$VERSION ]; then
    rm -rf ffmpeg-$VERSION
fi
wget -q https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz
tar xf ffmpeg-$VERSION.tar.xz
cd ffmpeg-$VERSION

echo "[+] Configuring with HEVC/NVENC support..."
./configure \
    --prefix="$INSTALL_PREFIX" \
    --enable-gpl \
    --enable-version3 \
    --enable-nonfree \
    --enable-libx265 \
    --enable-libx264 \
    --enable-nvenc \
    --enable-cuda-nvcc \
    --enable-cuvid \
    --enable-nvdec \
    --enable-libfreetype \
    --enable-libfontconfig \
    --enable-libharfbuzz \
    --enable-libvpx \
    --enable-libopus \
    --enable-libvorbis \
    --enable-libtheora \
    --enable-libopenjpeg \
    --enable-libdav1d \
    --enable-libass \
    --enable-libbluray \
    --enable-libbs2b \
    --enable-libfribidi \
    --enable-libgme \
    --enable-libgsm \
    --enable-libmp3lame \
    --enable-libmysofa \
    --enable-libopenmpt \
    --enable-librubberband \
    --enable-libshine \
    --enable-libsnappy \
    --enable-libsoxr \
    --enable-libspeex \
    --enable-libssh \
    --enable-libwebp \
    --enable-libxml2 \
    --enable-libzimg \
    --enable-libxvid \
    --enable-openssl \
    --enable-shared \
    --disable-doc \
    --disable-debug

echo ""
echo "[+] Building FFmpeg (this will take a few minutes)..."
make -j$(nproc)

echo ""
echo "[+] Installing to $INSTALL_PREFIX..."
make install

echo ""
echo "[+] Build complete!"
echo ""
echo "[+] Verify HEVC support:"
$INSTALL_PREFIX/bin/ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "hevc|h265"

echo ""
echo "[*] To use this FFmpeg build, either:"
echo "    1. Add to PATH: export PATH=\"$INSTALL_PREFIX/bin:\$PATH\""
echo "    2. Or use full path: $INSTALL_PREFIX/bin/ffmpeg"

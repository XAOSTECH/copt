# Building copt for Ubuntu 25.10+ (Wayland)

This branch explores building copt as a standalone Ubuntu package/binary that can be installed directly on the host system without requiring a devcontainer.

## Target System

- **OS**: Ubuntu 25.10+ (Oracular Oriole) or any Wayland-based Linux
- **Display Server**: Wayland (required for KMS grab)
- **GPU**: NVIDIA GPU with recent drivers (565+) for NVENC
- **Kernel**: 6.8+ with DRM/KMS support

## Quick Install

```bash
# Install dependencies
make install-deps

# Install copt to /usr/local
sudo make install

# Add your user to video group
sudo usermod -aG video,render $USER

# Log out and back in, then test
sudo copt --probe
```

## Build Requirements

### FFmpeg with KMS Grab

The system FFmpeg in Ubuntu 25.10 may not have `kmsgrab` support. You'll need to build FFmpeg from source:

```bash
# Install build dependencies
sudo apt-get install build-essential pkg-config yasm libdrm-dev \
    libva-dev libnvidia-encode-565 nvidia-cuda-toolkit

# Clone FFmpeg
git clone https://git.ffmpeg.org/ffmpeg.git
cd ffmpeg

# Configure with KMS grab and NVENC
./configure \
    --enable-gpl \
    --enable-version3 \
    --enable-nonfree \
    --enable-libdrm \
    --enable-kmsgrab \
    --enable-nvenc \
    --enable-cuda \
    --enable-cuvid \
    --enable-libx264 \
    --enable-libx265

# Build and install
make -j$(nproc)
sudo make install
sudo ldconfig
```

### Alternative: Use Static FFmpeg Build

Download a pre-built static FFmpeg with kmsgrab:

```bash
# Download latest static build (check for kmsgrab support)
wget https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz
tar xf ffmpeg-release-amd64-static.tar.xz
sudo cp ffmpeg-*-static/ffmpeg /usr/local/bin/
```

## Installation

```bash
# From the repository root
sudo make install
```

This installs:
- `/usr/local/bin/copt` - Main capture binary
- `/usr/local/bin/copt-autorestart` - Auto-restart wrapper
- `/usr/local/lib/copt/` - Library modules
- `~/.config/copt/copt.conf` - User configuration

## Usage

```bash
# Test capture (5 second dry-run)
sudo copt -A --dry-run -o /tmp/test.mkv

# Stream to YouTube Live
sudo copt -y YOUR_STREAM_KEY

# Use preset encoding profile
sudo copt --profile 1080p60 -y YOUR_STREAM_KEY

# Record to file
sudo copt -o ~/recording.mkv
```

## Packaging (Future)

This branch will eventually support:

### Debian Package
```bash
make deb
sudo dpkg -i copt_0.1.0_amd64.deb
```

### AppImage
```bash
make appimage
./copt-x86_64.AppImage --profile 1080p60 -y STREAM_KEY
```

### Snap Package
```bash
sudo snap install copt
```

## Why This Approach?

**Benefits over devcontainer:**
- ✅ Direct hardware access (no container permission issues)
- ✅ Lower overhead (no container runtime)
- ✅ Easier for end users (standard package install)
- ✅ Native systemd integration
- ✅ Works with system security policies

**Tradeoffs:**
- ❌ Users must install dependencies on host
- ❌ Requires building FFmpeg from source (for now)
- ❌ Less isolated (but copt needs hardware access anyway)

## Development

Switching between approaches:

```bash
# Build module approach (this branch)
git checkout build-module-ubuntu2510

# Devcontainer approach (main)
git checkout main
```

Both approaches share the same core copt code - just different deployment strategies.

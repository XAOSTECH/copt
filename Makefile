# ============================================================================
# copt Makefile — Build and install Wayland screen capture tool
# ============================================================================
# Target: Ubuntu 25.10+ with Wayland support
#
# Usage:
#   make                  # Show help
#   make install          # Install to /usr/local
#   make install-deps     # Install build/runtime dependencies
#   make uninstall        # Remove installation
#   make deb              # Build a .deb package
#
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================

.PHONY: help install install-deps uninstall deb clean

PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
LIBDIR = $(PREFIX)/lib/copt
CONFDIR = $(HOME)/.config/copt
SYSCONFDIR = /etc/copt

VERSION := $(shell grep -E 'COPT_VERSION=' src/copt.sh | head -1 | cut -d= -f2 | tr -d '"')

help:
	@echo "copt v$(VERSION) — Wayland KMS Screen Capture"
	@echo ""
	@echo "Targets:"
	@echo "  make install          Install copt to $(PREFIX)"
	@echo "  make install-deps     Install Ubuntu dependencies"
	@echo "  make uninstall        Remove installation"
	@echo "  make deb              Build .deb package"
	@echo "  make clean            Clean build artifacts"
	@echo ""
	@echo "Install location:"
	@echo "  Binaries: $(BINDIR)/copt, $(BINDIR)/copt-autorestart, $(BINDIR)/copt-host"
	@echo "  Libraries: $(LIBDIR)/"
	@echo "  Config: $(CONFDIR)/copt.conf"

# ============================================================================
# Install runtime and build dependencies
# ============================================================================
install-deps:
	@echo "Installing dependencies for Ubuntu 25.10+..."
	sudo apt-get update
	sudo apt-get install -y \
		build-essential \
		pkg-config \
		git \
		ffmpeg \
		lib alsa-tools \
		libdrm-dev \
		libva-dev \
		nvidia-cuda-toolkit \
		nvidia-driver-565 \
		libnvidia-encode-565
	@echo ""
	@echo "✓ Dependencies installed"
	@echo ""
	@echo "Note: You may need to build FFmpeg from source with:"
	@echo "  - --enable-libdrm"
	@echo "  - --enable-kmsgrab"
	@echo "  - --enable-nvenc"
	@echo ""
	@echo "See: https://trac.ffmpeg.org/wiki/CompilationGuide/Ubuntu"

# ============================================================================
# Install to system
# ============================================================================
install:
	@echo "Installing copt v$(VERSION) to $(PREFIX)..."
	# Install binaries
	install -Dm755 src/copt.sh $(BINDIR)/copt
	install -Dm755 src/copt-autorestart.sh $(BINDIR)/copt-autorestart
	install -Dm755 src/copt-host.sh $(BINDIR)/copt-host
	# Install libraries
	mkdir -p $(LIBDIR)/lib $(LIBDIR)/cfg
	cp -r lib/* $(LIBDIR)/lib/
	cp -r cfg/* $(LIBDIR)/cfg/
	# Install config (don't overwrite existing)
	mkdir -p $(CONFDIR)
	@if [ ! -f $(CONFDIR)/copt.conf ]; then \
		cp copt.conf.example $(CONFDIR)/copt.conf; \
		echo "  ✓ Installed config to $(CONFDIR)/copt.conf"; \
	else \
		echo "  ⚠ Config exists at $(CONFDIR)/copt.conf (not overwriting)"; \
	fi
	# Install system config directory
	sudo mkdir -p $(SYSCONFDIR)
	sudo cp cfg/defaults.conf $(SYSCONFDIR)/
	@echo ""
	@echo "✓ Installation complete!"
	@echo ""
	@echo "Run: sudo copt --help"

# ============================================================================
# Uninstall from system
# ============================================================================
uninstall:
	@echo "Uninstalling copt..."
	rm -f $(BINDIR)/copt
	rm -f $(BINDIR)/copt-autorestart
	rm -f $(BINDIR)/copt-host
	rm -rf $(LIBDIR)
	@echo "✓ Uninstalled (user config preserved at $(CONFDIR))"

# ============================================================================
# Build Debian package
# ============================================================================
deb:
	@echo "Building .deb package for Ubuntu 25.10+..."
	@echo "Not implemented yet. Use 'make install' for now."
	@exit 1

clean:
	@echo "Nothing to clean (shellscript project)"


## Credits

- **P010 kernel patches** — [awawa-dev/P010_for_V4L2](https://github.com/awawa-dev/P010_for_V4L2)
  by Alexander Weissmann ([@awawa-dev](https://github.com/awawa-dev)), creator of
  [HyperHDR](https://github.com/awawa-dev/HyperHDR). Enables native P010 v4l2 support
  for UVC devices. Included as a submodule in
  [XAOSTECH/video-tools](https://github.com/XAOSTECH/video-tools) alongside this repo.

---

## [0.0.1] - 2026-02-22 (re-release)

### Added
- add --host flag for direct host execution (lower latency)
- add --preview flag to copt-host
- add copt-preview - independent live preview window

### Fixed
- copt-preview display server access and diagnostics
- copt-preview path resolution when installed to ~/bin
- remove setparams HDR reinterpretation - device encodes HDR in 8-bit
- simplify find_video_device to prefer symlink unconditionally

### Changed
- chore(dc-init): generate release fix
- chore(dc-init): generate codeql fix
- chore(dc-init): generate codeql and automerge fix
- chore(docs): restore readme content + move docs
- Merge pull request #2 from XAOSTECH:anglicise/20260222-210023

chore: Convert American spellings to British English
- chore: convert American spellings to British English
- dc-init
- refactor: consolidate files - rename copt-host to copt
- refactor: container-first execution, agnostic USB device naming, HDR metadata fixes
- Add .env loading debug output
- Fix YouTube HLS URL construction

### Documentation
- add YouTube HDR troubleshooting section


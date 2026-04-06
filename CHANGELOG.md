
## [0.1.0] - 2026-04-06

### Changed
- Merge pull request #4 from XAOSTECH:anglicise/20260401-020459
- chore: convert American spellings to British English
- chore: update git tree visualisation
- chore(dc-init): load workflows,actions
- chore(dc-init): update workflows,actions

## [0.0.1] - 2026-03-09 (re-release)

### Fixed
- remove stray ] from for loops; handle --skip-relay in worker
- relay sync + --skip-relay flag + --help early exit + updated help text
- add missing colorspace vars; consolidate to 4k30 + 1080p60
- declare input colorspace before -i to prevent implicit matrix conversion
- profile arg parsing + banner timing
- embed HDR colour metadata via setparams in USB hevc path

### Changed
- chore(dc-init): update workflows and actions
- Remove redundant obs-safe-launch.sh, use shared op-cap launcher
- Merge pull request #3 from XAOSTECH:anglicise/20260301-015228

chore: Convert American spellings to British English
- chore: convert American spellings to British English
- chore: rremove .gitmodules
- Add USB capture and OBS crash prevention utilities
- Simplify relay back to synchronous uploads with playlist timer
- Fix stale playlist and segment tracking issues
- Refactor relay to upload segments in background for independent playlist scheduling
- Reduce playlist upload interval to 3s and wrap logging
- Add debug logging for playlist upload timing
- Show full URL format with partial cid masking for debugging
- Make relay cleanup more robust with verification loops

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


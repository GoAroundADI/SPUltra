# SP Ultra

<p align="center">
  <img src="docs/images/social-preview.png" width="100%" alt="SP Ultra — SFTP and SCP remote file transfer">
</p>

SP Ultra is a native macOS SFTP/SCP file-transfer client and a SecureFX alternative for Apple Silicon.

It provides a dual-pane SwiftUI interface, saved sessions, drag-and-drop transfers, real-time progress, remote rename and permission editing, UTF-8 online editing, SFTP resume, and an embedded MCP server. SSH and SCP run through the in-app SwiftNIO/Citadel stack; the app does not invoke the system `ssh`, `sftp`, or `scp` commands.

SCP automatically retries with compatibility algorithms for older servers and jailbroken iOS devices. The same Quick Connect form is used for every SCP target.

## Requirements

- Apple Silicon Mac
- macOS 15.0 or later

## Build

```bash
git clone https://github.com/GoAroundADI/SP-Ultra.git
cd SP-Ultra
swift build
swift test
zsh scripts/package-app.sh
zsh scripts/package-dmg.sh
```

The arm64 DMG is written as `SPUltra-1.0.0-arm64.dmg`.

## Author

SP Ultra is developed and maintained by **Go Around ADI** and released under the [MIT License](LICENSE).

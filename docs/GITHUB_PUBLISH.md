# GitHub 发布指南

## 仓库

- 名称：`SPUltra`
- 描述：`一款支持 SFTP / SCP 远程传输协议的 macOS 软件，SecureFX 平替产品。`
- Topics：`macos`、`swiftui`、`sftp`、`scp`、`ssh`、`file-transfer`、`securefx-alternative`、`apple-silicon`
- 默认分支：`main`

## 1.0.0

```bash
zsh scripts/package-app.sh
zsh scripts/package-dmg.sh
shasum -a 256 SPUltra-1.0.0-arm64.dmg
git tag -a v1.0.0 -m "SP Ultra 1.0.0"
git push origin main v1.0.0
gh release create v1.0.0 SPUltra-1.0.0-arm64.dmg \
  --title "SP Ultra 1.0.0 — SFTP / SCP SecureFX 平替" \
  --notes-file docs/RELEASE_NOTES_1.0.0.md \
  --latest
```

发布前确认：

- `swift test` 全部通过。
- 真实 SCP 与支持 SFTP 的服务器分别完成集成测试。
- 两个可执行文件均为 arm64。
- `codesign --verify --deep --strict` 与 `hdiutil verify` 通过。
- App 关于窗口显示 `1.0.0`，作者仅为 Go Around ADI。
- README、MCP 和下载链接均指向 `GoAroundADI/SP-Ultra`。

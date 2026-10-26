# 参与贡献

感谢你愿意为 SP Ultra 做贡献。本文说明项目的开发流程和提交前需要通过的检查。

参与本项目即表示你同意遵守[行为准则](CODE_OF_CONDUCT.md)。

## 可以贡献什么

- 用缺陷模板提交可复现的问题。
- 改进文档、截图和翻译。
- 为路径解析、会话处理或 SSH 行为补充测试。
- 实现范围清晰、符合产品方向的小功能。

较大的功能请先开 Issue 讨论设计，避免投入大量时间后方向不一致。

## 开发环境

要求：

- Apple 芯片 Mac（发布包仅 arm64）
- macOS 15+
- Xcode 16+ 与 Command Line Tools

```bash
git clone https://github.com/GoAroundADI/SP-Ultra.git
cd SP-Ultra
swift build
swift test
swift run SPUltra
```

打包：

```bash
zsh scripts/package-app.sh
zsh scripts/package-dmg.sh
```

## 分支与提交

- 从 `main` 创建主题分支：`feat/…`、`fix/…`、`docs/…`、`chore/…`。
- 提交保持小而聚焦。
- 提交标题使用祈使语气，例如：
  `fix: 钥匙串缺失时弹出密码输入窗口`。
- 必要时在提交正文中引用相关 Issue。

## 代码规范

- UI 文案使用中文；标识符、类型名、函数名使用英文。
- 网络和 shell 处理不要放进 SwiftUI 视图；优先写可测试的值类型和小函数。
- 提交前运行格式化：

  ```bash
  xcrun swift-format format --in-place --recursive Sources Tests --configuration .swift-format
  xcrun swift-format lint --recursive Sources Tests --configuration .swift-format
  ```

- 新增运行时依赖前，请先在 Issue 中讨论。
- 不要提交凭据、主机密钥、个人钥匙串数据或 `.build` 产物。

## 测试

```bash
swift test
```

网络集成测试默认跳过，需要一台可丢弃的 SSH 主机：

```bash
SPULTRA_TEST_HOST=127.0.0.1 \
SPULTRA_TEST_PORT=22 \
SPULTRA_TEST_USER=root \
SPULTRA_TEST_PASSWORD='…' \
SPULTRA_TEST_REMOTE_DIR=/tmp \
swift test --filter NativeSSHIntegrationTests
```

请在 PR 中注明测试过的模式（SFTP、SCP、旧版 SSH）以及主机类型（macOS、Linux、越狱 iOS）。

## Pull Request

一个 PR 需要满足：

- [ ] 描述清楚改动内容，并关联 Issue。
- [ ] `swift build` 与 `swift test` 通过。
- [ ] 新行为尽可能有测试覆盖。
- [ ] UI 改动附截图或短录屏。
- [ ] 不包含密码、个人路径或生成的二进制文件。
- [ ] 行为或配置变化时同步更新文档。

维护者可能要求缩小范围、补充测试或调整方向。请保持耐心与友善，这是一个利用业余时间维护的项目。

## 安全问题

请勿公开提交安全漏洞。请阅读 [SECURITY.md](SECURITY.md) 并通过私密渠道报告。

## 许可证

提交贡献即表示你同意该贡献以本项目的 [MIT License](LICENSE) 授权。

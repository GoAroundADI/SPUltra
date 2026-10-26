# 开发指南

本文覆盖构建、调试、测试、打包与发布 SP Ultra 的完整流程。

## 环境要求

- Apple 芯片 Mac
- macOS 15（Sequoia）或更高
- Xcode 16+ 与 Command Line Tools（打包脚本会用到 `xcrun`、`sips`、`iconutil`、`plutil`）

检查：

```bash
swift --version
xcodebuild -version
```

## 初始化

```bash
git clone https://github.com/GoAroundADI/SP-Ultra.git
cd SP-Ultra
swift build
swift test
```

从终端运行：

```bash
swift run SPUltra
```

首次构建会拉取 Citadel、swift-nio-ssh、SwiftNIO 与 Swift Crypto，可能需要几分钟。

## 项目结构

| 路径 | 用途 |
| --- | --- |
| `Sources/SPUltra/AppModel.swift` | 状态、连接生命周期、传输、会话凭据/缓存 |
| `Sources/SPUltra/FileServices.swift` | SFTP/SCP 传输、远程列表、shell 兜底 |
| `Sources/SPUltra/Models.swift` | 配置、文件项、传输任务、错误 |
| `Sources/SPUltra/Stores.swift` | 会话 JSON 与钥匙串 |
| `Sources/SPUltra/HostKeyStore.swift` | TOFU 主机密钥与校验器 |
| `Sources/SPUltra/ContentView.swift` | 分栏、文件表、拖拽、日志 |
| `Sources/SPUltra/SessionSidebar.swift` | 会话列表与右键菜单 |
| `Sources/SPUltra/SessionForm.swift` | 共用连接表单与路径下拉 |
| `Sources/SPUltra/SessionEditorView.swift` | 会话属性窗口 |
| `Sources/SPUltra/PasswordPromptView.swift` | 应用内 SSH 密码输入 |
| `Sources/SPUltra/QuickConnectView.swift` | 快速连接窗口 |
| `Sources/SPUltra/TransferQueueView.swift` | 传输队列与日志控制台 |
| `Sources/SPUltra/DebugCapture.swift` | DEBUG 截图工具 |
| `Sources/SPUltraMCP/main.swift` | stdio MCP 服务 |
| `Tests/SPUltraTests/` | 单元测试与可选集成测试 |
| `docs/ARCHITECTURE.md` | 设计与数据流 |

## 构建与测试

```bash
swift build                 # debug
swift build -c release      # release
swift test                  # 单元测试；集成测试默认跳过
```

集成测试需要一台可丢弃的 SSH 主机：

```bash
SPULTRA_TEST_HOST=127.0.0.1 \
SPULTRA_TEST_PORT=22 \
SPULTRA_TEST_USER=root \
SPULTRA_TEST_PASSWORD='your-password' \
SPULTRA_TEST_REMOTE_DIR=/tmp \
swift test --filter NativeSSHIntegrationTests
```

`SPULTRA_TEST_REMOTE_DIR` 默认 `/tmp`，可指向目标主机上的任意可写目录。
目标提供 SFTP 子系统时设置 `SPULTRA_TEST_SFTP=1`；仅支持 SCP 的设备不要设置。

## 调试

### 日志

应用内 **连接日志** 会显示连接进度、远程命令、传输结果和错误。`AppFailure` 的文案会原样显示；SCP 命令在 Citadel 提供 stderr 时也会带上远端错误。

常见日志：

- `正在从钥匙串读取已保存的密码…`
- `已创建远程文件…` / `已创建远程文件夹…`
- `shell 重定向创建文件失败，改用 SCP 协议通道…`
- `首次握手失败，启用旧设备兼容算法后重试一次…`

### DEBUG 截图工具

`DebugCapture` 只在 DEBUG 构建中编译。运行 `swift run SPUltra` 前可设置：

| 环境变量 | 作用 |
| --- | --- |
| `SPULTRA_DEBUG_CAPTURE=1` | 2 秒后截图所有窗口到临时目录 |
| `SPULTRA_OPEN_DONATION=1` | 离屏渲染捐赠窗口 |
| `SPULTRA_OPEN_QUICK=1` | 离屏渲染快速连接 |
| `SPULTRA_OPEN_EDITOR=1` | 离屏渲染会话属性 |
| `SPULTRA_OPEN_PASSWORD=1` | 离屏渲染密码输入窗口 |

示例：

```bash
SPULTRA_DEBUG_CAPTURE=1 SPULTRA_OPEN_PASSWORD=1 swift run SPUltra
```

输出位于 `FileManager.default.temporaryDirectory`，文件名以 `spultra-` 开头。

### 开发期间的钥匙串

每次 ad-hoc 重新构建都会改变代码签名，macOS 可能要求输入一次登录钥匙串密码。选择 **始终允许**；应用还会在本次启动内缓存密码。

如需从零测试，可在“钥匙串访问”中删除 `com.spultra.credentials` 下对应会话的条目。

## 代码规范

仓库使用 4 空格、140 列的 `swift-format`：

```bash
xcrun swift-format format --in-place --recursive Sources Tests --configuration .swift-format
xcrun swift-format lint --recursive Sources Tests --configuration .swift-format
```

约定：

- 网络和 shell 处理不要放进 SwiftUI 视图。
- 优先写可单元测试的小值类型和纯函数。
- 新增第三方运行时依赖前先开 Issue 讨论。
- 新增用户文案用中文；标识符用英文。
- 新代码避免不必要的强制解包。

## 打包

### .app

```bash
zsh scripts/package-app.sh
```

脚本会：

1. release 构建 arm64 的 `SPUltra` 与 `SPUltraMCP`；
2. 创建 app bundle 并复制资源 bundle；
3. 从 `Resources/ThirdParty/arrows-transfer-up-down.svg` 生成图标；
4. 复制并校验 `Resources/Info.plist`，再注入脚本顶部的标识、版本、构建号和最低系统版本；
5. 复制第三方许可证；
6. ad-hoc 签名。

可替换的构建常量集中在 `scripts/package-app.sh` 顶部；静态应用元数据集中在 `Resources/Info.plist`。

### DMG

```bash
zsh scripts/package-dmg.sh
```

输出仓库根目录下的 `SPUltra-<version>-arm64.dmg`，包含 App 和 `/Applications` 快捷方式。DMG 已被 `.gitignore` 忽略，发布时上传到 GitHub Releases。

## 签名与公证

本地使用 ad-hoc 签名即可。公开分发建议使用 Developer ID 签名并公证：

```bash
codesign --force --deep --options runtime \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  "dist/SP Ultra.app"

ditto -c -k --keepParent "dist/SP Ultra.app" "SPUltra.zip"
xcrun notarytool submit "SPUltra.zip" \
  --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password" --wait
xcrun stapler staple "dist/SP Ultra.app"
```

随后重新生成 DMG，必要时也进行 staple。不要把凭据提交到仓库；CI 中使用 `notarytool` 的钥匙串 profile。

## Fork 后改名

如果发布自己的构建，请同步修改：

- `scripts/package-app.sh` 中的 `BUNDLE_ID`
- `Sources/SPUltra/Stores.swift` 中的钥匙串服务 `com.spultra.credentials`
- `Sources/SPUltra/Models.swift` 中的 UTType `com.spultra.remoteitem`
- 存储与 MCP 中的 Application Support 目录名 `SP Ultra`
- `scripts/package-app.sh` 与 `Resources/Info.plist` 中的 App / 可执行文件名
- `Resources/Info.plist` 中的版权与关于窗口文案

修改钥匙串服务会导致已有密码不可见，用户需要重新输入。

## 发布检查清单

- [ ] 更新 `scripts/package-app.sh` 中的 `MARKETING_VERSION` / `BUILD_NUMBER`。
- [ ] 同步更新 `Sources/SPUltraMCP/main.swift` 中的 `serverInfo.version`。
- [ ] 更新 `CHANGELOG.md` 与 README 中的版本号。
- [ ] 运行 `swift test`。
- [ ] 视情况运行集成测试：SFTP、SCP、受限 shell 设备各一遍。
- [ ] `zsh scripts/package-app.sh`
- [ ] `zsh scripts/package-dmg.sh`
- [ ] `lipo -info` 确认两个可执行文件均为 `arm64`。
- [ ] `codesign --verify --deep --strict` 通过。
- [ ] 挂载 DMG 并从 DMG 启动 App。
- [ ] 打 tag，并把 DMG 上传到 GitHub Releases。
- [ ] 按 [GITHUB_PUBLISH.md](GITHUB_PUBLISH.md) 填写仓库 About、Topics、社交预览与 Release 文案。

## 故障排查

| 现象 | 处理 |
| --- | --- |
| `swift build` 拉取依赖失败 | 检查 GitHub 网络/代理；删除 `.build` 后重试 |
| App 构建成功但启动即退出 | 用 `swift run SPUltra` 在终端运行并查看输出 |
| 每次启动都弹钥匙串授权 | 选择“始终允许”；参见上面的钥匙串说明 |
| `SSH 算法协商失败` | 旧设备直接选择 SCP；应用会自动用兼容算法重试 |
| SFTP 子系统错误 | 服务器没有 SFTP；改用 SCP |
| MCP 主机密钥不一致 | 确认主机变化后调用 `reset_host_key(confirm: true)` |
| DMG 创建失败 | 确认 `hdiutil` 可用且 App bundle 已生成 |

安全问题请按 [SECURITY.md](../SECURITY.md) 私密报告。

# 安全策略

## 支持的版本

安全修复只应用于 `main` 分支上的最新版本。更早的 ad-hoc 构建不受支持。

| 版本 | 支持 |
| --- | --- |
| 1.1.x | ✅ |
| < 1.1 | ❌ |

## 报告安全漏洞

**请勿**为安全问题创建公开 Issue。请使用 GitHub 的私密漏洞报告：

<https://github.com/GoAroundADI/SP-Ultra/security/advisories/new>

请尽量提供：

- 问题描述与影响范围。
- 复现步骤、App 版本和 macOS 版本。
- 涉及 SFTP、SCP、MCP 还是钥匙串集成。
- 相关日志（请先移除密码、私钥和主机指纹）。

通常在几天内会收到确认。请在修复和协同披露完成前不要公开细节。

## 安全模型

- **不调用系统 SSH。** 连接与传输使用应用内 Citadel / SwiftNIO SSH 协议栈，不执行 `/usr/bin/ssh`、`sftp` 或 `scp`，也不读取或修改 `~/.ssh/known_hosts`。
- **密码。** 保存的密码存放在 macOS 钥匙串；MCP 的密码只在进程内存中使用，不读取 GUI 钥匙串。
- **主机密钥。** GUI 与 MCP 在 `~/Library/Application Support/SP Ultra/` 下各自维护独立的 TOFU 记录。密钥变化时必须由用户明确信任（GUI）或重置 MCP 记录。
- **最小暴露。** 应用不包含遥测或远程上报。
- **ad-hoc 签名。** 发布包未公证；下载二进制时请谨慎，优先从源码构建。

## 不在范围内

- 要求 macOS 账户已被攻破才能利用的问题。
- 无法通过 SP Ultra 触发的第三方依赖漏洞（也请向上游报告）。
- 需要用户主动安装不可信构建的社会工程场景。

## 第三方组件

依赖及其许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

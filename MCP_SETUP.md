# SP Ultra 内嵌 MCP

SP Ultra 1.0.0 在 App 内携带一个独立的 stdio MCP 服务。它不读取 GUI 会话、钥匙串密码或 GUI 主机指纹库。

```text
/Applications/SP Ultra.app/Contents/MacOS/SPUltraMCP
```

## Codex 配置

```bash
codex mcp add sp-ultra -- "/Applications/SP Ultra.app/Contents/MacOS/SPUltraMCP"
```

## 工具

| 工具 | 参数 | 说明 |
| --- | --- | --- |
| `connect` | `host`、`username`、`password`、`port`、`protocol` | 建立 SFTP/SCP 会话。SCP 自动兼容旧设备。 |
| `list_directory` | `path` | 列出远程目录。 |
| `connection_status` | 无 | 读取当前连接状态。 |
| `disconnect` | 无 | 断开连接。 |
| `reset_host_key` | `host`、`port`、`confirm: true` | 明确确认后清除指定 TOFU 记录；损坏的数据库会先备份再重建。 |

连接示例：

```json
{
  "name": "connect",
  "arguments": {
    "host": "127.0.0.1",
    "port": 22,
    "username": "root",
    "password": "your-password",
    "protocol": "SCP"
  }
}
```

普通服务器优先使用 SFTP；缺少 SFTP 子系统的旧设备或越狱 iOS 直接选择 SCP，无需其他专用参数。

## 主机指纹

MCP 使用独立文件：

```text
~/Library/Application Support/SP Ultra/mcp_host_keys.json
```

文件权限为 `0600`。主机密钥变化时连接会拒绝；只有确认设备或 SSH 服务确实更换后，才应调用 `reset_host_key` 并传入 `confirm: true`。如果数据库损坏，重置操作会保留带时间戳的备份。

密码仅存在于 MCP 进程内存中，不应写入仓库、Issues 或共享配置。

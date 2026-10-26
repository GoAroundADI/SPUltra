#if DEBUG
    import AppKit
    import SwiftUI

    /// 仅调试构建可用的自截图工具（通过环境变量 SPULTRA_DEBUG_CAPTURE 触发），
    /// 用于自动化验证界面渲染效果，正式发布构建中不包含。
    enum DebugCapture {
        static func scheduleIfRequested(model: AppModel) {
            let env = ProcessInfo.processInfo.environment
            guard env["SPULTRA_DEBUG_CAPTURE"] != nil else { return }
            Task { @MainActor in
                if env["SPULTRA_PROGRESS_SAMPLE"] != nil {
                    var upload = TransferJob(
                        id: UUID(), direction: .upload, source: "/tmp/archive.zip", destination: "/var/mobile/archive.zip",
                        displayName: "archive.zip", isDirectory: false, totalBytes: 420_000_000)
                    upload.status = .running
                    upload.startedAt = Date().addingTimeInterval(-8)
                    upload.transferredBytes = 168_000_000
                    upload.progress = 0.4
                    upload.bytesPerSecond = 21_000_000
                    upload.resumedBytes = 32_000_000
                    var download = TransferJob(
                        id: UUID(), direction: .download, source: "/var/log/system.log", destination: "/tmp/system.log",
                        displayName: "system.log", isDirectory: false, totalBytes: 80_000_000)
                    download.status = .running
                    download.startedAt = Date().addingTimeInterval(-5)
                    download.transferredBytes = 60_000_000
                    download.progress = 0.75
                    download.bytesPerSecond = 12_000_000
                    model.jobs = [upload, download]
                }
                try? await Task.sleep(for: .seconds(2))
                captureAllWindows(prefix: "main")
                if env["SPULTRA_OPEN_DONATION"] != nil {
                    renderOffscreen(DonationView(), size: NSSize(width: 552, height: 560), name: "donation")
                }
                if env["SPULTRA_OPEN_QUICK"] != nil {
                    renderOffscreen(QuickConnectView().environmentObject(model), size: NSSize(width: 620, height: 720), name: "quick")
                }
                if env["SPULTRA_OPEN_PASSWORD"] != nil {
                    let sample = SessionProfile(name: "127.0.0.1", host: "127.0.0.1", port: 22, username: "root", protocolKind: .scp)
                    renderOffscreen(
                        PasswordPromptView(session: sample).environmentObject(model),
                        size: NSSize(width: 440, height: 300), name: "password"
                    )
                }
                if env["SPULTRA_OPEN_EDITOR"] != nil {
                    let sample = SessionProfile(
                        name: "127.0.0.1", host: "127.0.0.1", port: 22, username: "root",
                        protocolKind: .sftp, authentication: .password, privateKeyPath: "",
                        initialRemotePath: "/var/www", saveSession: true
                    )
                    renderOffscreen(
                        SessionEditorView(profile: sample).environmentObject(model),
                        size: NSSize(width: 620, height: 720), name: "editor"
                    )
                }
                if env["SPULTRA_OPEN_REMOTE_OPERATIONS"] != nil {
                    let item = RemoteItem(
                        path: "/var/mobile/Documents/config.txt", name: "config.txt", isDirectory: false,
                        isSymbolicLink: false, size: 128, modifiedText: "2026/10/26 12:00", permissions: "-rw-r--r--")
                    renderOffscreen(
                        RemoteRenameView(request: RemoteRenameRequest(item: item)).environmentObject(model),
                        size: NSSize(width: 460, height: 240), name: "remote-rename")
                    renderOffscreen(
                        RemotePermissionsView(request: RemotePermissionsRequest(item: item)).environmentObject(model),
                        size: NSSize(width: 500, height: 280), name: "remote-permissions")
                    renderOffscreen(
                        RemoteTextEditorView(
                            document: RemoteTextDocument(
                                path: item.path, name: item.name,
                                text: "# SP Ultra\nport = 22\nprotocol = \"SFTP\"\n", permissions: item.permissions
                            )
                        )
                        .environmentObject(model),
                        size: NSSize(width: 900, height: 650), name: "remote-editor")
                }
            }
        }

        /// 把指定 SwiftUI 视图放进离屏窗口真实渲染后导出 PNG，不依赖屏幕录制权限。
        static func renderOffscreen<V: View>(_ view: V, size: NSSize, name: String) {
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(origin: .init(x: -20_000, y: -20_000), size: size),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = hosting
            window.orderBack(nil)
            window.displayIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("spultra-\(name).png"))
            }
            window.orderOut(nil)
        }

        static func captureAllWindows(prefix: String) {
            for (index, window) in NSApp.windows.enumerated() {
                guard let view = window.contentView, !view.bounds.isEmpty else { continue }
                window.displayIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                guard let data = rep.representation(using: .png, properties: [:]) else { continue }
                try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("spultra-\(prefix)-\(index).png"))
            }
        }
    }
#endif

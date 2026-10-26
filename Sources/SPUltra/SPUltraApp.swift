import AppKit
import SwiftUI

@main
struct SPUltraApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1_180, minHeight: 740)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 SP Ultra") {
                    let marketingVersion =
                        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "SP Ultra",
                        .applicationVersion: marketingVersion,
                        // 保留内部构建号供更新/诊断使用，但不在面向用户的关于窗口重复显示。
                        .version: "",
                    ])
                }
            }
            CommandGroup(after: .newItem) {
                Button("快速连接…") { model.isQuickConnectVisible = true }
                    .keyboardShortcut("n", modifiers: [.command])
            }
            CommandMenu("传输") {
                Button("上传所选项目") { model.uploadSelection() }
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                Button("下载所选项目") { model.downloadSelection() }
                    .keyboardShortcut(.downArrow, modifiers: [.command])
                Divider()
                Button("取消传输") { model.cancelTransfers() }
            }
            CommandMenu("连接") {
                Button("重置主机指纹库…") { model.isHostKeyResetConfirmationPresented = true }
            }
            CommandMenu("界面") {
                Toggle("会话管理器", isOn: $model.isSessionManagerVisible)
                Toggle("传输日志", isOn: $model.isConsoleVisible)
                Toggle("隐藏文件", isOn: $model.showHiddenFiles)
            }
        }
    }
}

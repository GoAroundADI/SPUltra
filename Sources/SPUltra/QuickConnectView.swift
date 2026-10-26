import AppKit
import SwiftUI

struct QuickConnectView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var profile = SessionProfile()
    @State private var password = ""
    @State private var savePassword = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("快速连接", systemImage: "bolt.horizontal.circle.fill").font(.title2.bold())
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }.buttonStyle(
                    .plain)
            }
            .padding(20).background(.bar)

            SessionForm(profile: $profile, password: $password, savePassword: $savePassword)

            Divider()
            HStack {
                Text("首次连接会记录主机指纹；指纹变化时应用会拒绝连接并要求核对。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button {
                    startConnection()
                } label: {
                    if isConnecting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在连接")
                        }
                    } else {
                        Text("连接")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    isConnecting || profile.host.trimmingCharacters(in: .whitespaces).isEmpty
                        || profile.username.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(16)
        }
        .frame(width: 620, height: 720)
        .alert(
            "SP Ultra",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .alert(item: $model.hostKeyConflict) { conflict in
            Alert(
                title: Text("主机身份已变化"),
                message: Text("旧指纹：\n\(conflict.previousFingerprint)\n\n新指纹：\n\(conflict.presentedFingerprint)\n\n请先确认设备确实已重装或更换 SSH 服务。"),
                primaryButton: .destructive(Text("信任新指纹"), action: model.trustChangedHostKey),
                secondaryButton: .cancel(Text("取消"), action: model.rejectChangedHostKey)
            )
        }
    }

    private var isConnecting: Bool { model.isConnecting }

    private func startConnection() {
        if profile.name == "新建会话", !profile.host.isEmpty { profile.name = profile.host }
        model.connect(profile: profile, password: password, savePassword: savePassword)
    }

    private func close() {
        if isConnecting { model.disconnect() }
        dismiss()
    }
}

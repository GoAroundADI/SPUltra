import SwiftUI

struct SessionSidebar: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter = ""

    private var filtered: [SessionProfile] {
        guard !filter.isEmpty else { return model.sessions }
        return model.sessions.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || $0.host.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("会话管理器", systemImage: "rectangle.stack")
                    .font(.headline)
                Spacer()
                Button {
                    model.isQuickConnectVisible = true
                } label: {
                    Image(systemName: "plus")
                }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).frame(height: 36).background(.bar)
            Divider()
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("筛选会话", text: $filter).textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button {
                        filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }.buttonStyle(.plain)
                }
            }
            .padding(8).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            List(selection: $model.selectedSessionID) {
                Section("会话") {
                    ForEach(filtered) { session in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(session.name).lineLimit(1)
                                    if model.connectedSessionID == session.id {
                                        Circle().fill(Color.green).frame(width: 6, height: 6)
                                            .help("当前已连接")
                                    }
                                }
                                Text("\(session.protocolKind.rawValue) · \(session.host)").font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: "server.rack")
                        }
                        .tag(session.id)
                        .contextMenu {
                            Button("连接") { model.connectSaved(session) }
                                .disabled(model.isConnecting || model.connectedSessionID == session.id)
                            Button("断开") { if model.connectedSessionID == session.id { model.disconnect() } }
                                .disabled(model.connectedSessionID != session.id)
                            Divider()
                            Button("属性…") { model.editSession(session) }
                            Divider()
                            Button("删除", role: .destructive) { model.deleteSession(session) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onTapGesture(count: 2) {
                if let session = model.selectedSession { model.connectSaved(session) }
            }
            Divider()
            HStack {
                Button {
                    model.isQuickConnectVisible = true
                } label: {
                    Label("新建", systemImage: "plus")
                }
                Spacer()
                Text("\(model.sessions.count) 个会话").font(.caption).foregroundStyle(.secondary)
            }.padding(9)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

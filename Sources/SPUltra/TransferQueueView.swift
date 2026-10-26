import SwiftUI

struct TransferQueueView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Label("传输队列", systemImage: "arrow.left.arrow.right")
                        .font(.headline)
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("清除已完成") { model.clearFinishedJobs() }.disabled(model.jobs.isEmpty)
                    Button("全部取消") { model.cancelTransfers() }
                        .disabled(!model.jobs.contains { $0.status == .queued || $0.status == .running })
                }
                HStack(spacing: 18) {
                    directionProgress(.upload)
                    directionProgress(.download)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
            Divider()
            Table(model.jobs) {
                TableColumn("文件名") { job in
                    Label(job.displayName, systemImage: job.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                }.width(min: 130, ideal: 220)
                TableColumn("目标") { job in Text(job.destination).lineLimit(1).truncationMode(.middle) }
                    .width(min: 150, ideal: 280)
                TableColumn("大小") { job in
                    Text(job.totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: job.totalBytes, countStyle: .file) : "—")
                }
                .width(80)
                TableColumn("进度") { job in
                    VStack(alignment: .leading, spacing: 2) {
                        if job.status == .running, job.totalBytes <= 0 {
                            ProgressView().controlSize(.small).frame(minWidth: 100)
                        } else {
                            ProgressView(value: job.progress).frame(minWidth: 100)
                        }
                        Text(progressText(job)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }.width(min: 115, ideal: 155)
                TableColumn("速度") { job in
                    if job.status == .running, job.bytesPerSecond > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(job.bytesPerSecond), countStyle: .file))/s")
                            .font(.caption.monospacedDigit())
                    } else {
                        Text("—")
                    }
                }.width(min: 75, ideal: 95)
                TableColumn("状态") { job in
                    HStack(spacing: 5) {
                        Circle().fill(statusColor(job.status)).frame(width: 7, height: 7)
                        Text(job.status.rawValue)
                        if job.resumedBytes > 0 { Image(systemName: "arrow.clockwise").help("已从断点续传") }
                    }.help(job.errorMessage ?? "")
                }.width(105)
                TableColumn("开始时间") { job in Text(job.startedAt?.formatted(date: .omitted, time: .standard) ?? "—") }.width(90)
                TableColumn("完成时间") { job in Text(job.finishedAt?.formatted(date: .omitted, time: .standard) ?? "—") }.width(90)
            }
            .overlay {
                if model.jobs.isEmpty {
                    ContentUnavailableView("传输队列为空", systemImage: "tray", description: Text("在两侧面板之间拖拽文件或文件夹即可上传/下载"))
                }
            }
        }
    }

    private var summary: String {
        let active = model.jobs.filter { $0.status == .running || $0.status == .queued }.count
        return active == 0 ? "" : "· \(active) 项进行中"
    }

    @ViewBuilder
    private func directionProgress(_ direction: TransferDirection) -> some View {
        let active = model.jobs.filter { $0.direction == direction && ($0.status == .queued || $0.status == .running) }
        let transferred = active.reduce(Int64(0)) { $0 + $1.transferredBytes }
        let total = active.reduce(Int64(0)) { $0 + $1.totalBytes }
        HStack(spacing: 7) {
            Image(systemName: direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(direction == .upload ? .blue : .green)
            Text(direction.rawValue).font(.caption.bold())
            if active.isEmpty {
                ProgressView(value: 0).frame(maxWidth: 150)
                Text("空闲").font(.caption2).foregroundStyle(.secondary)
            } else if total > 0 {
                ProgressView(value: min(1, Double(transferred) / Double(total))).frame(maxWidth: 150)
                Text("\(Int(min(1, Double(transferred) / Double(total)) * 100))%")
                    .font(.caption2.monospacedDigit()).frame(width: 32, alignment: .trailing)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: 150)
                Text("计算中").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func progressText(_ job: TransferJob) -> String {
        let transferred = ByteCountFormatter.string(fromByteCount: job.transferredBytes, countStyle: .file)
        guard job.totalBytes > 0 else { return transferred }
        let total = ByteCountFormatter.string(fromByteCount: job.totalBytes, countStyle: .file)
        return "\(transferred) / \(total)"
    }

    private func statusColor(_ status: TransferStatus) -> Color {
        switch status {
        case .queued: return .secondary
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}

struct LogConsole: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("连接日志", systemImage: "terminal").font(.caption.bold())
                Spacer()
                Button("清除") { model.logs.removeAll() }.font(.caption).buttonStyle(.borderless)
            }.padding(.horizontal, 9).frame(height: 27).background(Color(nsColor: .controlBackgroundColor))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(model.logs) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(entry.time.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
                                Text(entry.level.rawValue).foregroundStyle(logColor(entry.level)).frame(width: 38, alignment: .leading)
                                Text(entry.message).textSelection(.enabled)
                            }
                            .font(.system(size: 11, design: .monospaced)).id(entry.id)
                        }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.logs.count) { _, _ in
                    if let id = model.logs.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .background(Color.black.opacity(0.34))
        }
    }

    private func logColor(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

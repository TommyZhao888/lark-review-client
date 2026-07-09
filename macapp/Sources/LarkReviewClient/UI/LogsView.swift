import SwiftUI

/// 日志窗口：运行日志（实时）+ Review 日志（列表/详情）。
struct LogsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TabView {
            RunLogTab()
                .tabItem { Label("运行日志", systemImage: "terminal") }
            ReviewLogsTab()
                .tabItem { Label("Review 日志", systemImage: "doc.text.magnifyingglass") }
            WSMessagesTab()
                .tabItem { Label("WS 消息", systemImage: "arrow.up.arrow.down.circle") }
        }
        .padding(8)
    }
}

/// WebSocket 消息帧日志：收/发原文，方便排查协议问题。
private struct WSMessagesTab: View {
    @Environment(AppState.self) private var state
    @State private var hideHeartbeats = true

    private var entries: [AppState.WSLogEntry] {
        hideHeartbeats ? state.wsMessages.filter { !$0.isHeartbeat } : state.wsMessages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("隐藏心跳", isOn: $hideHeartbeats)
                    .toggleStyle(.checkbox)
                Text("共 \(entries.count) 条（最多保留 500）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空") { state.clearWSMessages() }
                    .disabled(state.wsMessages.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(entries) { e in
                            HStack(alignment: .top, spacing: 6) {
                                Text(e.outbound ? "↑" : "↓")
                                    .font(.system(.caption, design: .monospaced).bold())
                                    .foregroundStyle(e.outbound ? Color.blue : Color.green)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.date.formatted(date: .omitted, time: .standard))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(e.text)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                            .id(e.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: entries.count) { _, _ in
                    if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if entries.isEmpty {
                Text(state.wsMessages.isEmpty ? "暂无消息（连上服务端后这里会显示收发的每一帧）" : "仅有心跳帧（取消「隐藏心跳」可见）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RunLogTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(state.recentLogLines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.recentLogLines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            HStack {
                Text(LogStore.shared.logPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: LogStore.shared.logPath)])
                }
                .font(.caption)
            }
        }
        .onAppear {
            // 首次打开时从文件回填历史（app 启动前的日志不在内存 ring buffer 里）
            if state.recentLogLines.isEmpty {
                let tail = LogStore.shared.tailLog()
                state.recentLogLines = tail.components(separatedBy: "\n").filter { !$0.isEmpty }
            }
        }
    }
}

private struct ReviewLogsTab: View {
    @State private var entries: [LogStore.ReviewLogEntry] = []
    @State private var selected: String?
    @State private var content = ""

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("最近 \(entries.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        entries = LogStore.shared.listReviewLogs()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
                List(entries, selection: $selected) { e in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.file)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Text(e.mtime.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .tag(e.file)
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 240, maxWidth: 340)

            ScrollView {
                Text(content.isEmpty ? "选择左侧一条日志查看" : content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .onAppear { entries = LogStore.shared.listReviewLogs() }
        .onChange(of: selected) { _, file in
            content = file.map { LogStore.shared.readReviewLog(file: $0) } ?? ""
        }
    }
}

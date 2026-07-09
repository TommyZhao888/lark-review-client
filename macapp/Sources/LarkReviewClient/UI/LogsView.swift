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
        }
        .padding(8)
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

import SwiftUI

/// 菜单栏弹板：身份、连接状态、当前任务、队列、升级提示、快捷操作。
struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            statusSection
            if let up = state.upgrade { upgradeBanner(up) }
            jobSection
            Divider()
            actions
        }
        .padding(12)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("🦁 Lark Review Client")
                .font(.headline)
            Spacer()
            Text("v\(CLIENT_VERSION)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(state.connectionLabel)
                    .font(.callout)
            }
            if let id = state.identity {
                Text("\(id.name)  ·  \(id.openId)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var statusColor: Color {
        switch state.connection {
        case .registered: return .green
        case .connected, .connecting: return .yellow
        case .disconnected: return .red
        case .halted: return .orange
        }
    }

    private func upgradeBanner(_ up: UpgradeInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("🆙 有新版本 v\(up.recommended ?? "?")（当前 v\(CLIENT_VERSION)）")
                .font(.callout.bold())
            if up.below_min == true {
                Text("已低于最低要求 v\(up.min ?? "?")，可能不兼容")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let msg = up.message, !msg.isEmpty {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let busy = state.runningJob != nil || !state.queuedJobs.isEmpty
            switch state.updatePhase {
            case .running(let step):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(step).font(.caption)
                }
            case .failed(let reason):
                Text("更新失败：\(reason)").font(.caption).foregroundStyle(.red)
                updateButton("重试更新并重启", disabled: busy)
            case .idle:
                updateButton("更新并重启", disabled: busy)
                if busy {
                    Text("有 review 在跑/排队，跑完再更新").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    private func updateButton(_ title: String, disabled: Bool) -> some View {
        Button(title) { AppRuntime.shared.performSelfUpdate(auto: false) }
            .disabled(disabled)
    }

    @ViewBuilder
    private var jobSection: some View {
        if let job = state.runningJob {
            VStack(alignment: .leading, spacing: 3) {
                Text("⚡ 正在 Review")
                    .font(.callout.bold())
                Text("PR #\(job.prNum)  \(job.repo)  [\(job.stage)]")
                    .font(.caption)
                Text("开始于 \(job.since.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        if !state.queuedJobs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("排队中: \(state.queuedJobs.count)")
                    .font(.caption.bold())
                ForEach(Array(state.queuedJobs.enumerated()), id: \.offset) { _, j in
                    Text("PR #\(j.prNum)  \(j.repo)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        if state.runningJob == nil, state.queuedJobs.isEmpty, state.isRegistered {
            Text("待命中，等待派单")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .halted = state.connection {
                Button("🔁 重新连接") {
                    AppRuntime.shared.manualReconnect()
                    dismiss()
                }
            }
            HStack {
                Button("设置…") {
                    dismiss()
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("日志…") {
                    dismiss()
                    openWindow(id: "logs")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("退出") {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

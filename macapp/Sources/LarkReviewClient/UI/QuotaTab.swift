import SwiftUI

/// 设置窗口「额度」tab：账号套餐 + 5 小时窗/周窗已用与重置时间 + 当前模型信息。
/// 数据来自 QuotaMonitor 的 `claude -p /usage` 缓存（每 10min 自动刷新，派活前再刷一次）
/// 与 `claude auth status`（打开本 tab 时按需查，5min 缓存）。与 Node 版配置页「额度」tab 逐字段对齐。
struct QuotaTab: View {
    @Environment(AppState.self) private var state

    @State private var snap: QuotaSnapshot?
    @State private var account: ClaudeAccountInfo?
    @State private var lastReview: UsageStore.LastReview?
    @State private var busy = false

    var body: some View {
        Form {
            planSection
            usageSection
            modelSection
            if let raw = snap?.raw, !raw.isEmpty {
                Section("/usage 原文（排查用）") {
                    Text(raw)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .task { await load(force: false) }
    }

    // ---------- 账号套餐 ----------

    private var planSection: some View {
        Section("账号套餐（读本机 claude 登录态）") {
            LabeledContent("套餐", value: dash(account?.subscriptionType?.uppercased()))
            LabeledContent("登录方式", value: dash(account?.authMethod))
            LabeledContent("账号", value: dash(account?.email))
            LabeledContent("组织", value: dash(account?.orgName))
            if account?.loggedIn == false {
                Label("claude 未登录 —— 终端跑 `claude auth login`，否则额度查不到、review 也跑不了。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let err = account?.error {
                Text(err).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // ---------- 额度用量 ----------

    private var usageSection: some View {
        Section {
            if let s = snap {
                windowRow(s.fiveHour, threshold: state.config.quotaFiveHourThreshold)
                windowRow(s.sevenDay, threshold: state.config.quotaSevenDayThreshold)
                ForEach(s.modelWindows) { w in
                    windowRow(QuotaWindow(name: "周窗 · " + w.name, pct: w.pct, resetAtMs: w.resetAtMs),
                              threshold: state.config.quotaSevenDayThreshold)
                }
                if s.ok {
                    Label("额度充足，可正常接单", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("额度不足（\(s.reason ?? "?")）· 已停止接单，预计 "
                          + (s.resetAt.map { fmt($0) + " " + delta($0) } ?? "未知") + " 恢复",
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let e = s.lastError {
                    Text("最近一次查额度失败（\(fmt(e.at))）：\(e.reason)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("加载中…").foregroundStyle(.secondary)
            }
            HStack {
                Button(busy ? "查询中…" : "立即查一次") { Task { await load(force: true) } }
                    .disabled(busy)
                Spacer()
            }
            Text("客户端每 10 分钟用 `claude -p /usage` 自动查一次（headless，零 token），派单前还会再查一次；"
                 + "任一窗超过阈值即上报额度不足，服务端改派他人，到重置时间自动恢复。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("额度用量" + (snap?.updatedAt.map {
                "　· 数据时间 \(fmt($0))" + ((snap?.fresh == false) ? "（已过期，上报服务端时按未知处理）" : "")
            } ?? "　· 尚未查到"))
        }
    }

    /// 一个额度窗：已用% + 停派阈值 + 进度条 + 重置时间。pct 为空 = 还没查到。
    @ViewBuilder
    private func windowRow(_ w: QuotaWindow, threshold: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(w.name)
                Spacer()
                if let p = w.pct {
                    Text("\(p)% 已用").bold()
                    Text("/ 停派阈值 \(threshold)%").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            bar(w.pct, threshold: threshold)
            Text(w.resetAt.map { "重置 \(fmt($0)) \(delta($0))" } ?? "（该窗未给出重置时间）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// 已用进度条。颜色写死不走 accentColor —— 后者在窗口失焦时会被系统脱色成灰, 红/橙告警就没了。
    private func bar(_ pct: Int?, threshold: Int) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(barColor(pct, threshold))
                    .frame(width: g.size.width * Double(min(pct ?? 0, 100)) / 100)
            }
        }
        .frame(height: 6)
    }

    private func barColor(_ pct: Int?, _ threshold: Int) -> Color {
        guard let pct else { return .secondary }
        if pct >= threshold { return .red }
        return pct >= threshold - 15 ? .orange : .green
    }

    // ---------- 模型 ----------

    private var modelSection: some View {
        Section("模型") {
            LabeledContent("review 模型（本机配置）", value: dash(state.config.reviewModel))
            LabeledContent("最近一次 review 实际模型", value: lastReview.map { lr in
                lr.model + (lr.ts.map { " · " + fmt($0) } ?? "")
                    + (lr.repo.isEmpty ? "" : " · \(lr.repo) #\(lr.prNum)")
            } ?? "—")
            LabeledContent("claude 版本", value: dash(account?.version))
            Text("claude: \(state.config.claudePath)"
                 + (state.config.effectiveQuotaClaudePath == state.config.claudePath
                    ? "" : " · 查额度用: \(state.config.effectiveQuotaClaudePath)"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("服务端派单时可用 review_model 覆盖本机配置，故两者可能不同。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // ---------- 数据 ----------

    /// force = 先现跑一次 `claude -p /usage`（约 1~3s）再取；成功则顺带独立上报一次额度（对齐 Node 版）。
    private func load(force: Bool) async {
        busy = true
        defer { busy = false }
        if force, await QuotaMonitor.shared.refreshUsage(config: state.config) {
            AppRuntime.shared.reportQuota()
        }
        account = await QuotaMonitor.shared.accountInfo(config: state.config, force: force)
        snap = QuotaMonitor.shared.snapshot(config: state.config)
        lastReview = UsageStore.lastReview()
    }

    private func dash(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "—" }
        return s
    }

    private func fmt(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

    /// 距重置还有多久（跨天的周窗用 d/h，5 小时窗用 h/m）。
    private func delta(_ d: Date) -> String {
        let sec = Int(d.timeIntervalSinceNow)
        if sec <= 0 { return "（已到点）" }
        let h = sec / 3600, m = (sec % 3600) / 60
        if h >= 48 { return "（还有 \(h / 24)d\(h % 24)h）" }
        return h > 0 ? "（还有 \(h)h\(m)m）" : "（还有 \(m)m）"
    }
}

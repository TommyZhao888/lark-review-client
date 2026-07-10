import Foundation
import AppKit

/// 组装层：把 ConfigStore / WebSocketClient / ReviewCoordinator / LogStore /
/// NotificationManager 接到 AppState，对齐 Node 版主流程。
@MainActor
final class AppRuntime {
    static let shared = AppRuntime()

    let state = AppState()
    let ws = WebSocketClient()
    let reviews = ReviewCoordinator()
    let notifications = NotificationManager()

    private var pruneTask: Task<Void, Never>?
    private var started = false
    /// 已对该 recommended 版本自动尝试过更新，防失败后每次重连都重试（一次没成功就等用户手动/换轮）。
    private var autoUpdateTriedFor: String?

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        state.config = ConfigStore.load()
        LogStore.shared.log("config \(ConfigStore.configPath) loaded, repos: \(state.config.repos.keys.sorted().joined(separator: ", ").isEmpty ? "(无)" : state.config.repos.keys.sorted().joined(separator: ", ")) (身份由服务端按 token 下发)")
        StatuslineInstaller.ensure(config: state.config)   // 自动配置额度快照 statusLine(仅当未配过; 幂等)

        LogStore.shared.onLine = { line in
            Task { @MainActor in AppRuntime.shared.state.appendLog(line) }
        }
        InboundMessage.onDecodeFailure = { type, error in
            LogStore.shared.log("⚠️ 消息 \(type) 解码失败(已丢弃): \(error)")
        }
        notifications.currentConfig = { [state] in state.config }
        notifications.requestAuthorization()

        wireWebSocket()
        wireReviews()

        // 预热登录 shell PATH（避免第一单 review 时才卡 5s）
        Task.detached { _ = ProcessRunner.loginShellPATH() }

        ws.start(config: state.config)

        // worktree / review 日志过期清理：启动一次 + 每 6h
        pruneTask = Task { @MainActor [state] in
            while !Task.isCancelled {
                let cfg = state.config
                await WorktreeManager.pruneStaleWorktrees(repos: cfg.repos, maxAgeDays: cfg.worktreeMaxAgeDays)
                LogStore.shared.pruneReviewLogs(maxAgeDays: cfg.worktreeMaxAgeDays)
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    func shutdown() {
        LogStore.shared.log("bye")
        pruneTask?.cancel()
        ws.shutdown()
        ChildProcessRegistry.shared.terminateAll()
    }

    /// 设置保存：持久化 + 热重载重连。返回错误信息（nil = 成功）。
    func saveConfig(_ cfg: Config) -> String? {
        if cfg.serverUrl.isEmpty || cfg.token.isEmpty {
            return "serverUrl 和 token 必填"
        }
        // repos 允许为空（先连上拿服务端清单再配），但配了的必须两个路径齐全。
        var normalized = cfg
        for (name, rc) in cfg.repos {
            var rc = rc
            rc.mainRepo = rc.mainRepo.trimmingCharacters(in: .whitespaces)
            rc.worktreeBase = rc.worktreeBase.trimmingCharacters(in: .whitespaces)
            if rc.mainRepo.isEmpty {
                return "项目 \(name) 的 mainRepo 必须填"
            }
            // worktreeBase 留空自动补 <mainRepo>-worktrees
            if rc.worktreeBase.isEmpty {
                rc.worktreeBase = rc.mainRepo + "-worktrees"
            }
            normalized.repos[name] = rc
        }
        do {
            try ConfigStore.save(normalized)
        } catch {
            return "保存失败: \(error.localizedDescription)"
        }
        state.config = ConfigStore.load()
        ws.reconnect(with: state.config)
        return nil
    }

    /// halted（bad_token）后菜单栏「重新连接」。
    func manualReconnect() {
        ws.reconnect(with: state.config)
    }

    /// 自更新：git pull + make bundle + 重启。auto=true 为「空闲时自动更新」触发（不打断在跑/排队的 review）。
    func performSelfUpdate(auto: Bool) {
        if case .running = state.updatePhase { return }              // 已在更新中
        if state.runningJob != nil || !state.queuedJobs.isEmpty {
            if auto { return }                                       // 自动模式：有活在跑就不更新，等空闲
            state.updatePhase = .failed("有 review 在跑或排队，等它跑完再更新")
            return
        }
        state.updatePhase = .running("准备…")
        LogStore.shared.log("self-update: 开始更新\(auto ? "（自动，检测到新版本且空闲）" : "（手动）")")
        Task { [weak self] in
            let outcome = await SelfUpdater.run(onStep: { step in
                Task { @MainActor in self?.state.updatePhase = .running(step) }
            })
            await MainActor.run {
                guard let self else { return }
                if outcome.ok {
                    LogStore.shared.log("self-update: \(outcome.message)")
                    if outcome.changed {
                        self.state.updatePhase = .running("重启中…")   // relaunch 已触发，进程即将退出
                    } else {
                        self.state.updatePhase = .idle
                        self.notifications.notify("客户端已是最新", outcome.message)
                    }
                } else {
                    self.state.updatePhase = .failed(outcome.message)
                    LogStore.shared.log("self-update 失败: \(outcome.message)")
                    self.notifications.notify("⚠️ 自动更新失败", outcome.message)
                }
            }
        }
    }

    // ---------- 接线 ----------

    private func wireWebSocket() {
        ws.onStateChange = { [state] s in state.connection = s }
        ws.onFrame = { [state] outbound, text in state.appendWSMessage(outbound: outbound, text: text) }

        ws.onRegisterAck = { [self, state, ws, notifications] ack, wasReconnect in
            state.identity = AppState.Identity(
                openId: ack.open_id ?? "",
                name: ack.name ?? "",
                recommendedVersion: ack.recommended_version
            )
            state.upgrade = ack.upgrade
            if let repos = ack.managed_repos { state.managedRepos = repos }

            if wasReconnect {
                let running = state.runningJob
                let midJob = running.map { " (PR #\($0.prNum) 仍在本机继续)" } ?? ""
                notifications.notify("🔁 已重新连接 hub", (running != nil ? "Review 仍在继续" : "待命中") + midJob)
                ws.send(.reconnected(
                    wasBusy: running != nil,
                    repo: running?.repo ?? "",
                    prNum: running?.prNum
                ))
            }

            // 对照服务端清单提示配置缺口：本地多配的不会被派单。
            let managedNames = Set(state.managedRepos.map(\.repo))
            let extras = state.config.repos.keys.filter { !managedNames.isEmpty && !managedNames.contains($0) }
            if !extras.isEmpty {
                LogStore.shared.log("本地配置的 repo 不在服务端受管清单里(不会被派单): \(extras.joined(separator: ", "))")
            }
            if state.config.repos.isEmpty {
                LogStore.shared.log("尚未配置任何项目 —— 打开设置从服务端清单里选择并填本机路径")
            }
            if let up = ack.upgrade {
                if up.below_min == true {
                    LogStore.shared.log("⛔ 版本过低: 当前 v\(CLIENT_VERSION) 低于最低要求 v\(up.min ?? "?") —— 服务端已暂停给你派 review, 升级后自动恢复。\(up.message.map { " 升级方式: \($0)" } ?? "")")
                    notifications.notify("⛔ 版本过低，已暂停派单", "当前 v\(CLIENT_VERSION) 低于最低 v\(up.min ?? "?")，请尽快升级")
                } else {
                    LogStore.shared.log("🆙 建议升级: 当前 v\(CLIENT_VERSION) → 推荐 v\(up.recommended ?? "?")(当前仍可正常接单)。\(up.message.map { " 升级方式: \($0)" } ?? "")")
                    notifications.notify("🆙 有新版本 v\(up.recommended ?? "?")", "当前 v\(CLIENT_VERSION)，建议升级(仍可接单)")
                }
                // 「空闲时自动更新」开启 + 当前空闲 → 自动更新。每个 recommended 版本只自动尝试一次(防失败重连死循环)。
                let rec = up.recommended ?? "?"
                let idle = state.runningJob == nil && state.queuedJobs.isEmpty
                // 自动更新仅对源码(git)安装生效: dmg 安装无法本地编译, 靠菜单栏「前往下载新版」引导。
                if state.config.autoUpdate, idle, self.autoUpdateTriedFor != rec, SelfUpdater.isGitInstall() {
                    self.autoUpdateTriedFor = rec
                    LogStore.shared.log("自动更新: 检测到新版本 v\(rec) 且空闲，开始自动更新")
                    self.performSelfUpdate(auto: true)
                }
            }
        }

        ws.onReposUpdated = { [state] repos in
            state.managedRepos = repos
        }

        ws.onReviewJob = { [state, reviews, notifications] job in
            notifications.notify("🟡 收到 Review PR #\(job.pr_num)", "\(job.repo) · \(job.branch ?? "")")
            _ = state
            reviews.enqueue(job)
        }

        ws.onPrClosed = { [state] pc in
            guard let conf = state.config.repos[pc.repo] else { return }
            Task {
                await WorktreeManager.removeWorktree(mainRepo: conf.mainRepo, worktreeBase: conf.worktreeBase, prNum: pc.pr_num)
            }
        }

        ws.onDisconnected = { [state, notifications] _ in
            let running = state.runningJob
            notifications.notify("⚠️ 与 hub 断开", "正在自动重连…" + (running.map { " (PR #\($0.prNum) 仍在本机继续)" } ?? ""))
        }
    }

    private func wireReviews() {
        reviews.currentConfig = { [state] in state.config }
        reviews.sendMessage = { [ws] msg in ws.send(msg) }

        reviews.onJobStart = { [state, notifications] job in
            state.runningJob = AppState.RunningJob(
                repo: job.repo, prNum: job.pr_num, branch: job.branch ?? "",
                stage: "worktree", since: Date()
            )
            notifications.notify("⚡ 正在 Review PR #\(job.pr_num)", "\(job.repo) · \(job.branch ?? "") · 用你的账号在本机自动执行")
        }

        reviews.onStageChange = { [state] job, stage in
            if state.runningJob?.prNum == job.pr_num {
                state.runningJob?.stage = stage
            }
        }

        reviews.onJobFinish = { [state, notifications] job, result in
            state.runningJob = nil
            if result.exitCode == 0, !result.verdict.isEmpty {
                notifications.notify("✅ Review 完成 PR #\(job.pr_num)", "结论 \(result.verdict) · inline \(result.inlineCount) · 已用你的账号提交")
            } else {
                notifications.notify("❌ Review 未完成 PR #\(job.pr_num)", "exit=\(result.exitCode) \(String(result.logTail.prefix(80)))")
            }
        }

        reviews.onQueueChange = { [state] queue in
            state.queuedJobs = queue.map { (repo: $0.repo, prNum: $0.pr_num) }
        }
    }
}

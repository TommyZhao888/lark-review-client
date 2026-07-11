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
    let outbox = ResultOutbox()

    /// 服务端受管清单本地缓存(重启/重连后首次 register 就带上完整自动参与列表; 与 Node 同一文件)。
    private var managedCachePath: String { ConfigStore.configPath + ".managed-cache.json" }
    private func loadManagedCache() -> [ManagedRepo] {
        guard let data = FileManager.default.contents(atPath: managedCachePath),
              let repos = try? JSONDecoder().decode([ManagedRepo].self, from: data) else { return [] }
        return repos.filter { !$0.repo.isEmpty }
    }
    private func saveManagedCache(_ repos: [ManagedRepo]) {
        guard let data = try? JSONEncoder().encode(repos) else { return }
        let tmp = managedCachePath + ".tmp"
        try? data.write(to: URL(fileURLWithPath: tmp))
        _ = rename(tmp, managedCachePath)
    }

    private var pruneTask: Task<Void, Never>?
    private var usageTask: Task<Void, Never>?
    private var started = false
    /// 已对该 recommended 版本自动尝试过更新，防失败后每次重连都重试（一次没成功就等用户手动/换轮）。
    private var autoUpdateTriedFor: String?

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        state.config = ConfigStore.load()
        state.managedRepos = loadManagedCache()
        let repoList = state.config.repos.keys.sorted().joined(separator: ", ")
        let autoNote = state.config.autoRepos ? " + 自动参与服务端受管项目" : ""
        LogStore.shared.log("config \(ConfigStore.configPath) loaded, repos: \(repoList.isEmpty ? "(无)" : repoList)\(autoNote) (身份由服务端按 token 下发)")
        StatuslineInstaller.cleanup()   // 还原旧版为额度快照改过的 statusLine(现改用 /usage 查额度)

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

        // worktree / review 日志过期清理：启动一次 + 每 6h(手动配置 + 自动参与的项目都扫, 按解析后路径)
        pruneTask = Task { @MainActor [state] in
            while !Task.isCancelled {
                let cfg = state.config
                var resolved: [String: RepoConfig] = [:]
                for name in cfg.effectiveRepoNames(managed: state.managedRepos) {
                    let r = cfg.resolveRepo(name)
                    resolved[name] = RepoConfig(mainRepo: r.mainRepo, worktreeBase: r.worktreeBase)
                }
                await WorktreeManager.pruneStaleWorktrees(repos: resolved, maxAgeDays: cfg.worktreeMaxAgeDays)
                LogStore.shared.pruneReviewLogs(maxAgeDays: cfg.worktreeMaxAgeDays)
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }

        // Claude 额度查询: 立即一次 + 每 10min(headless `claude -p /usage`, 零 token; 派活前还会再查一次)。
        // 刷新出新鲜额度就独立上报一次 .quota(不再挂心跳; 与 Node 版一致)。
        usageTask = Task { @MainActor [state, ws] in
            while !Task.isCancelled {
                let ok = await QuotaMonitor.shared.refreshUsage(config: state.config)
                if ok { ws.send(.quota(quota: QuotaMonitor.shared.current(config: state.config))) }
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    func shutdown() {
        LogStore.shared.log("bye")
        pruneTask?.cancel()
        usageTask?.cancel()
        ws.shutdown()
        ChildProcessRegistry.shared.terminateAll()
    }

    /// 设置保存：持久化 + 热重载重连。返回错误信息（nil = 成功）。
    /// v1.7: 路径允许留空 = 自动模式(按默认克隆根目录解析并自动 clone), 不再强制必填。
    func saveConfig(_ cfg: Config) -> String? {
        if cfg.serverUrl.isEmpty || cfg.token.isEmpty {
            return "serverUrl 和 token 必填"
        }
        do {
            try ConfigStore.save(cfg)
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

    /// 自更新：从 GitHub Releases 下载目标版本 dmg → 原地替换自己 → 重启（任意安装位置可用）。
    /// auto=true 为「空闲时自动更新」触发（不打断在跑/排队的 review）。
    func performSelfUpdate(auto: Bool) {
        if case .running = state.updatePhase { return }              // 已在更新中
        if state.runningJob != nil || !state.queuedJobs.isEmpty {
            if auto { return }                                       // 自动模式：有活在跑就不更新，等空闲
            state.updatePhase = .failed("有 review 在跑或排队，等它跑完再更新")
            return
        }
        state.updatePhase = .running("准备…")
        LogStore.shared.log("self-update: 开始更新\(auto ? "（自动，检测到新版本且空闲）" : "（手动）")")
        let target = state.upgrade?.recommended
        Task { [weak self] in
            let outcome = await SelfUpdater.run(targetVersion: target, onStep: { step in
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
                    self.notifications.notify("⚠️ 更新失败", outcome.message)
                    // 「未遂」（安装包未就绪/更新中来单）不算消耗本版本的自动尝试机会。
                    if auto, outcome.retryable { self.autoUpdateTriedFor = nil }
                }
            }
        }
    }

    // ---------- 接线 ----------

    private func wireWebSocket() {
        ws.onStateChange = { [state] s in state.connection = s }
        ws.onFrame = { [state] outbound, text in state.appendWSMessage(outbound: outbound, text: text) }
        // 参与项目列表 = 本机配置 ∪ autoRepos 下的受管清单(注册时上报; 清单变化后重注册)。
        ws.effectiveRepos = { [state] in
            state.config.effectiveRepoNames(managed: state.managedRepos)
        }
        // 结果补投队列接线: 发送经 ws.sendRaw; 注册成功后 flush; 收到 ack 清对应条目。
        outbox.sendRaw = { [ws] text in ws.sendRaw(text) }
        outbox.isRegistered = { [ws] in ws.isRegistered }
        ws.onReviewResultAck = { [outbox] jobId in outbox.ack(jobId: jobId) }

        ws.onRegisterAck = { [self, state, ws, notifications] ack, wasReconnect in
            state.identity = AppState.Identity(
                openId: ack.open_id ?? "",
                name: ack.name ?? "",
                recommendedVersion: ack.recommended_version
            )
            state.upgrade = ack.upgrade
            if let repos = ack.managed_repos {
                state.managedRepos = repos
                self.saveManagedCache(repos)
            }
            // 断线/重启期间攒下的 review 结果(含用量)补投, 收到 ack 才清。
            self.outbox.flush()
            // 首次安装/清单变化: 本次注册可能还没带上受管项目 → 按最新清单重注册(幂等)。
            ws.reRegisterIfReposChanged(reason: "register_ack 下发清单")

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
            if state.config.autoRepos {
                let autoOnes = managedNames.filter { state.config.repos[$0] == nil }.sorted()
                if !autoOnes.isEmpty {
                    LogStore.shared.log("自动参与(未单独配路径, 派单时按需 clone 到 \(state.config.repoBaseDir)): [\(autoOnes.joined(separator: ", "))]")
                }
            } else if state.config.repos.isEmpty {
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
                if state.config.autoUpdate, idle, self.autoUpdateTriedFor != rec {
                    self.autoUpdateTriedFor = rec
                    LogStore.shared.log("自动更新: 检测到新版本 v\(rec) 且空闲，开始自动更新")
                    self.performSelfUpdate(auto: true)
                }
            }
        }

        ws.onReposUpdated = { [self, state, ws] repos in
            state.managedRepos = repos
            self.saveManagedCache(repos)
            ws.reRegisterIfReposChanged(reason: "repos_updated")   // autoRepos 下参与列表随清单联动
        }

        ws.onReviewJob = { [state, reviews, notifications] job in
            notifications.notify("🟡 收到 Review PR #\(job.pr_num)", "\(job.repo) · \(job.branch ?? "")")
            _ = state
            reviews.enqueue(job)
        }

        ws.onPrClosed = { [state] pc in
            guard state.config.participates(pc.repo, managed: state.managedRepos) else { return }
            let conf = state.config.resolveRepo(pc.repo)
            guard FileManager.default.fileExists(atPath: conf.mainRepo) else { return }
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
        reviews.currentManagedRepos = { [state] in state.managedRepos }
        reviews.sendMessage = { [ws] msg in ws.send(msg) }
        reviews.queueResult = { [outbox] jobId, payload in outbox.queue(jobId: jobId, payloadJSON: payload) }

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
                var uNote = ""
                if let u = result.usage, let outTok = u.outputTokens {
                    uNote = " · \(u.inputTokens ?? 0)/\(outTok) tokens $\(u.totalCostUsd ?? 0)"
                }
                notifications.notify("✅ Review 完成 PR #\(job.pr_num)", "结论 \(result.verdict) · inline \(result.inlineCount)\(uNote) · 已用你的账号提交")
            } else {
                notifications.notify("❌ Review 未完成 PR #\(job.pr_num)", "exit=\(result.exitCode) \(String(result.logTail.prefix(80)))")
            }
        }

        reviews.onQueueChange = { [state] queue in
            state.queuedJobs = queue.map { (repo: $0.repo, prNum: $0.pr_num) }
        }
    }
}

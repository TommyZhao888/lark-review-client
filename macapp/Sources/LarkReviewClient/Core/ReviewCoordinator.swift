import Foundation

/// review 任务串行执行（对齐 Node 版 pump/runReviewJob）：一次只跑一单，避免本机多个
/// claude 抢资源。重复派单的防护在服务端（hub 掉线时保留在途 job + 派单去重），
/// client 不做去重——只负责重连 + 把真实结果发回。
@MainActor
final class ReviewCoordinator {

    var currentConfig: () -> Config = { Config() }
    var currentManagedRepos: () -> [ManagedRepo] = { [] }
    var sendMessage: (OutboundMessage) -> Void = { _ in }
    /// 结果经磁盘 pending 队列可靠投递（AppRuntime 接到 ResultOutbox）。
    var queueResult: (_ jobId: String, _ payloadJSON: String) -> Void = { _, _ in }
    var onJobStart: ((ReviewJob) -> Void)?
    var onStageChange: ((ReviewJob, String) -> Void)?
    var onJobFinish: ((ReviewJob, ReviewResult) -> Void)?
    var onQueueChange: (([ReviewJob]) -> Void)?

    private var busy = false
    private var queue: [ReviewJob] = []

    func enqueue(_ job: ReviewJob) {
        queue.append(job)
        onQueueChange?(queue)
        pump()
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let job = queue.removeFirst()
        onQueueChange?(queue)
        onJobStart?(job)
        Task { @MainActor in
            let result = await runReviewJob(job)
            // 结果经 pending 队列可靠投递: 断线窗口内完成 / 进程重启都不丢, 重连后补投直至 hub ack。
            let msg = OutboundMessage.reviewResult(jobId: job.job_id, result: result)
            if let payload = try? msg.encodedString() {
                queueResult(job.job_id, payload)
            } else {
                sendMessage(msg)   // 序列化异常兜底(理论不可达): 至少尽力直发一次
            }
            onJobFinish?(job, result)
            busy = false
            pump()
        }
    }

    private func runReviewJob(_ job: ReviewJob) async -> ReviewResult {
        let cfg = currentConfig()
        // hub 已校验 repo，这里再防一手: 本机配置过, 或 autoRepos 下服务端受管即参与。
        guard cfg.participates(job.repo, managed: currentManagedRepos()) else {
            return ReviewResult(exitCode: 1, logTail: "本机未配置且未自动参与 repo \(job.repo)")
        }
        let conf = cfg.resolveRepo(job.repo)

        // 派活前先查一次最新额度: 不足就【拒接本单】(不跑 review), 交服务端改派给有额度的人。
        await QuotaMonitor.shared.refreshUsage(config: cfg)
        let q0 = QuotaMonitor.shared.current(config: cfg)
        if q0.ok == false {
            LogStore.shared.log("派活前自查: Claude 额度不足(\(q0.reason ?? "?")), 拒接 PR #\(job.pr_num), 交服务端改派")
            var r = ReviewResult(exitCode: 0, logTail: "本机 Claude 额度不足(\(q0.reason ?? "")), 已拒接本单, 交由服务端改派给有额度的人")
            r.quota = q0
            r.declinedQuota = true
            return r
        }

        // mainRepo 尚不存在(自动模式的首个 job, 或手动配了路径但还没 clone)→ 先从远端自动 clone。
        if !FileManager.default.fileExists(atPath: conf.mainRepo + "/.git") {
            sendMessage(.reviewProgress(jobId: job.job_id, stage: "clone"))
            onStageChange?(job, "clone")
        }
        let cl = await RepoCloner.ensureRepoCloned(
            repo: job.repo, provider: job.provider, prUrl: job.pr_url, mainRepo: conf.mainRepo)
        guard cl.ok else {
            return ReviewResult(exitCode: 1, logTail: String("仓库准备失败(自动 clone):\n\(cl.detail)".suffix(4000)))
        }

        sendMessage(.reviewProgress(jobId: job.job_id, stage: "worktree"))
        onStageChange?(job, "worktree")
        let wt = await WorktreeManager.ensureWorktree(
            mainRepo: conf.mainRepo, worktreeBase: conf.worktreeBase,
            prNum: job.pr_num, branch: job.branch, provider: job.provider
        )
        guard wt.ok else {
            return ReviewResult(exitCode: 1, logTail: String("worktree 准备失败:\n\(wt.detail)".suffix(4000)))
        }

        let ciStatus = ciStatusString(overall: job.ci_overall, failedNames: job.ci_failed_names)
        let prompt = renderPrompt(job: job, worktreePath: wt.worktreePath, ciStatus: ciStatus,
                                  repoTemplate: conf.prompt, globalTemplate: cfg.globalPrompt)
        let model = (job.review_model?.isEmpty == false ? job.review_model! : cfg.reviewModel)

        sendMessage(.reviewProgress(jobId: job.job_id, stage: "claude"))
        onStageChange?(job, "claude")
        LogStore.shared.log("running claude --print --model \(model) in \(wt.worktreePath)")
        // --output-format json: 信封里带 usage/total_cost_usd(token 统计用)。老版 claude 不认时
        // parseClaudeEnvelope 返回 nil → 按原始文本走老路径, usage 缺省为空, 零破坏。
        let r = await ProcessRunner.run(cfg.claudePath, [
            "--print", "--output-format", "json", "--model", model, "--dangerously-skip-permissions",
            "--add-dir", conf.mainRepo, "--add-dir", conf.worktreeBase,
        ], cwd: wt.worktreePath, stdin: prompt)

        let envelope = UsageStore.parseClaudeEnvelope(r.stdout)
        let usage = envelope?.usage
        let logText = (envelope?.text ?? r.stdout) + (r.stderr.isEmpty ? "" : "\n" + r.stderr)
        let parsed = parseResultLine(logText)
        let usageNote = usage.map { " tokens(in/out)=\($0.inputTokens ?? -1)/\($0.outputTokens ?? -1) cost=$\($0.totalCostUsd ?? 0)" } ?? ""
        LogStore.shared.log("claude exited=\(r.code) verdict=\(parsed.verdict.isEmpty ? "-" : parsed.verdict) inline=\(parsed.inlineCount)\(usageNote)")
        UsageStore.record(job: job, model: model, exitCode: r.code, verdict: parsed.verdict, usage: usage)
        // 反应式额度检测: 本次 review 若命中限额, 记下重置时间, 之后上报"额度不足", 服务端停派+换人。
        QuotaMonitor.shared.noteReviewOutput(logText)

        let result = ReviewResult(
            exitCode: Int(r.code),
            logTail: String(logText.suffix(8000)),
            resultLine: parsed.resultLine,
            verdict: parsed.verdict,
            generalCommentUrl: parsed.generalCommentUrl,
            inlineCount: parsed.inlineCount,
            quota: QuotaMonitor.shared.current(config: cfg),   // 让服务端立即知道本机额度状态
            usage: usage
        )
        if let saved = LogStore.shared.writeReviewLog(job: job, model: model, exitCode: r.code, result: result, logText: logText) {
            LogStore.shared.log("review 完整日志已存: \(saved)")
        }
        return result
    }
}

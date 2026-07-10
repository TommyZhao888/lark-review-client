import Foundation

/// review 任务串行执行（对齐 Node 版 pump/runReviewJob）：一次只跑一单，避免本机多个
/// claude 抢资源。重复派单的防护在服务端（hub 掉线时保留在途 job + 派单去重），
/// client 不做去重——只负责重连 + 把真实结果发回。
@MainActor
final class ReviewCoordinator {

    var currentConfig: () -> Config = { Config() }
    var sendMessage: (OutboundMessage) -> Void = { _ in }
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
            // 结果照常发回 hub——即使中途断线，重连后这条也会被 hub 接受（hub 保留了该 job）。
            sendMessage(.reviewResult(jobId: job.job_id, result: result))
            onJobFinish?(job, result)
            busy = false
            pump()
        }
    }

    private func runReviewJob(_ job: ReviewJob) async -> ReviewResult {
        let cfg = currentConfig()
        // hub 已校验 repo，这里再防一手。
        guard let conf = cfg.repos[job.repo] else {
            return ReviewResult(exitCode: 1, logTail: "本机未配置 repo \(job.repo)")
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
        let prompt = renderPrompt(job: job, worktreePath: wt.worktreePath, ciStatus: ciStatus, repoTemplate: conf.prompt)
        let model = (job.review_model?.isEmpty == false ? job.review_model! : cfg.reviewModel)

        sendMessage(.reviewProgress(jobId: job.job_id, stage: "claude"))
        onStageChange?(job, "claude")
        LogStore.shared.log("running claude --print --model \(model) in \(wt.worktreePath)")
        let r = await ProcessRunner.run(cfg.claudePath, [
            "--print", "--model", model, "--dangerously-skip-permissions",
            "--add-dir", conf.mainRepo, "--add-dir", conf.worktreeBase,
        ], cwd: wt.worktreePath, stdin: prompt)

        let logText = r.stdout + r.stderr
        let parsed = parseResultLine(logText)
        LogStore.shared.log("claude exited=\(r.code) verdict=\(parsed.verdict.isEmpty ? "-" : parsed.verdict) inline=\(parsed.inlineCount)")
        // 反应式额度检测: 本次 review 若命中限额, 记下重置时间, 之后上报"额度不足", 服务端停派+换人。
        QuotaMonitor.shared.noteReviewOutput(logText)

        let result = ReviewResult(
            exitCode: Int(r.code),
            logTail: String(logText.suffix(8000)),
            resultLine: parsed.resultLine,
            verdict: parsed.verdict,
            generalCommentUrl: parsed.generalCommentUrl,
            inlineCount: parsed.inlineCount,
            quota: QuotaMonitor.shared.current(config: cfg)   // 让服务端立即知道本机额度状态
        )
        if let saved = LogStore.shared.writeReviewLog(job: job, model: model, exitCode: r.code, result: result, logText: logText) {
            LogStore.shared.log("review 完整日志已存: \(saved)")
        }
        return result
    }
}

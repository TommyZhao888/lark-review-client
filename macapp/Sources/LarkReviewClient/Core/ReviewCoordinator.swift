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
    /// 手动终止状态变化(供 UI 展示「终止中…」并防重复点击)。
    var onCancelChange: ((Bool) -> Void)?

    private var busy = false
    private var queue: [ReviewJob] = []
    /// 当前在跑 claude 的进程句柄(用于手动终止)。
    private let procHandle = ProcHandle()
    /// 用户已请求终止当前单(runReviewJob 据此在各阶段间提前收尾)。
    private var cancelRequested = false
    /// 本机 claude 是否支持 stream-json(nil=未知; 首次没拿到 result 事件 → 记 false 走 json)。
    private var streamJsonSupported: Bool?

    func enqueue(_ job: ReviewJob) {
        queue.append(job)
        onQueueChange?(queue)
        pump()
    }

    /// 手动终止当前在跑的 review: 终止 claude 进程 + 标记, 让本单按失败收尾并释放队列(交服务端改派)。
    func cancelCurrent() {
        guard busy, !cancelRequested else { return }
        cancelRequested = true
        onCancelChange?(true)
        LogStore.shared.log("收到手动终止请求, 正在结束当前 Review…")
        procHandle.terminate()
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        cancelRequested = false
        onCancelChange?(false)
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

        if cancelRequested {
            return ReviewResult(exitCode: 130, logTail: "本次 Review 在准备阶段(clone)被手动终止")
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
        if cancelRequested {
            return ReviewResult(exitCode: 130, logTail: "本次 Review 在准备阶段(worktree)被手动终止")
        }

        let ciStatus = ciStatusString(overall: job.ci_overall, failedNames: job.ci_failed_names)
        let prompt = renderPrompt(job: job, worktreePath: wt.worktreePath, ciStatus: ciStatus,
                                  repoTemplate: conf.prompt, globalTemplate: cfg.globalPrompt)
        let model = (job.review_model?.isEmpty == false ? job.review_model! : cfg.reviewModel)

        sendMessage(.reviewProgress(jobId: job.job_id, stage: "claude"))
        onStageChange?(job, "claude")
        // ADO 单: 把 PAT 注入 claude 子进程环境, 让 /pr-review-azdo(经 az/REST 提交评论/投票)能认证。
        // GUI app 从登录项启动拿不到 shell 里 export 的变量, 故经登录 shell 解析(RepoCloner.azdoPat)。
        var claudeEnv: [String: String] = [:]
        if job.provider == "azdo" {
            if let pat = RepoCloner.azdoPat() {
                claudeEnv["AZURE_DEVOPS_EXT_PAT"] = pat
                claudeEnv["AZDO_PAT"] = pat   // 兼容旧变量名
            } else {
                LogStore.shared.log("⚠️ azdo 单但未检测到 AZURE_DEVOPS_EXT_PAT/AZDO_PAT, /pr-review-azdo 可能无法向 ADO 提交评论/投票")
            }
        }
        let timeoutMs = cfg.reviewTimeoutMs
        // 优先 stream-json --verbose: 边跑边把 claude 的工具调用/文字喂进运行日志(实时可见);
        // 末尾 result 事件带最终文本+用量(与 json 信封同字段, 复用 parseClaudeEnvelope)。
        // 老版 claude 不支持 → 本次拿不到 result 事件, 回退 --output-format json 重跑并记住(能力探测)。
        let useStream = (streamJsonSupported != false)
        let baseArgs = ["--print", "--model", model, "--dangerously-skip-permissions",
                        "--add-dir", conf.mainRepo, "--add-dir", conf.worktreeBase]
        let streamArgs = ["--output-format", "stream-json", "--verbose"] + baseArgs
        let jsonArgs = ["--output-format", "json"] + baseArgs
        LogStore.shared.log("running claude --print (\(useStream ? "stream-json" : "json")) --model \(model) in \(wt.worktreePath)"
            + (timeoutMs > 0 ? " (超时 \(timeoutMs / 60000) 分钟)" : " (无超时)"))

        let resultBox = StringBox()
        let prNum = job.pr_num
        let onLine: (@Sendable (String) -> Void)?
        if useStream {
            onLine = { line in
                let (logs, isResult) = ClaudeStream.parseLine(line)
                for l in logs { LogStore.shared.log("PR #\(prNum) \(l)") }
                if isResult { resultBox.set(line) }
            }
        } else {
            onLine = nil
        }

        // 心跳: claude 长时间无事件(思考中)也让运行日志看得到"活着"。
        let claudeStart = Date()
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                let secs = Int(Date().timeIntervalSince(claudeStart))
                LogStore.shared.log("PR #\(job.pr_num) review 进行中… claude 已运行 \(secs)s")
            }
        }
        var r = await ProcessRunner.run(cfg.claudePath, useStream ? streamArgs : jsonArgs,
            cwd: wt.worktreePath, stdin: prompt, extraEnv: claudeEnv,
            timeoutMs: timeoutMs, handle: procHandle, onOutputLine: onLine)

        // 结果信封来源: stream 模式取 result 事件那行; json 模式取整段 stdout。
        var payload: String? = useStream ? (resultBox.get() ?? ClaudeStream.scanResultLine(r.stdout))
                                          : (r.stdout.isEmpty ? nil : r.stdout)
        // 用了 stream 却没拿到 result 事件, 且不是被终止/超时 → 判定老版不支持: 回退 json 重跑一次并记住。
        if useStream, payload == nil, !cancelRequested, r.code != 124 {
            streamJsonSupported = false
            LogStore.shared.log("claude 未产出 stream-json 结果事件, 回退 --output-format json 重跑一次")
            r = await ProcessRunner.run(cfg.claudePath, jsonArgs, cwd: wt.worktreePath,
                stdin: prompt, extraEnv: claudeEnv, timeoutMs: timeoutMs, handle: procHandle)
            payload = r.stdout.isEmpty ? nil : r.stdout
        } else if useStream, payload != nil {
            streamJsonSupported = true
        }
        heartbeat.cancel()

        let elapsed = Int(Date().timeIntervalSince(claudeStart))
        let envelope = UsageStore.parseClaudeEnvelope(payload ?? "")
        let usage = envelope?.usage
        // stream 模式 r.stdout 是整段 NDJSON, 不能当正文; 优先用 result 事件里的最终文本。
        let baseText = envelope?.text ?? (useStream ? (payload ?? "(未取到 claude 结果)") : r.stdout)
        var logText = baseText + (r.stderr.isEmpty ? "" : "\n" + r.stderr)
        // 手动终止 / 超时: 在日志正文顶部标注(stdout 多半为空), 仍按失败上报交服务端改派。
        if cancelRequested {
            LogStore.shared.log("PR #\(job.pr_num) review 已被手动终止 (claude 运行 \(elapsed)s)")
            logText = "⛔ 本次 Review 被用户手动终止 (claude 运行 \(elapsed)s)。\n\n" + logText
        } else if r.code == 124 {
            LogStore.shared.log("⏱ PR #\(job.pr_num) review 超时(\(timeoutMs / 60000) 分钟)已自动终止, 上报失败交服务端改派")
            logText = "⏱ 本次 Review 超时 (\(timeoutMs / 60000) 分钟) 已自动终止。\n\n" + logText
        }
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

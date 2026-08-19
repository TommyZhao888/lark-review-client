import Foundation

/// review 任务串行执行（对齐 Node 版 pump/runReviewJob）：一次只跑一单，避免本机多个
/// claude 抢资源。重复派单的防护主要在服务端（hub 掉线时保留在途 job + 派单去重）；
/// client 只做两件它能确定的事：
///   1. 同一 (repo, PR) 的【待跑】job 只留最新的一个 —— 见 enqueue；
///   2. 上一单跑完后，若排在它后面的同 PR job 面对的 head 与它刚评审并提交的 head 一致 → 跳过，
///      沿用上一单结论 —— 见 DuplicateGuard。
/// 除此以外一律照跑（尤其“再来一轮”这类合法重派）：宁可重复也不漏。
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
    /// 当前在跑的 job(同 head 去重要知道"本单排在谁后面"; 对齐 Node 版 runningJob)。
    private var runningJob: ReviewJob?
    private let dupGuard = DuplicateGuard()

    func enqueue(_ job: ReviewJob) {
        // hub 判一单超时的死线从派单起算, 而本机串行排队期间不发 review_progress —— 队列一深, 还没
        // 轮到的 job 就会被 hub 判失败并重派, 而老 job 仍躺在队列里 → 同一个 head 被 review 两遍。
        // (2026-08-07 实测: hub 一次派 6 单, #696 排队 33min 被判失败重派, 队列里同时出现两个 #696。)
        // 两个 job 都还没开跑, 留新的永远不亏: 重试 = 纯重复; 新一轮 = 老的在评审过期 head。
        // 已开跑的那单不动(它可能正在评审老 head, 新一轮理应排在它后面) —— 但记下"本单排在谁后面":
        // 那一单的结论 hub 派本单时还看不到, 本单可能只是它的重复(开跑前用 head 一比就知道)。
        dupGuard.noteDispatch(job, runningJob: runningJob)
        let stale = queue.filter { $0.repo == job.repo && $0.pr_num == job.pr_num }
        queue.removeAll { $0.repo == job.repo && $0.pr_num == job.pr_num }
        queue.append(job)
        for s in stale {
            LogStore.shared.log("队列去重: PR #\(s.pr_num) 已有新 job \(job.job_id) → 丢弃尚未开跑的旧 job \(s.job_id)")
            dupGuard.forget(s.job_id)
            // 立刻回执, 别让 hub 空等到超时(空等正是重派的成因)。exit 0 + 空 verdict = 没跑出 review。
            let r = ReviewResult(exitCode: 0, logTail: "尚未开跑就被同 PR 的新 job \(job.job_id) 取代"
                                 + "(hub 重派或新一轮), 本机已丢弃本单; 请以新 job 的结果为准")
            let msg = OutboundMessage.reviewResult(jobId: s.job_id, result: r)
            if let payload = try? msg.encodedString() { queueResult(s.job_id, payload) } else { sendMessage(msg) }
        }
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
        runningJob = job
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
            runningJob = nil
            dupGuard.forget(job.job_id)
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

        // 同 head 重复派单: 上一单还在跑时 hub 又派了本单(它当时看不到上一单的结论), 而上一单已经把这个
        // head 评审完并提交了 review → 再跑一遍纯属重复(2026-08-14 PR #736 实测: 两条 APPROVE + 4 条同位置
        // inline 落在同一个 head c390e813, 白烧一轮 opus)。此时直接沿用上一单的结论回执, 不再跑 claude。
        if let dup = dupGuard.duplicate(of: job, head: wt.head) {
            let url = dup.generalCommentUrl.isEmpty ? "无链接" : dup.generalCommentUrl
            let short = String(wt.head.prefix(8))
            LogStore.shared.log("跳过重复 review: PR #\(job.pr_num) head \(short) 已由 job \(dup.jobId) 评审并提交(\(url))")
            var r = ReviewResult(
                exitCode: 0,
                logTail: "本单在 job \(dup.jobId) 运行期间派出, 而该单已对同一个 head \(short) 完成评审并提交 review"
                    + "(\(url), 结论 \(dup.verdict))。head 未变, 本机跳过重复评审, 结论沿用上一单。",
                resultLine: dup.resultLine, verdict: dup.verdict,
                generalCommentUrl: dup.generalCommentUrl, inlineCount: dup.inlineCount,
                quota: QuotaMonitor.shared.current(config: cfg))
            r.dedupedOf = dup.jobId
            return r
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
        // 本单确实提交了 review(有结论) → 记下"这个 head 已评审过", 供同 head 重复派单去重。
        if r.code == 0, !parsed.verdict.isEmpty, !wt.head.isEmpty {
            dupGuard.noteReviewed(job, head: wt.head, result: result)
        }
        if let saved = LogStore.shared.writeReviewLog(job: job, model: model, exitCode: r.code, result: result,
                                                      logText: logText, head: wt.head) {
            LogStore.shared.log("review 完整日志已存: \(saved)")
        }
        return result
    }
}

/// 同 head 重复派单的判定（与 Node 版 dispatchedBehind / lastReviewed / duplicateReviewOf 逐条对齐）。
/// 纯状态机、不碰 IO：本机内存态，进程重启清零无碍（只影响一个 review 时段内的去重）。
@MainActor
final class DuplicateGuard {

    /// 本机已提交过 review 的那一单（沿用它的结论时要原样回执给 hub）。
    struct Done: Equatable {
        var jobId: String
        var head: String
        var verdict: String
        var generalCommentUrl: String
        var inlineCount: String
        var resultLine: String
    }

    private var behind: [String: String] = [:]   // job_id → 派本单时同 (repo,PR) 正在跑的 job_id
    private var done: [String: Done] = [:]       // "repo#pr" → 本机最近一单已提交的 review

    static func key(_ job: ReviewJob) -> String { "\(job.repo)#\(job.pr_num)" }

    /// 入队时：同 (repo,PR) 已有一单在跑 → 记下本单「排在谁后面」（它的结论 hub 派本单时看不到）。
    func noteDispatch(_ job: ReviewJob, runningJob: ReviewJob?) {
        guard let run = runningJob, run.repo == job.repo, run.pr_num == job.pr_num else { return }
        behind[job.job_id] = run.job_id
    }

    /// 本单确实提交了 review → 记下「这个 head 已评审过」。
    func noteReviewed(_ job: ReviewJob, head: String, result: ReviewResult) {
        done[Self.key(job)] = Done(jobId: job.job_id, head: head, verdict: result.verdict,
                                   generalCommentUrl: result.generalCommentUrl,
                                   inlineCount: result.inlineCount, resultLine: result.resultLine)
    }

    /// 本单收尾/被丢弃 → 清掉它的排队关系（只留 done，供后续单比 head）。
    func forget(_ jobId: String) { behind.removeValue(forKey: jobId) }

    /// 三条同时成立才算同 head 重复单：本单是在上一单【还在跑】时派出的（hub 当时看不到上一单结论，
    /// 故不可能是人看完结论主动要的「再来一轮」）、上一单确实提交了 review、当前 head 与它评审的
    /// head 一致（有新推送则 head 变 → 照跑）。任一条不满足都返回 nil（照跑）。
    func duplicate(of job: ReviewJob, head: String) -> Done? {
        guard let b = behind[job.job_id], !head.isEmpty,
              let prev = done[Self.key(job)], prev.jobId == b, prev.head == head else { return nil }
        return prev
    }
}

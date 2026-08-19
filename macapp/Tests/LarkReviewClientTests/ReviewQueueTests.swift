import XCTest
@testable import LarkReviewClient

/// 队列去重(v1.9.3)。背景: hub 判一单超时的死线从派单起算, 而本机串行排队期间不发
/// review_progress —— 队列一深, 还没轮到的 job 就被 hub 判失败并重派, 老 job 仍躺在队列里
/// → 同一个 head 被 review 两遍(2026-08-07 PR #696 实测: hub 一次派 6 单, 队列里出现两个 #696)。
@MainActor
final class ReviewQueueTests: XCTestCase {

    /// enqueue 去重会走 LogStore, 而 LogStore 单例默认写【生产日志】~/.lark-review-client.log。
    /// 在 shared 首次初始化前把两个路径改到临时目录, 别让 `swift test` 往真日志里灌测试噪音。
    override class func setUp() {
        let tmp = NSTemporaryDirectory() + "lark-review-tests-\(ProcessInfo.processInfo.processIdentifier)"
        setenv("LARK_REVIEW_CLIENT_LOG", tmp + ".log", 1)
        setenv("LARK_REVIEW_CLIENT_REVIEW_LOG_DIR", tmp + "-logs", 1)
    }

    private func job(_ id: String, _ pr: Int, repo: String = "o/r") -> ReviewJob {
        ReviewJob(job_id: id, pr_num: pr, repo: repo)
    }

    /// 首单被 pump 立刻取走(busy 期间 Task 不会在同步测试体里推进), 之后入队的都留在队列里可观察。
    func testNewerJobForSamePrReplacesQueuedOne() throws {
        let c = ReviewCoordinator()
        var lastQueue: [ReviewJob] = []
        var reported: [String] = []
        var payloads: [String: String] = [:]
        c.onQueueChange = { lastQueue = $0 }
        c.queueResult = { id, payload in reported.append(id); payloads[id] = payload }

        c.enqueue(job("j1", 700))     // 开跑
        c.enqueue(job("j2", 696))
        c.enqueue(job("j3", 695))
        c.enqueue(job("j4", 696))     // 同 PR 的新 job → 顶掉尚未开跑的 j2

        XCTAssertEqual(lastQueue.map(\.job_id), ["j3", "j4"])
        XCTAssertEqual(lastQueue.map(\.pr_num), [695, 696])

        // 被顶掉的那单立刻回执, 不让 hub 空等到超时(空等正是重派的成因)。
        XCTAssertEqual(reported, ["j2"])
        let payload = try XCTUnwrap(payloads["j2"])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "review_result")
        XCTAssertEqual(obj["job_id"] as? String, "j2")
        XCTAssertEqual(obj["exit_code"] as? Int, 0)
        XCTAssertEqual(obj["verdict"] as? String, "")          // 没跑出 review
        XCTAssertTrue((obj["log_tail"] as? String ?? "").contains("j4"), "回执要指明被哪个 job 取代")
    }

    /// 已开跑的那单不动: 它可能正在评审老 head, 新一轮理应排在它后面, 不能被顶掉。
    func testRunningJobIsNotDeduped() {
        let c = ReviewCoordinator()
        var lastQueue: [ReviewJob] = []
        var reported: [String] = []
        c.onQueueChange = { lastQueue = $0 }
        c.queueResult = { id, _ in reported.append(id) }

        c.enqueue(job("j1", 696))     // 开跑
        c.enqueue(job("j2", 696))

        XCTAssertEqual(lastQueue.map(\.job_id), ["j2"])
        XCTAssertTrue(reported.isEmpty)
    }

    /// 去重键是 (repo, pr_num): 不同 repo 的同号 PR 不能互相顶掉。
    func testSamePrNumberInDifferentReposDoNotCollide() {
        let c = ReviewCoordinator()
        var lastQueue: [ReviewJob] = []
        c.onQueueChange = { lastQueue = $0 }

        c.enqueue(job("j0", 1, repo: "o/a"))      // 开跑
        c.enqueue(job("j1", 696, repo: "o/a"))
        c.enqueue(job("j2", 696, repo: "o/b"))

        XCTAssertEqual(lastQueue.map(\.job_id), ["j1", "j2"])
    }

    // MARK: - 同 head 去重(v1.9.3)
    // 背景: 上一单还在跑时 hub 又派了同 PR 一单(它当时看不到上一单结论), 上一单跑完提交了 review,
    // 排在后面的那单又把同一个 head 评审一遍 —— 2026-08-14 PR #736 实测两条 APPROVE + 4 条同位置
    // inline 落在同一个 head c390e813。

    private func done(_ verdict: String = "APPROVE") -> ReviewResult {
        ReviewResult(exitCode: 0, logTail: "", resultLine: "___RESULT___ verdict=\(verdict) …",
                     verdict: verdict, generalCommentUrl: "https://x/pull/736#review-1", inlineCount: "2")
    }

    /// 在跑的单期间派出 + 上一单已提交 review + head 未变 → 判为重复, 沿用上一单结论。
    func testSameHeadDuringRunningJobIsDuplicate() throws {
        let g = DuplicateGuard()
        let j1 = job("j1", 736), j2 = job("j2", 736)
        g.noteDispatch(j2, runningJob: j1)
        g.noteReviewed(j1, head: "c390e813ff", result: done())

        let dup = try XCTUnwrap(g.duplicate(of: j2, head: "c390e813ff"))
        XCTAssertEqual(dup.jobId, "j1")
        XCTAssertEqual(dup.verdict, "APPROVE")
        XCTAssertEqual(dup.generalCommentUrl, "https://x/pull/736#review-1")
        XCTAssertEqual(dup.inlineCount, "2")
    }

    /// 期间有新推送 → head 变了, 本单要真跑(评审的是新代码)。
    func testNewHeadIsNotDuplicate() {
        let g = DuplicateGuard()
        let j1 = job("j1", 736), j2 = job("j2", 736)
        g.noteDispatch(j2, runningJob: j1)
        g.noteReviewed(j1, head: "c390e813ff", result: done())

        XCTAssertNil(g.duplicate(of: j2, head: "deadbeef00"))
        XCTAssertNil(g.duplicate(of: j2, head: ""), "拿不到 head 时不敢判重复, 照跑")
    }

    /// 上一单出结论【之后】才派的单 = 人主动要的"再来一轮", 绝不能拦。
    func testJobDispatchedAfterPreviousFinishedIsNotDuplicate() {
        let g = DuplicateGuard()
        let j1 = job("j1", 736), j2 = job("j2", 736)
        g.noteReviewed(j1, head: "c390e813ff", result: done())   // 上一单已收尾(没有 noteDispatch)

        XCTAssertNil(g.duplicate(of: j2, head: "c390e813ff"))
    }

    /// 排在 j1 后面, 但已提交的 review 是更早的 j0 的(j1 自己没跑出结论) → 不算重复, 照跑。
    func testDuplicateRequiresPreviousToBeTheJobWeQueuedBehind() {
        let g = DuplicateGuard()
        let j0 = job("j0", 736), j1 = job("j1", 736), j2 = job("j2", 736)
        g.noteReviewed(j0, head: "c390e813ff", result: done())
        g.noteDispatch(j2, runningJob: j1)

        XCTAssertNil(g.duplicate(of: j2, head: "c390e813ff"))
    }

    /// 去重键是 (repo, pr_num): 不同 repo 的同号 PR 不能互相认成重复。
    func testDuplicateKeyIncludesRepo() {
        let g = DuplicateGuard()
        let a1 = job("a1", 736, repo: "o/a"), a2 = job("a2", 736, repo: "o/a")
        let b2 = job("b2", 736, repo: "o/b")
        g.noteDispatch(a2, runningJob: a1)
        g.noteDispatch(b2, runningJob: a1)          // 不同 repo: noteDispatch 本身就不该记
        g.noteReviewed(a1, head: "c390e813ff", result: done())

        XCTAssertNotNil(g.duplicate(of: a2, head: "c390e813ff"))
        XCTAssertNil(g.duplicate(of: b2, head: "c390e813ff"))
    }

    /// 本单收尾后清掉排队关系: 同一个 job_id 不会在下一轮被误判(id 复用/重投)。
    func testForgetClearsDispatchRelation() {
        let g = DuplicateGuard()
        let j1 = job("j1", 736), j2 = job("j2", 736)
        g.noteDispatch(j2, runningJob: j1)
        g.noteReviewed(j1, head: "c390e813ff", result: done())
        g.forget(j2.job_id)

        XCTAssertNil(g.duplicate(of: j2, head: "c390e813ff"))
    }
}

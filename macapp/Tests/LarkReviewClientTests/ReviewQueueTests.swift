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
}

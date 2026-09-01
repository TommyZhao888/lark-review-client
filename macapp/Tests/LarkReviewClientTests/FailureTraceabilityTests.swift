import XCTest
@testable import LarkReviewClient

/// 测试用的临时日志路径：LogStore 是单例且默认写【生产日志】~/.lark-review-client.log，
/// 必须在 shared 首次初始化前把两个路径改到临时目录（与 ReviewQueueTests 用同一份路径，
/// 无论哪个测试类先跑都指向同一个临时目录）。
private func redirectLogStoreToTemp() {
    let tmp = NSTemporaryDirectory() + "lark-review-tests-\(ProcessInfo.processInfo.processIdentifier)"
    setenv("LARK_REVIEW_CLIENT_LOG", tmp + ".log", 1)
    setenv("LARK_REVIEW_CLIENT_REVIEW_LOG_DIR", tmp + "-logs", 1)
}

/// 失败可追溯性（2026-09-01 PR #916 实测）：hub 的失败卡片让成员「详见你本机日志」，而
/// claude 起跑前就结束的单（repo 未参与 / clone 失败 / worktree 失败 / 准备阶段被终止）
/// 既不写运行日志、也不落 review 日志，只把原因塞进回执发给 hub —— 连续两次派单在本机
/// 全程零日志，成员翻不到任何线索。这里钉住「任何一单都在本机留下可查记录」。
@MainActor
final class EarlyFailureLogTests: XCTestCase {

    override class func setUp() { redirectLogStoreToTemp() }

    /// repo 未参与是最早的一条早退分支：不碰网络、不碰 git，专测「失败必落盘」这一件事。
    private func runUnparticipatedJob(pr: Int) async {
        let c = ReviewCoordinator()
        var reported = false
        c.queueResult = { _, _ in reported = true }
        c.enqueue(ReviewJob(job_id: "j-early-\(pr)", pr_num: pr, repo: "unconfigured/repo"))
        for _ in 0..<100 where !reported {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(reported, "早退分支也必须回执, 否则 hub 会空等到超时")
    }

    func testEarlyFailureLeavesReviewLogOnDisk() async {
        let pr = 990_001
        await runUnparticipatedJob(pr: pr)
        let files = LogStore.shared.listReviewLogs().map(\.file)
        XCTAssertTrue(files.contains { $0.hasPrefix("pr-\(pr)-") },
                      "claude 起跑前就失败的单也要落一份 review 日志, 否则卡片那句「详见本机日志」是空头支票; 现有: \(files)")
    }

    func testEarlyFailureWritesReasonToRunLog() async {
        let pr = 990_002
        await runUnparticipatedJob(pr: pr)
        XCTAssertTrue(LogStore.shared.tailLog().contains("unconfigured/repo"),
                      "运行日志要留下失败原因, 否则本机只剩一条转瞬即逝的系统通知")
    }
}

/// worktree 自愈（2026-09-01 PR #916 实测）：主仓的 .git/worktrees/<name> admin 目录被并发的
/// `worktree remove` / `worktree prune` 清掉后，工作树目录还在但已不是 git 仓库 →
/// `reset --hard` 永远 fatal，该 PR 每次重派都必然失败，形成死循环。刷新失败要能删掉重建。
final class WorktreeSelfHealTests: XCTestCase {

    override class func setUp() { redirectLogStoreToTemp() }

    private var root = ""

    override func setUp() async throws {
        try await super.setUp()
        root = NSTemporaryDirectory() + "wt-heal-\(ProcessInfo.processInfo.processIdentifier)-\(name.hashValue)"
        try? FileManager.default.removeItem(atPath: root)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: root)
        try await super.tearDown()
    }

    @discardableResult
    private func git(_ args: [String]) async -> ProcessResult {
        await ProcessRunner.run("/usr/bin/git", ["-c", "user.email=t@t", "-c", "user.name=t"] + args)
    }

    /// 造一个「主仓 + origin 裸仓 + 一条 feature 分支」的最小现场。
    private func makeRepo() async throws -> (main: String, worktreeBase: String, branch: String) {
        let origin = root + "/origin.git", main = root + "/main", branch = "feature/x"
        await git(["init", "--bare", "-b", "main", origin])
        await git(["init", "-b", "main", main])
        try "hi".write(toFile: main + "/f.txt", atomically: true, encoding: .utf8)
        await git(["-C", main, "add", "."])
        await git(["-C", main, "commit", "-m", "init"])
        await git(["-C", main, "remote", "add", "origin", origin])
        await git(["-C", main, "push", "origin", "main"])
        await git(["-C", main, "branch", branch])
        await git(["-C", main, "push", "origin", branch])
        return (main, root + "/worktrees", branch)
    }

    func testRefreshFailureRebuildsBrokenWorktree() async throws {
        let (main, wtBase, branch) = try await makeRepo()
        let first = await WorktreeManager.ensureWorktree(
            mainRepo: main, worktreeBase: wtBase, prNum: 1, branch: branch, provider: nil)
        XCTAssertTrue(first.ok, "前置条件: 首次应能建出 worktree — \(first.detail)")

        // 远端把该分支推进一格: 重建必须落在这个新 commit 上, 而不是本地分支停着的旧 commit。
        let newHead = try await advanceRemoteBranch(main: main, branch: branch)

        // 模拟并发 prune：admin 目录没了，工作树目录还在 → 已不是 git 仓库。
        try FileManager.default.removeItem(atPath: main + "/.git/worktrees/pr-1")

        let second = await WorktreeManager.ensureWorktree(
            mainRepo: main, worktreeBase: wtBase, prNum: 1, branch: branch, provider: nil)
        XCTAssertTrue(second.ok, "admin 目录丢失后应删掉重建, 而不是让该 PR 永久卡死 — \(second.detail)")
        XCTAssertEqual(second.head, newHead,
                       "重建要落在 origin/\(branch) 上; 检出本地分支会静默拿旧代码跑完整 review 并发到 PR")
    }

    /// 首建路径同样不能用本地分支: removeWorktree/pruneStaleWorktrees 删目录 + prune 后本地分支
    /// 还在且停在旧 commit, 下次派单会静默检出旧代码。
    func testFreshWorktreeChecksOutRemoteHeadNotStaleLocalBranch() async throws {
        let (main, wtBase, branch) = try await makeRepo()
        let first = await WorktreeManager.ensureWorktree(
            mainRepo: main, worktreeBase: wtBase, prNum: 2, branch: branch, provider: nil)
        XCTAssertTrue(first.ok, "前置条件: 首次应能建出 worktree — \(first.detail)")

        let newHead = try await advanceRemoteBranch(main: main, branch: branch)
        await WorktreeManager.removeWorktree(mainRepo: main, worktreeBase: wtBase, prNum: 2)

        let again = await WorktreeManager.ensureWorktree(
            mainRepo: main, worktreeBase: wtBase, prNum: 2, branch: branch, provider: nil)
        XCTAssertTrue(again.ok, "worktree 被清掉后应能重新建出 — \(again.detail)")
        XCTAssertEqual(again.head, newHead, "首建也要以 origin/\(branch) 为准, 本地分支可能停在旧 commit")
    }

    /// 用另一份 clone 把 origin 上的分支推进一格, 返回新 head(主仓不 fetch, 保持本地分支过期)。
    private func advanceRemoteBranch(main: String, branch: String) async throws -> String {
        let side = root + "/side"
        await git(["clone", "--branch", branch, root + "/origin.git", side])
        try "bye".write(toFile: side + "/f.txt", atomically: true, encoding: .utf8)
        await git(["-C", side, "commit", "-am", "advance"])
        await git(["-C", side, "push", "origin", branch])
        let h = await git(["-C", side, "rev-parse", "HEAD"])
        return h.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

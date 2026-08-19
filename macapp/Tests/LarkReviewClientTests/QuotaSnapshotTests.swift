import XCTest
@testable import LarkReviewClient

/// 设置窗口「额度」tab 的数据来源：/usage 文本解析 → QuotaSnapshot（展示）+ QuotaStatus（上报）。
/// 关键约束：新增的「按模型周窗」只进快照，绝不进上报载荷（协议不变）。
@MainActor
final class QuotaSnapshotTests: XCTestCase {

    /// claude 2.1.x `/usage` 的真实输出（团队套餐；末行是按模型的周窗）。
    private let usageText = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 19% used · resets Aug 3 at 7pm (Asia/Shanghai)
    Current week (all models): 11% used · resets Aug 8 at 3pm (Asia/Shanghai)
    Current week (Fable): 0% used

    What's contributing to your limits usage?
    Last 7d · 223 requests · 3 sessions
    """

    func testSnapshotExposesWindowsAndPerModelWeekRows() {
        let q = QuotaMonitor.shared
        XCTAssertTrue(q.parseUsageText(usageText))

        let snap = q.snapshot(config: Config())
        XCTAssertEqual(snap.fiveHour.pct, 19)
        XCTAssertEqual(snap.sevenDay.pct, 11)
        XCTAssertNotNil(snap.fiveHour.resetAt, "5 小时窗要带出重置时间")
        XCTAssertNotNil(snap.sevenDay.resetAt)
        XCTAssertTrue(snap.fresh, "刚解析完必须算新鲜")
        XCTAssertNil(snap.lastError, "解析成功要清掉上一次的失败原因")
        XCTAssertTrue(snap.ok, "19%/11% 远低于 90/95 阈值 → 可接单")

        // 「all models」那行已单独解析，不得重复出现在按模型列表里。
        XCTAssertEqual(snap.modelWindows.map(\.name), ["Fable"])
        XCTAssertEqual(snap.modelWindows.first?.pct, 0)
        XCTAssertNil(snap.modelWindows.first?.resetAt, "该行没给 resets → 重置时间为空而不是瞎猜")
    }

    /// 展示字段不得污染上报协议：quota 载荷仍只有既有 7 个键。
    func testReportedQuotaPayloadUnchangedByDisplayFields() {
        let q = QuotaMonitor.shared
        XCTAssertTrue(q.parseUsageText(usageText))

        let payload = q.current(config: Config()).jsonObject
        XCTAssertEqual(Set(payload.keys),
                       ["ok", "five_hour_pct", "five_hour_reset_at", "seven_day_pct", "seven_day_reset_at"])
        XCTAssertEqual(payload["five_hour_pct"] as? Int, 19)
        XCTAssertEqual(payload["seven_day_pct"] as? Int, 11)
    }

    /// 解析不出百分比（未登录/不是真 claude）时：不覆盖旧值，且记下可行动的失败原因。
    func testParseFailureKeepsPreviousValues() {
        let q = QuotaMonitor.shared
        XCTAssertTrue(q.parseUsageText(usageText))
        XCTAssertFalse(q.parseUsageText("You are currently using your subscription\n\n(只有用量构成, 没有百分比行)"))

        let snap = q.snapshot(config: Config())
        XCTAssertEqual(snap.fiveHour.pct, 19, "失败不清空缓存，继续展示上一次的值")
        XCTAssertEqual(snap.modelWindows.map(\.name), ["Fable"])
    }

    /// 「最近一次 review 实际模型」取最后一条带 model 的记录（坏行/缺字段跳过）。
    func testLastReviewPicksNewestUsableRecord() throws {
        let file = NSTemporaryDirectory() + "lrc-usage-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: file) }
        try """
        {"ts":"2026-08-02T09:12:33Z","repo":"o/r","pr_num":"812","model":"claude-opus-4-8"}
        {"ts":"2026-08-03T01:40:11Z","repo":"o/r","pr_num":"815","model":"claude-sonnet-4-6"}
        {"ts":"2026-08-03T02:00:00Z","repo":"o/r","pr_num":"816"}
        坏行不是 json
        """.write(toFile: file, atomically: true, encoding: .utf8)

        let lr = try XCTUnwrap(UsageStore.lastReview(file: file))
        XCTAssertEqual(lr.model, "claude-sonnet-4-6")
        XCTAssertEqual(lr.prNum, "815")
        XCTAssertNotNil(lr.ts)

        XCTAssertNil(UsageStore.lastReview(file: file + ".missing"), "还没跑过 review → nil")
    }

    /// 探针参数: 默认带 --no-session-persistence(否则每次 /usage 都在 ~/.claude 落一条会话记录);
    /// 老版 claude 不认时去掉重试, 其余参数一字不动。
    func testUsageArgsCarryNoSessionPersistenceUnlessDisabled() {
        let on = QuotaMonitor.usageArgs(noSessionPersistence: true)
        XCTAssertEqual(on, ["-p", "/usage", "--output-format", "json",
                            "--dangerously-skip-permissions", "--no-session-persistence"])

        let off = QuotaMonitor.usageArgs(noSessionPersistence: false)
        XCTAssertEqual(off, ["-p", "/usage", "--output-format", "json", "--dangerously-skip-permissions"],
                       "回退只摘掉这一个开关: /usage 与 skip-permissions 都不能丢")
    }

    /// 只有"不认这个开关"才回退 —— 额度真的查不到(过期/不是 claude)不能被误判成开关问题。
    func testUnknownOptionDetection() {
        XCTAssertTrue(QuotaMonitor.isUnknownOptionError("error: unknown option '--no-session-persistence'"))
        XCTAssertTrue(QuotaMonitor.isUnknownOptionError("Error: Unknown flag: --no-session-persistence"))
        XCTAssertFalse(QuotaMonitor.isUnknownOptionError(
            "OAuth access token has expired. Re-authenticate to continue."))
        XCTAssertFalse(QuotaMonitor.isUnknownOptionError(""))
    }
}

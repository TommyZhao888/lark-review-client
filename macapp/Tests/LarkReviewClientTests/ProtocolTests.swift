import XCTest
@testable import LarkReviewClient

final class ProtocolTests: XCTestCase {

    // ---------- 出站消息 JSON 与 Node 版逐字段对齐 ----------

    private func jsonObject(_ msg: OutboundMessage) throws -> [String: Any] {
        let text = try msg.encodedString()
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    func testRegisterMessage() throws {
        let obj = try jsonObject(.register(token: "tk", hostname: "my-mac", repos: ["a/b", "c/d"], version: "2.0.0"))
        XCTAssertEqual(obj["type"] as? String, "register")
        XCTAssertEqual(obj["token"] as? String, "tk")
        XCTAssertEqual(obj["hostname"] as? String, "my-mac")
        XCTAssertEqual(obj["repos"] as? [String], ["a/b", "c/d"])
        XCTAssertEqual(obj["version"] as? String, "2.0.0")
        XCTAssertNil(obj["open_id"], "绝不上报 open_id（防冒名，身份归服务端）")
        XCTAssertNil(obj["name"])
    }

    func testHeartbeat() throws {
        let obj = try jsonObject(.heartbeat)
        XCTAssertEqual(obj as? [String: String], ["type": "heartbeat"])
    }

    func testReviewProgress() throws {
        let obj = try jsonObject(.reviewProgress(jobId: "j1", stage: "worktree"))
        XCTAssertEqual(obj["type"] as? String, "review_progress")
        XCTAssertEqual(obj["job_id"] as? String, "j1")
        XCTAssertEqual(obj["stage"] as? String, "worktree")
    }

    func testReviewResultInlineCountIsString() throws {
        let r = ReviewResult(exitCode: 0, logTail: "tail", resultLine: "___RESULT___ …",
                             verdict: "APPROVE", generalCommentUrl: "https://x", inlineCount: "3")
        let obj = try jsonObject(.reviewResult(jobId: "j1", result: r))
        XCTAssertEqual(obj["type"] as? String, "review_result")
        XCTAssertEqual(obj["exit_code"] as? Int, 0)
        // 关键兼容点：inline_count 必须是字符串（Node 版是正则捕获串，失败时 "?"）
        XCTAssertEqual(obj["inline_count"] as? String, "3")
        XCTAssertEqual(obj["verdict"] as? String, "APPROVE")
        XCTAssertEqual(obj["general_comment_url"] as? String, "https://x")
        XCTAssertEqual(obj["log_tail"] as? String, "tail")
    }

    func testReviewResultFailureDefaults() throws {
        let r = ReviewResult(exitCode: 1, logTail: "err")
        let obj = try jsonObject(.reviewResult(jobId: "j1", result: r))
        XCTAssertEqual(obj["inline_count"] as? String, "?")
        XCTAssertEqual(obj["verdict"] as? String, "")
        XCTAssertEqual(obj["result_line"] as? String, "")
    }

    func testReconnectedWithJob() throws {
        let obj = try jsonObject(.reconnected(wasBusy: true, repo: "a/b", prNum: 42))
        XCTAssertEqual(obj["type"] as? String, "reconnected")
        XCTAssertEqual(obj["was_busy"] as? Bool, true)
        XCTAssertEqual(obj["repo"] as? String, "a/b")
        XCTAssertEqual(obj["pr_num"] as? Int, 42)
    }

    func testReconnectedIdle() throws {
        // Node 版无任务时 repo/pr_num 都是空串
        let obj = try jsonObject(.reconnected(wasBusy: false, repo: "", prNum: nil))
        XCTAssertEqual(obj["pr_num"] as? String, "")
        XCTAssertEqual(obj["repo"] as? String, "")
    }

    // ---------- 入站解析 ----------

    func testParseRegisterAck() {
        let text = """
        {"type":"register_ack","open_id":"ou_x","name":"Allen","recommended_version":"1.3.0",
         "upgrade":{"recommended":"1.3.0","min":"1.0.0","below_min":false,"message":"git pull"},
         "managed_repos":[{"repo":"a/b"},{"repo":"c/d","provider":"azdo","prompt":"custom"}]}
        """
        guard case let .registerAck(ack)? = InboundMessage.parse(text) else {
            return XCTFail("应解析为 registerAck")
        }
        XCTAssertEqual(ack.open_id, "ou_x")
        XCTAssertEqual(ack.name, "Allen")
        XCTAssertEqual(ack.upgrade?.recommended, "1.3.0")
        XCTAssertEqual(ack.managed_repos?.count, 2)
        XCTAssertEqual(ack.managed_repos?[1].provider, "azdo")
    }

    func testParseRegisterAckMinimal() {
        // 服务端字段可增减，全部 Optional
        guard case .registerAck? = InboundMessage.parse(#"{"type":"register_ack"}"#) else {
            return XCTFail("最小 register_ack 也应能解析")
        }
    }

    func testParseReviewJob() {
        let text = """
        {"type":"review_job","job_id":"j-1","pr_num":7,"repo":"a/b","branch":"feat/x",
         "provider":"azdo","pr_url":"https://dev.azure.com/x","ci_overall":"failing",
         "ci_failed_names":"unit-test","review_model":"claude-sonnet-5","prompt_template":"T"}
        """
        guard case let .reviewJob(job)? = InboundMessage.parse(text) else {
            return XCTFail("应解析为 reviewJob")
        }
        XCTAssertEqual(job.job_id, "j-1")
        XCTAssertEqual(job.pr_num, 7)
        XCTAssertEqual(job.provider, "azdo")
        XCTAssertEqual(job.ci_failed_names, "unit-test")
    }

    func testParseUnknownAndGarbage() {
        XCTAssertNil(InboundMessage.parse(#"{"type":"future_thing","x":1}"#), "未知类型静默丢弃")
        XCTAssertNil(InboundMessage.parse("not json"), "非法 JSON 静默丢弃")
        XCTAssertNil(InboundMessage.parse(#"{"no_type":true}"#))
    }

    func testParsePrClosedAndReject() {
        guard case let .prClosed(pc)? = InboundMessage.parse(#"{"type":"pr_closed","repo":"a/b","pr_num":3}"#) else {
            return XCTFail()
        }
        XCTAssertEqual(pc.pr_num, 3)
        guard case let .registerReject(rej)? = InboundMessage.parse(#"{"type":"register_reject","reason":"bad_token"}"#) else {
            return XCTFail()
        }
        XCTAssertEqual(rej.reason, "bad_token")
    }

    // ---------- ___RESULT___ 解析 ----------

    func testParseResultLineTakesLast() {
        let log = """
        noise
        ___RESULT___ verdict=COMMENT general_comment_url=https://a inline_count=1
        more noise
        ___RESULT___ verdict=APPROVE general_comment_url=https://b inline_count=5
        trailing
        """
        let p = parseResultLine(log)
        XCTAssertEqual(p.verdict, "APPROVE", "多次出现取最后一次匹配")
        XCTAssertEqual(p.generalCommentUrl, "https://b")
        XCTAssertEqual(p.inlineCount, "5")
        XCTAssertTrue(p.resultLine.hasPrefix("___RESULT___ verdict=APPROVE"))
    }

    func testParseResultLineNoMatch() {
        let p = parseResultLine("claude crashed")
        XCTAssertEqual(p.verdict, "")
        XCTAssertEqual(p.inlineCount, "?")
        XCTAssertEqual(p.resultLine, "")
    }

    func testParseResultLineNone() {
        let p = parseResultLine("___RESULT___ verdict=REQUEST_CHANGES general_comment_url=NONE inline_count=0")
        XCTAssertEqual(p.verdict, "REQUEST_CHANGES")
        XCTAssertEqual(p.generalCommentUrl, "NONE")
        XCTAssertEqual(p.inlineCount, "0")
    }

    // ---------- prompt 渲染 ----------

    private func makeJob(provider: String? = nil, promptTemplate: String? = nil) -> ReviewJob {
        ReviewJob(job_id: "j", pr_num: 12, repo: "o/r", branch: "main", provider: provider,
                  pr_url: "https://pr", ci_overall: "passing", ci_failed_names: nil,
                  review_model: nil, prompt_template: promptTemplate)
    }

    func testRenderPromptPriority() {
        let job = makeJob(promptTemplate: "server {{PR_NUM}}")
        // 本机 repo prompt 最优先
        XCTAssertEqual(renderPrompt(job: job, worktreePath: "/wt", ciStatus: "ok", repoTemplate: "local {{PR_NUM}}"),
                       "local 12")
        // 其次服务端下发
        XCTAssertEqual(renderPrompt(job: job, worktreePath: "/wt", ciStatus: "ok", repoTemplate: "  "),
                       "server 12", "空白 repoTemplate 不算数")
        // 最后内置默认（GitHub）
        let builtin = renderPrompt(job: makeJob(), worktreePath: "/wt", ciStatus: "ok", repoTemplate: nil)
        XCTAssertTrue(builtin.contains("Run /pr-review 12 fully autonomously"))
        XCTAssertTrue(builtin.contains("/wt"))
        XCTAssertTrue(builtin.contains("Current CI status: ok."))
    }

    func testRenderPromptAzdoBuiltin() {
        let p = renderPrompt(job: makeJob(provider: "azdo"), worktreePath: "/wt", ciStatus: "ok", repoTemplate: nil)
        XCTAssertTrue(p.contains("Run /pr-review-azdo 12"))
        XCTAssertTrue(p.contains("https://pr"))
        XCTAssertTrue(p.contains("repo o/r"))
    }

    func testCiStatusString() {
        XCTAssertEqual(ciStatusString(overall: "failing", failedNames: "unit, lint"),
                       "failing; failed checks: unit, lint")
        XCTAssertEqual(ciStatusString(overall: "passing", failedNames: nil), "passing")
        XCTAssertEqual(ciStatusString(overall: nil, failedNames: nil), "")
    }
}

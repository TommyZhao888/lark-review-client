import XCTest
@testable import LarkReviewClient

/// v1.7 新特性: 自动参与/自动 clone 路径解析、结果行契约附加、用量上报、结果回执。
final class V17FeatureTests: XCTestCase {

    // ---------- 项目解析 ----------

    func testRepoDirName() {
        XCTAssertEqual(Config.repoDirName("owner/repo"), "owner-repo")
        XCTAssertEqual(Config.repoDirName("liontrip-cms/cms-apostrophe"), "liontrip-cms-cms-apostrophe")
    }

    func testResolveRepoAutoAndManual() {
        var cfg = Config()
        cfg.repoBaseDir = "/base"
        // 未配置 = 自动模式
        let auto = cfg.resolveRepo("o/r")
        XCTAssertTrue(auto.auto)
        XCTAssertEqual(auto.mainRepo, "/base/o-r")
        XCTAssertEqual(auto.worktreeBase, "/base/o-r-worktrees")
        // 手动路径优先(旧行为兼容); worktreeBase 缺省 = mainRepo + "-worktrees"
        cfg.repos["o/r"] = RepoConfig(mainRepo: "/me/r", worktreeBase: "")
        let manual = cfg.resolveRepo("o/r")
        XCTAssertFalse(manual.auto)
        XCTAssertEqual(manual.mainRepo, "/me/r")
        XCTAssertEqual(manual.worktreeBase, "/me/r-worktrees")
        // prompt-only 条目: 路径仍自动
        cfg.repos["o/r"] = RepoConfig(mainRepo: "", worktreeBase: "", prompt: "p")
        XCTAssertTrue(cfg.resolveRepo("o/r").auto)
    }

    func testEffectiveAndParticipates() {
        var cfg = Config()
        cfg.repos["local/one"] = RepoConfig(mainRepo: "/x", worktreeBase: "")
        let managed = [ManagedRepo(repo: "srv/a"), ManagedRepo(repo: "local/one")]
        XCTAssertEqual(cfg.effectiveRepoNames(managed: managed), ["local/one", "srv/a"])
        XCTAssertTrue(cfg.participates("srv/a", managed: managed))
        cfg.autoRepos = false
        XCTAssertEqual(cfg.effectiveRepoNames(managed: managed), ["local/one"])
        XCTAssertFalse(cfg.participates("srv/a", managed: managed))
        XCTAssertTrue(cfg.participates("local/one", managed: managed))
    }

    // ---------- clone URL 推导 ----------

    func testDeriveCloneUrl() {
        XCTAssertEqual(RepoCloner.deriveCloneUrl(repo: "o/r", provider: nil, prUrl: nil),
                       "https://github.com/o/r.git")
        let ado = RepoCloner.deriveCloneUrl(
            repo: "liontrip-cms/cms-apostrophe", provider: "azdo",
            prUrl: "https://ado.example.com/Col/proj/_git/cms-apostrophe/pullrequest/1425")
        XCTAssertEqual(ado, "https://ado.example.com/Col/proj/_git/cms-apostrophe")
        XCTAssertNil(RepoCloner.deriveCloneUrl(repo: "a/b", provider: "azdo", prUrl: ""))
    }

    // ---------- 提示词: 契约附加(不改原意) + 全局/单项目优先级 ----------

    private func job(provider: String? = nil, serverPrompt: String? = nil) -> ReviewJob {
        ReviewJob(job_id: "j1", pr_num: 7, repo: "o/r", branch: "b", provider: provider,
                  pr_url: "https://x/pr/7", ci_overall: "SUCCESS", ci_failed_names: nil,
                  review_model: nil, prompt_template: serverPrompt)
    }

    func testPromptContractAppendedForFreeFormPrompt() {
        let p = renderPrompt(job: job(), worktreePath: "/wt", ciStatus: "OK",
                             repoTemplate: nil, globalTemplate: "用一句中文评价 {{PR_NUM}}")
        XCTAssertTrue(p.hasPrefix("用一句中文评价 7"))          // 用户提示词本体在最前、原样保留
        XCTAssertTrue(p.contains("___RESULT___"))               // 契约被附加
        XCTAssertTrue(p.contains("does NOT change, override"))  // 附加块声明不改原意
    }

    func testPromptContractNotDuplicated() {
        let p = renderPrompt(job: job(), worktreePath: "/wt", ciStatus: "OK",
                             repoTemplate: nil, globalTemplate: "")
        // 内置模板自带契约, 不应重复附加
        XCTAssertEqual(p.components(separatedBy: "___RESULT___").count - 1, 1)
    }

    func testPromptPriorityRepoOverGlobalOverServer() {
        let j = job(serverPrompt: "SERVER ___RESULT___")
        let repoWins = renderPrompt(job: j, worktreePath: "/wt", ciStatus: "OK",
                                    repoTemplate: "REPO ___RESULT___", globalTemplate: "GLOBAL ___RESULT___")
        XCTAssertTrue(repoWins.hasPrefix("REPO"))
        let globalWins = renderPrompt(job: j, worktreePath: "/wt", ciStatus: "OK",
                                      repoTemplate: nil, globalTemplate: "GLOBAL ___RESULT___")
        XCTAssertTrue(globalWins.hasPrefix("GLOBAL"))
        let serverWins = renderPrompt(job: j, worktreePath: "/wt", ciStatus: "OK",
                                      repoTemplate: nil, globalTemplate: "")
        XCTAssertTrue(serverWins.hasPrefix("SERVER"))
    }

    // ---------- claude json 信封解析 ----------

    func testParseClaudeEnvelope() {
        let stdout = #"{"result":"hi\n___RESULT___ verdict=COMMENT general_comment_url=NONE inline_count=0","usage":{"input_tokens":2,"output_tokens":34,"cache_read_input_tokens":10,"cache_creation_input_tokens":5},"total_cost_usd":0.014,"duration_ms":5000,"num_turns":1}"#
        let parsed = UsageStore.parseClaudeEnvelope(stdout)
        XCTAssertNotNil(parsed)
        XCTAssertTrue(parsed!.text.hasPrefix("hi"))
        XCTAssertEqual(parsed!.usage.inputTokens, 2)
        XCTAssertEqual(parsed!.usage.outputTokens, 34)
        XCTAssertEqual(parsed!.usage.totalCostUsd, 0.014)
        XCTAssertEqual(parsed!.usage.numTurns, 1)
        // 老版 claude 纯文本输出 → nil(回退老路径)
        XCTAssertNil(UsageStore.parseClaudeEnvelope("plain text output"))
    }

    // ---------- 协议: usage 出站 + review_result_ack 入站 ----------

    func testReviewResultCarriesUsage() throws {
        var r = ReviewResult(exitCode: 0, logTail: "t", verdict: "COMMENT")
        r.usage = ReviewUsage(inputTokens: 2, outputTokens: 34, totalCostUsd: 0.014)
        let text = try OutboundMessage.reviewResult(jobId: "j1", result: r).encodedString()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let usage = try XCTUnwrap(obj["usage"] as? [String: Any])
        XCTAssertEqual(usage["input_tokens"] as? Int, 2)
        XCTAssertEqual(usage["output_tokens"] as? Int, 34)
        XCTAssertEqual(usage["total_cost_usd"] as? Double, 0.014)
        // 无 usage 时不带字段(旧 hub 兼容)
        let noUsage = try OutboundMessage.reviewResult(jobId: "j1", result: ReviewResult(exitCode: 1, logTail: "x")).encodedString()
        let obj2 = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(noUsage.utf8)) as? [String: Any])
        XCTAssertNil(obj2["usage"])
    }

    func testReviewResultAckParse() {
        let msg = InboundMessage.parse(#"{"type":"review_result_ack","job_id":"job_x_1"}"#)
        guard case let .reviewResultAck(ack)? = msg else {
            return XCTFail("应解析为 reviewResultAck")
        }
        XCTAssertEqual(ack.job_id, "job_x_1")
    }
}

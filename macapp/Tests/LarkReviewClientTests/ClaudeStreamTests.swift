import XCTest
@testable import LarkReviewClient

/// stream-json 单行事件解析: 工具调用/文字 → 人话日志; result 事件识别 + 复用 parseClaudeEnvelope。
final class ClaudeStreamTests: XCTestCase {

    func testToolUseLine() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr diff 123"}}]}}"#
        let (logs, isResult) = ClaudeStream.parseLine(line)
        XCTAssertFalse(isResult)
        XCTAssertEqual(logs, ["🔧 Bash gh pr diff 123"])
    }

    func testReadToolShowsFilePath() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/repo/app/x.ts"}}]}}"#
        let (logs, _) = ClaudeStream.parseLine(line)
        XCTAssertEqual(logs, ["🔧 Read /repo/app/x.ts"])
    }

    func testAssistantTextSnippet() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"正在核对 CI 失败项"}]}}"#
        let (logs, isResult) = ClaudeStream.parseLine(line)
        XCTAssertFalse(isResult)
        XCTAssertEqual(logs, ["💬 正在核对 CI 失败项"])
    }

    func testResultEventFlaggedAndParsable() {
        let line = #"{"type":"result","subtype":"success","result":"done\n___RESULT___ verdict=COMMENT general_comment_url=NONE inline_count=0","usage":{"input_tokens":2,"output_tokens":34},"total_cost_usd":0.02,"num_turns":3}"#
        let (logs, isResult) = ClaudeStream.parseLine(line)
        XCTAssertTrue(isResult)
        XCTAssertTrue(logs.isEmpty)
        // result 事件行可直接喂给现有信封解析器(字段与 --output-format json 一致)
        let env = UsageStore.parseClaudeEnvelope(line)
        XCTAssertNotNil(env)
        XCTAssertTrue(env!.text.hasPrefix("done"))
        XCTAssertEqual(env!.usage.inputTokens, 2)
        XCTAssertEqual(env!.usage.totalCostUsd, 0.02)
    }

    func testNonJsonAndOtherEventsIgnored() {
        XCTAssertEqual(ClaudeStream.parseLine("not json").logs, [])
        XCTAssertEqual(ClaudeStream.parseLine(#"{"type":"system","subtype":"init"}"#).logs, [])
        XCTAssertFalse(ClaudeStream.parseLine(#"{"type":"system"}"#).isResult)
    }

    func testScanResultLineFindsLast() {
        let stdout = [
            #"{"type":"system","subtype":"init"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#,
            #"{"type":"result","subtype":"success","result":"final","usage":{},"total_cost_usd":0.01}"#,
        ].joined(separator: "\n")
        let found = ClaudeStream.scanResultLine(stdout)
        XCTAssertNotNil(found)
        XCTAssertEqual(UsageStore.parseClaudeEnvelope(found!)?.text, "final")
    }
}

import XCTest
@testable import LarkReviewClient

/// 线程安全收集流式回调的行(回调在后台线程触发)。
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func add(_ s: String) { lock.lock(); _lines.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
}

/// ProcessRunner 的超时 / 手动终止 / 正常路径。用 /bin/sleep、/bin/echo 绝对路径,
/// 避免走 loginShellPATH(zsh -lic)的首次 5s 解析。
final class ProcessRunnerTests: XCTestCase {

    func testRunNoTimeoutSucceeds() async {
        let r = await ProcessRunner.run("/bin/echo", ["hi"])
        XCTAssertEqual(r.code, 0)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hi")
    }

    func testFastProcessUnderTimeoutNotKilled() async {
        let r = await ProcessRunner.run("/bin/echo", ["ok"], timeoutMs: 5000)
        XCTAssertEqual(r.code, 0, "远未到超时, 不应被终止")
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
    }

    func testTimeoutReturns124Quickly() async {
        let start = Date()
        let r = await ProcessRunner.run("/bin/sleep", ["10"], timeoutMs: 400)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(r.code, 124, "超时应返回 124")
        XCTAssertTrue(r.stderr.contains("超时"), "stderr 应注明超时: \(r.stderr)")
        XCTAssertLessThan(elapsed, 5, "应在超时后很快返回, 而不是等满 10s")
    }

    func testHandleTerminateEndsProcess() async {
        let handle = ProcHandle()
        let start = Date()
        async let result = ProcessRunner.run("/bin/sleep", ["10"], handle: handle)
        try? await Task.sleep(for: .milliseconds(300))   // 等进程起来 + attach
        handle.terminate()
        let r = await result
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotEqual(r.code, 0, "被终止的进程退出码不应为 0")
        XCTAssertLessThan(elapsed, 5, "终止后应很快返回")
    }

    func testOnOutputLineFiresPerLine() async {
        let sink = LineCollector()
        let r = await ProcessRunner.run("/bin/sh", ["-c", "printf 'a\\nb\\nc\\n'"],
                                        onOutputLine: { sink.add($0) })
        XCTAssertEqual(r.code, 0)
        XCTAssertEqual(sink.lines, ["a", "b", "c"])
        XCTAssertEqual(r.stdout, "a\nb\nc\n")   // 完整 stdout 仍照常累积返回
    }

    func testCommandNotFoundReturns127() async {
        let r = await ProcessRunner.run("/nonexistent/definitely-not-a-cmd", [])
        XCTAssertEqual(r.code, 127)
    }
}

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

    func testReturnsPromptlyWhenChildLeaksPipe() async {
        // sh 派生一个后台 sleep(继承 stdout), 打印 done 后自己退出; 后台 sleep 继续占着管道写端 8s。
        // 复现"claude 主进程退出但 MCP 等子孙进程占着管道 → 任务永不收尾"。
        // 修复前: readDataToEndOfFile 等到 sleep 结束(~8s)才返回; 修复后: 主进程退出后 3s 宽限强关管道即返回。
        let start = Date()
        let r = await ProcessRunner.run("/bin/sh", ["-c", "sleep 8 & echo done"])
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.stdout.contains("done"), "主进程退出前的输出必须完整拿到: \(r.stdout)")
        XCTAssertLessThan(elapsed, 6, "主进程退出后应在排空宽限期内返回, 不等残留子进程(实测 \(elapsed)s)")
    }

    func testTerminateReturnsPromptlyEvenIfChildLeaksPipe() async {
        // 复现"点终止后卡在'终止中'": 主进程被 terminate 杀掉, 但它派生的后台进程(模拟 MCP server)
        // 继承并占着 stdout。修复前 run 会一直等 EOF → 不返回 → cancelling 永不复位; 修复后主进程一死,
        // 排空宽限到点强关管道, run 及时返回, 任务收尾, 按钮复位。
        let handle = ProcHandle()
        let start = Date()
        async let result = ProcessRunner.run("/bin/sh", ["-c", "sleep 30 & echo running; sleep 30"], handle: handle)
        try? await Task.sleep(for: .milliseconds(500))
        handle.terminate()
        let r = await result
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotEqual(r.code, 0, "被终止的进程退出码不应为 0")
        XCTAssertLessThan(elapsed, 12, "终止后应在(信号 + 排空宽限)内返回, 不卡死: \(elapsed)s")
    }

    func testCommandNotFoundReturns127() async {
        let r = await ProcessRunner.run("/nonexistent/definitely-not-a-cmd", [])
        XCTAssertEqual(r.code, 127)
    }
}

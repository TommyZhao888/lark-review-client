import Foundation

struct ProcessResult {
    var code: Int32
    var stdout: String
    var stderr: String
}

/// 子进程封装（对齐 Node 的 run()）：
/// - 等退出前并发排空 stdout/stderr，防管道写满死锁
/// - stdin 写完必须 close（claude 等 EOF）
/// - 找不到可执行文件时返回 code=127（对齐 Node 的 spawn error 分支）
/// - 可选超时 timeoutMs>0：先 SIGTERM 宽限 8s 再 SIGKILL，返回 code=124（对齐 Node run 的 timeoutMs）
/// - 可选 handle：把在跑的进程暴露给调用方，用于手动终止（cancelCurrent）
enum ProcessRunner {

    /// GUI app 的 PATH 极精简（/usr/bin:/bin:...），claude/git/gh 常装在
    /// /opt/homebrew/bin、~/.local/bin。启动时用登录 shell 展开一次完整 PATH 并缓存。
    nonisolated(unsafe) private static var cachedPath: String?

    static func loginShellPATH() -> String {
        if let p = cachedPath { return p }
        let fallback = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            + ":/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "printf %s \"$PATH\""]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { cachedPath = fallback; return fallback }
        // 登录 shell 可能因用户 rc 卡住，5s 兜底
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
        if done.wait(timeout: .now() + 5) == .timedOut {
            p.terminate()
            cachedPath = fallback
            return fallback
        }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let result = out.isEmpty ? fallback : out
        cachedPath = result
        return result
    }

    /// 在完整 PATH 里解析命令的绝对路径；已是绝对路径则原样返回。找不到返回 nil。
    static func resolveExecutable(_ cmd: String) -> String? {
        if cmd.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: cmd) ? cmd : nil
        }
        for dir in loginShellPATH().split(separator: ":") {
            let candidate = "\(dir)/\(cmd)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func run(
        _ cmd: String,
        _ args: [String],
        cwd: String? = nil,
        stdin: String? = nil,
        extraEnv: [String: String] = [:],
        timeoutMs: Int = 0,
        handle: ProcHandle? = nil,
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async -> ProcessResult {
        guard let exe = resolveExecutable(cmd) else {
            return ProcessResult(code: 127, stdout: "", stderr: "command not found: \(cmd)")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginShellPATH()
        env["GIT_LFS_SKIP_SMUDGE"] = "1"
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inPipe { p.standardInput = inPipe } else { p.standardInput = FileHandle.nullDevice }

        do { try p.run() } catch {
            return ProcessResult(code: 127, stdout: "", stderr: error.localizedDescription)
        }
        ChildProcessRegistry.shared.register(p)
        handle?.attach(p)
        defer { ChildProcessRegistry.shared.unregister(p); handle?.detach() }

        // 可选超时：到点先 SIGTERM，宽限 8s 仍在跑再 SIGKILL；用 timedOut 标记以便返回 124。
        let timedOut = AtomicFlag()
        var timeoutWork: DispatchWorkItem?
        if timeoutMs > 0 {
            let work = DispatchWorkItem {
                timedOut.set()
                p.terminate()
                let pid = p.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                    if p.isRunning { kill(pid, SIGKILL) }
                }
            }
            timeoutWork = work
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: work)
        }

        // stdin 写入放后台（大 prompt 可能阻塞在管道容量上），写完必须 close 给 EOF。
        if let inPipe, let stdin {
            DispatchQueue.global().async {
                let fh = inPipe.fileHandleForWriting
                if let data = stdin.data(using: .utf8) { try? fh.write(contentsOf: data) }
                try? fh.close()
            }
        }

        // 并发排空两条输出管道，然后等退出。stdout 若给了 onOutputLine 则边读边按行回调(流式)。
        async let outData = drainOut(outPipe, onLine: onOutputLine)
        async let errData = drainOut(errPipe, onLine: nil)
        // 等退出: 双通道竞速, 只收尾一次。
        // 通道1: waitUntilExit(正常路径, 拿精确退出码)。
        // 通道2: kill(pid,0) 轮询兜底 —— NSTask 的终止通知可能丢失(mach 通知竞态/子进程被别处 reap),
        //   此时进程早已消失(无僵尸)而 waitUntilExit 永久悬挂在 mach_msg: 整单 review 卡死不收尾、
        //   busy 不复位队列全堵、点「终止」也无效(进程已死, terminate 是 no-op)。实测 2026-07-23
        //   PR #636: 结果已发 GitHub、claude 已退出, waitUntilExit 挂 20+ 分钟(sample 栈证实)。
        //   进程消失后给通道1一个 2s 宽限拿真实退出码; 仍没醒就以 0 收尾并注记(verdict 判定以
        //   stdout 结果行为准, 不受影响; 真实失败时 stdout 无结果行, 服务端有反查兜底)。
        //   注意兜底路径绝不能读 terminationStatus —— NSTask 仍自认 running, 读了直接抛 ObjC 异常。
        //   pid 复用会让轮询失明, 但需与通道1悬挂同时发生, 双小概率, 接受。
        let waitBypassed = AtomicFlag()
        let exitPid = p.processIdentifier
        let code: Int32 = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let resumed = AtomicFlag()
            DispatchQueue.global().async {
                p.waitUntilExit()
                if !resumed.testAndSet() { cont.resume(returning: p.terminationStatus) }
            }
            DispatchQueue.global().async {
                while kill(exitPid, 0) == 0 {
                    if resumed.isSet { return }              // 通道1已收尾, 轮询线程退出
                    usleep(500_000)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if !resumed.testAndSet() {
                        waitBypassed.set()
                        cont.resume(returning: 0)
                    }
                }
            }
        }
        timeoutWork?.cancel()
        // 主进程已退出: 给管道排空一个宽限期(3s), 到点强关读端解除阻塞。claude 可能派生了不随它退出的
        // 子孙进程(如配置里的 MCP server), 它们继承并占着 stdout/stderr 管道写端 → EOF 永不到达 →
        // 排空永久卡住 → 整个 review 任务卡死不收尾(超时 SIGKILL 了 claude 也一样卡, 残留子孙仍占管道)。
        // 主进程的输出在它退出前已写入管道, 强关只丢弃残留子孙的无关输出。
        let graceClose = DispatchWorkItem {
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: graceClose)
        let stdout = String(data: await outData, encoding: .utf8) ?? ""
        let stderr = String(data: await errData, encoding: .utf8) ?? ""
        graceClose.cancel()
        if timedOut.isSet {
            let note = "[client] 超时(\(timeoutMs / 1000)s)已终止子进程"
            return ProcessResult(code: 124, stdout: stdout, stderr: stderr.isEmpty ? note : stderr + "\n" + note)
        }
        if waitBypassed.isSet {
            let note = "[client] waitUntilExit 未醒(终止通知丢失), 已按进程消失兜底收尾(退出码不可得, 按 0)"
            return ProcessResult(code: code, stdout: stdout, stderr: stderr.isEmpty ? note : stderr + "\n" + note)
        }
        return ProcessResult(code: code, stdout: stdout, stderr: stderr)
    }

    /// 排空管道: 边读边(可选)按 \n 回调 onLine, 累积完整数据返回。
    /// 用可抛的 read(upToCount:) 而非 readDataToEndOfFile —— 这样外部在排空宽限到点后 close 读端时,
    /// 阻塞中的读会抛错中断(而不是永久卡死或抛不可捕获的 ObjC 异常)。
    private static func drainOut(_ pipe: Pipe, onLine: (@Sendable (String) -> Void)?) async -> Data {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let fh = pipe.fileHandleForReading
                var acc = Data()
                var lineBuf = Data()
                while true {
                    let chunk: Data?
                    do { chunk = try fh.read(upToCount: 65536) }
                    catch { break }                                  // 读端被关 → 中断
                    guard let chunk, !chunk.isEmpty else { break }   // nil = EOF
                    acc.append(chunk)
                    if let onLine {
                        lineBuf.append(chunk)
                        while let nl = lineBuf.firstIndex(of: 0x0A) {
                            let lineData = lineBuf.subdata(in: lineBuf.startIndex..<nl)
                            lineBuf.removeSubrange(lineBuf.startIndex...nl)
                            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty { onLine(s) }
                        }
                    }
                }
                if let onLine, let s = String(data: lineBuf, encoding: .utf8),
                   !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onLine(s) }
                cont.resume(returning: acc)
            }
        }
    }
}

/// 线程安全布尔标记（超时是否已触发；跨 DispatchQueue 读写）。
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    /// 置位并返回置位前的旧值(test-and-set), 用于"多通道竞速只收尾一次"。
    func testAndSet() -> Bool { lock.lock(); defer { lock.unlock() }; let old = flag; flag = true; return old }
}

/// 单个在跑子进程的句柄：调用方持有，用于手动终止（先 SIGTERM，宽限 8s 再 SIGKILL）。
/// 与 ProcessRunner.run(handle:) 配合——run 内部 attach/detach，外部 terminate。
final class ProcHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var proc: Process?

    func attach(_ p: Process) { lock.lock(); proc = p; lock.unlock() }
    func detach() { lock.lock(); proc = nil; lock.unlock() }

    /// 请求终止当前进程；无进程在跑则忽略（幂等）。
    func terminate() {
        lock.lock(); let p = proc; lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// 跟踪在跑的子进程，app 退出时统一 terminate。
final class ChildProcessRegistry: @unchecked Sendable {
    static let shared = ChildProcessRegistry()
    private let lock = NSLock()
    private var procs: [Process] = []

    func register(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        procs.append(p)
    }

    func unregister(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        procs.removeAll { $0 === p }
    }

    func terminateAll() {
        lock.lock(); defer { lock.unlock() }
        for p in procs where p.isRunning { p.terminate() }
        procs.removeAll()
    }
}

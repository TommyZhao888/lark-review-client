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
/// - 无超时：claude 一直跑到自己退出
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
        extraEnv: [String: String] = [:]
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
        defer { ChildProcessRegistry.shared.unregister(p) }

        // stdin 写入放后台（大 prompt 可能阻塞在管道容量上），写完必须 close 给 EOF。
        if let inPipe, let stdin {
            DispatchQueue.global().async {
                let fh = inPipe.fileHandleForWriting
                if let data = stdin.data(using: .utf8) { try? fh.write(contentsOf: data) }
                try? fh.close()
            }
        }

        // 并发排空两条输出管道，然后等退出。
        async let outData = drain(outPipe)
        async let errData = drain(errPipe)
        let code: Int32 = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus)
            }
        }
        let stdout = String(data: await outData, encoding: .utf8) ?? ""
        let stderr = String(data: await errData, encoding: .utf8) ?? ""
        return ProcessResult(code: code, stdout: stdout, stderr: stderr)
    }

    private static func drain(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: data)
            }
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

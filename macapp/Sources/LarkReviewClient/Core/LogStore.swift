import Foundation

/// 运行日志 + review 日志（路径与 Node 版完全一致，可来回切换）。
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    let logPath: String
    let reviewLogDir: String
    private let lock = NSLock()
    private let isoFormatter: ISO8601DateFormatter

    /// UI 层日志回调（AppRuntime 接到 AppState.recentLogLines）。
    var onLine: (@Sendable (String) -> Void)?

    private init() {
        let env = ProcessInfo.processInfo.environment
        logPath = env["LARK_REVIEW_CLIENT_LOG"] ?? NSHomeDirectory() + "/.lark-review-client.log"
        reviewLogDir = env["LARK_REVIEW_CLIENT_REVIEW_LOG_DIR"] ?? NSHomeDirectory() + "/.lark-review-client-logs"
        isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try? FileManager.default.createDirectory(atPath: reviewLogDir, withIntermediateDirectories: true)
    }

    private func isoNow() -> String { isoFormatter.string(from: Date()) }

    // ---------- 运行日志 ----------

    func log(_ message: String) {
        let line = "[client] \(isoNow()) \(message)"
        lock.lock()
        appendToFile(line + "\n")
        lock.unlock()
        onLine?(line)
    }

    private func appendToFile(_ text: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logPath) { fm.createFile(atPath: logPath, contents: nil) }
        guard let fh = FileHandle(forWritingAtPath: logPath) else { return }
        defer { try? fh.close() }
        // 简单轮转：超 5MB 截断保留后半（Node 版靠外部重定向没有轮转，这是顺手改进）。
        if let size = try? fh.seekToEnd(), size > 5 * 1024 * 1024,
           let all = fm.contents(atPath: logPath) {
            let keep = all.suffix(2 * 1024 * 1024)
            try? keep.write(to: URL(fileURLWithPath: logPath))
            guard let fh2 = FileHandle(forWritingAtPath: logPath) else { return }
            defer { try? fh2.close() }
            _ = try? fh2.seekToEnd()
            try? fh2.write(contentsOf: Data(text.utf8))
            return
        }
        try? fh.write(contentsOf: Data(text.utf8))
    }

    /// 读日志尾部（最多末 maxBytes 字节 / maxLines 行），对齐 Node tailLog。
    func tailLog(maxBytes: Int = 65536, maxLines: Int = 500) -> String {
        guard let fh = FileHandle(forReadingAtPath: logPath),
              let size = try? fh.seekToEnd() else {
            return "(暂无日志文件: \(logPath))"
        }
        defer { try? fh.close() }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return "" }
        var lines = text.components(separatedBy: "\n")
        if start > 0, !lines.isEmpty { lines.removeFirst() }  // 丢弃可能被截断的首行
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    // ---------- review 日志 ----------

    /// 把一次 review 的完整输出写入本机日志文件，返回路径（格式对齐 Node writeReviewLog）。
    func writeReviewLog(job: ReviewJob, model: String, exitCode: Int32, result: ReviewResult, logText: String) -> String? {
        let stamp = isoNow().replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
        let file = reviewLogDir + "/pr-\(job.pr_num)-\(stamp).log"
        let header =
            "# PR #\(job.pr_num)  repo=\(job.repo)  branch=\(job.branch ?? "")\n" +
            "# job=\(job.job_id)  model=\(model)  time=\(isoNow())\n" +
            "# exit=\(exitCode)  verdict=\(result.verdict.isEmpty ? "-" : result.verdict)  inline=\(result.inlineCount)  general_comment=\(result.generalCommentUrl.isEmpty ? "-" : result.generalCommentUrl)\n" +
            String(repeating: "#", count: 64) + "\n\n"
        do {
            try (header + logText).write(toFile: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            log("writeReviewLog: \(error.localizedDescription)")
            return nil
        }
    }

    struct ReviewLogEntry: Identifiable {
        var file: String
        var mtime: Date
        var id: String { file }
    }

    /// 最新 50 条 review 日志（按 mtime 倒序）。
    func listReviewLogs() -> [ReviewLogEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: reviewLogDir) else { return [] }
        return names
            .filter { $0.hasPrefix("pr-") && $0.hasSuffix(".log") }
            .compactMap { name -> ReviewLogEntry? in
                guard let attrs = try? fm.attributesOfItem(atPath: reviewLogDir + "/" + name),
                      let mtime = attrs[.modificationDate] as? Date else { return nil }
                return ReviewLogEntry(file: name, mtime: mtime)
            }
            .sorted { $0.mtime > $1.mtime }
            .prefix(50)
            .map { $0 }
    }

    /// 单次 review 日志内容（末 200000 字符）。
    func readReviewLog(file: String) -> String {
        guard file.hasPrefix("pr-"), file.hasSuffix(".log"), !file.contains("/") else { return "bad file" }
        guard let text = try? String(contentsOfFile: reviewLogDir + "/" + file, encoding: .utf8) else {
            return "读取失败"
        }
        return String(text.suffix(200_000))
    }

    /// 清理超过 maxAgeDays 天的 review 日志，避免无限增长。
    func pruneReviewLogs(maxAgeDays: Int) {
        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86400)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: reviewLogDir) else { return }
        for name in names where name.hasPrefix("pr-") && name.hasSuffix(".log") {
            let p = reviewLogDir + "/" + name
            if let attrs = try? fm.attributesOfItem(atPath: p),
               let mtime = attrs[.modificationDate] as? Date, mtime < cutoff {
                try? fm.removeItem(atPath: p)
            }
        }
    }
}

import Foundation

/// Review token 用量（对齐 Node 版 parseClaudeEnvelope/recordUsage/usageStats）：
/// claude --print --output-format json 的信封含 usage/total_cost_usd；老版 claude 输出非 json
/// 时解析失败 → 按原始文本走老路径（照常 review，仅无统计）。逐条落 usage.jsonl（与 Node 同一文件）。
enum UsageStore {

    static var usageLogFile: String { LogStore.shared.reviewLogDir + "/usage.jsonl" }

    /// 解析 claude json 信封：成功 → (最终文本, 用量摘要)；非 json/形状不对 → nil。
    static func parseClaudeEnvelope(_ stdout: String) -> (text: String, usage: ReviewUsage)? {
        guard let data = stdout.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = obj["result"] as? String else { return nil }
        let u = (obj["usage"] as? [String: Any]) ?? [:]
        let usage = ReviewUsage(
            inputTokens: u["input_tokens"] as? Int,
            outputTokens: u["output_tokens"] as? Int,
            cacheReadInputTokens: u["cache_read_input_tokens"] as? Int,
            cacheCreationInputTokens: u["cache_creation_input_tokens"] as? Int,
            totalCostUsd: obj["total_cost_usd"] as? Double,
            durationMs: obj["duration_ms"] as? Int,
            numTurns: obj["num_turns"] as? Int
        )
        return (text, usage)
    }

    /// 逐条落账（与 Node recordUsage 字段一致）。
    static func record(job: ReviewJob, model: String, exitCode: Int32, verdict: String, usage: ReviewUsage?) {
        guard let usage else { return }
        var rec: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "repo": job.repo, "pr_num": String(job.pr_num), "job_id": job.job_id,
            "model": model, "exit_code": Int(exitCode), "verdict": verdict,
        ]
        for (k, v) in usage.jsonObject { rec[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: usageLogFile) { fm.createFile(atPath: usageLogFile, contents: nil) }
        if let fh = FileHandle(forWritingAtPath: usageLogFile) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    struct Totals {
        var reviews = 0
        var inputTokens = 0
        var outputTokens = 0
        var costUsd = 0.0
    }

    /// 汇总本机用量（今日/累计），设置窗口展示用。文件不大（每 review 一行），直接全读。
    static func stats() -> (today: Totals, total: Totals) {
        var today = Totals(), total = Totals()
        guard let content = try? String(contentsOfFile: usageLogFile, encoding: .utf8) else {
            return (today, total)
        }
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        let dayKey = dayFmt.string(from: Date())
        let iso = ISO8601DateFormatter()
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let rec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            func add(_ t: inout Totals) {
                t.reviews += 1
                t.inputTokens += rec["input_tokens"] as? Int ?? 0
                t.outputTokens += rec["output_tokens"] as? Int ?? 0
                t.costUsd += rec["total_cost_usd"] as? Double ?? 0
            }
            add(&total)
            if let ts = rec["ts"] as? String, let d = iso.date(from: ts),
               dayFmt.string(from: d) == dayKey { add(&today) }
        }
        return (today, total)
    }

    static func format(_ t: Totals) -> String {
        func f(_ n: Int) -> String {
            n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6)
                : n >= 1000 ? String(format: "%.1fk", Double(n) / 1e3) : String(n)
        }
        return "\(t.reviews) 次 (in \(f(t.inputTokens)) / out \(f(t.outputTokens)) / $\(String(format: "%.4f", t.costUsd)))"
    }
}

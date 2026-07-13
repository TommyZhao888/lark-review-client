import Foundation

/// 线程安全字符串盒(流式回调在后台线程写, 主线程读)。
final class StringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ s: String) { lock.lock(); value = s; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}

/// 解析 claude `--output-format stream-json --verbose` 的单行事件(NDJSON)。
/// 只取粗粒度: assistant 事件里的 tool_use / text 块 → 人话日志行; result 事件 → 标记为最终
/// (最终结论/用量仍由 UsageStore.parseClaudeEnvelope 从该 result 行取, 与 json 信封字段一致)。
enum ClaudeStream {

    /// 返回 (要打到运行日志的行, 该行是否是最终 result 事件)。非 JSON / 其它事件 → ([], false)。
    static func parseLine(_ line: String) -> (logs: [String], isResult: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return ([], false) }
        switch type {
        case "result":
            return ([], true)
        case "assistant":
            guard let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { return ([], false) }
            var logs: [String] = []
            for block in content {
                let bt = block["type"] as? String
                if bt == "tool_use", let name = block["name"] as? String {
                    let brief = briefToolInput(name: name, input: block["input"] as? [String: Any])
                    logs.append("🔧 " + name + (brief.isEmpty ? "" : " " + brief))
                } else if bt == "text",
                          let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty {
                    logs.append("💬 " + snippet(text))
                }
            }
            return (logs, false)
        default:
            return ([], false)
        }
    }

    /// stdout 全文里扫最后一条 result 事件(流式回调漏接时的兜底)。
    static func scanResultLine(_ stdout: String) -> String? {
        var found: String?
        for raw in stdout.split(separator: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.contains("\"type\":\"result\"") || s.contains("\"type\": \"result\"") { found = s }
        }
        return found
    }

    private static func snippet(_ s: String) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 120 ? String(oneLine.prefix(120)) + "…" : oneLine
    }

    private static func briefToolInput(name: String, input: [String: Any]?) -> String {
        guard let input else { return "" }
        func str(_ k: String) -> String? { input[k] as? String }
        switch name {
        case "Bash": return str("command").map(snippet) ?? ""
        case "Read", "Edit", "Write", "NotebookEdit": return str("file_path") ?? ""
        case "Grep", "Glob": return str("pattern") ?? ""
        default:
            if let first = input.values.first(where: { $0 is String }) as? String { return snippet(first) }
            return ""
        }
    }
}

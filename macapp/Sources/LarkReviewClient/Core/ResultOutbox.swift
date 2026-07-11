import Foundation

/// review 结果可靠上报（至少一次投递，对齐 Node 版 pending-results 队列）：
/// 结果先落磁盘（configPath + ".pending-results.json"，与 Node 同一文件）再发送；重连注册成功后
/// 补投；收到 hub 的 review_result_ack 才删除——跨断线、跨进程重启都不丢。hub 侧幂等（job 已
/// finish 的重复投递直接忽略并回 ack）。旧 hub 不回 ack → 条目按 24h 过期清理，防永久重发。
@MainActor
final class ResultOutbox {

    /// 发送原始 JSON 文本帧（AppRuntime 接到 WebSocketClient.sendRaw；未连接时静默丢弃，靠重发闭环）。
    var sendRaw: (String) -> Void = { _ in }
    /// 当前是否已注册（flush 的前置条件）。
    var isRegistered: () -> Bool = { false }

    private let maxAgeMs: Double = 24 * 3600 * 1000
    private var entries: [[String: Any]] = []   // [{ts: ms, job_id, payload: 原始 JSON 字符串}]

    private var file: String { ConfigStore.configPath + ".pending-results.json" }

    init() {
        if let data = FileManager.default.contents(atPath: file),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            entries = arr
        }
    }

    private func save() {
        guard let data = try? JSONSerialization.data(withJSONObject: entries) else { return }
        let tmp = file + ".tmp"
        try? data.write(to: URL(fileURLWithPath: tmp))
        _ = rename(tmp, file)
    }

    /// 结果入队并立即尝试投递。
    func queue(jobId: String, payloadJSON: String) {
        prune()
        entries.append(["ts": Date().timeIntervalSince1970 * 1000, "job_id": jobId, "payload": payloadJSON])
        save()
        flush()
    }

    /// 补投全部未确认条目（注册成功后调用；以 hub 的 ack 逐条清除）。
    func flush() {
        guard isRegistered() else { return }
        prune()
        for e in entries {
            if let payload = e["payload"] as? String { sendRaw(payload) }
        }
    }

    /// hub 确认收到某条结果 → 从队列删除。
    func ack(jobId: String) {
        let before = entries.count
        entries.removeAll { ($0["job_id"] as? String) == jobId }
        if entries.count != before { save() }
    }

    var count: Int { entries.count }

    private func prune() {
        let now = Date().timeIntervalSince1970 * 1000
        let before = entries.count
        entries.removeAll { now - (($0["ts"] as? Double) ?? 0) >= maxAgeMs }
        if entries.count != before {
            LogStore.shared.log("丢弃 \(before - entries.count) 条超过 24h 未确认的 review 结果(hub 侧早已按超时处理)")
            save()
        }
    }
}

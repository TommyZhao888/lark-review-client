import Foundation

/// Claude 额度(quota)状态上报载荷。与 Node 版 currentQuota() 对齐: {ok, reason, reset_at(ms)}。
struct QuotaStatus: Equatable {
    var ok: Bool = true
    var reason: String? = nil
    var resetAtMs: Int? = nil

    /// 出站 JSON 字典(reason/reset_at 为 nil 时省略键, 服务端按缺失=null 处理)。
    var jsonObject: [String: Any] {
        var o: [String: Any] = ["ok": ok]
        if let reason { o["reason"] = reason }
        if let resetAtMs { o["reset_at"] = resetAtMs }
        return o
    }
}

/// 额度感知(与 Node 版逐字段对齐):
///  - 反应式(可靠底座): review 命中限额时 claude 输出含 "You've hit your ... limit ... resets ...",
///    解析出重置时间, 在此之前上报"额度不足"。
///  - 前瞻式(可选): 读 statusline 写的 rate_limits 快照, 5小时/7天窗已用 >= 阈值就提前上报。
///    headless 不触发 statusline, 故快照仅在本机交互用 Claude 时刷新; 限额账号级, 同样反映 headless 消耗。
/// current() 汇总两者交给服务端; reset 到点自动恢复。
@MainActor
final class QuotaMonitor {
    static let shared = QuotaMonitor()
    private init() {}

    /// 命中限额后置; 到 resetAt 自动失效。
    private var reactiveBlock: (reason: String, resetAt: Date)?

    /// 每次 review 跑完喂入其输出, 命中限额则记下重置时间。
    func noteReviewOutput(_ logText: String) {
        if let hit = detectQuotaHit(logText) {
            reactiveBlock = (reason: hit.reason, resetAt: hit.resetAt)
            LogStore.shared.log("⚠️ 命中 Claude 限额(\(hit.reason)), 预计 \(hit.resetAt) 恢复; 本机将上报额度不足")
        }
    }

    /// 当前额度状态: 反应式优先(未过期), 否则看快照; 默认 ok(未知不拦, 靠反应式兜底)。
    func current(config: Config) -> QuotaStatus {
        if let b = reactiveBlock {
            if Date() >= b.resetAt { reactiveBlock = nil }
            else { return QuotaStatus(ok: false, reason: b.reason, resetAtMs: ms(b.resetAt)) }
        }
        if let s = readSnapshotQuota(config: config), s.ok == false { return s }
        return QuotaStatus(ok: true)
    }

    // MARK: - 反应式解析

    func detectQuotaHit(_ logText: String) -> (reason: String, resetAt: Date)? {
        if logText.isEmpty { return nil }
        if let g = firstMatch(#"hit your\s+(\S+)\s+limit\b[^\n]*?\bresets?\s+([^\n.·]+)"#, logText),
           let kindRaw = g[1] {
            let kind = kindRaw.lowercased()
            let resetText = (g[2] ?? "").trimmingCharacters(in: .whitespaces)
            return ("\(kind)_limit", parseResetToEpoch(resetText, kind: kind))
        }
        if firstMatch(#"credit balance is too low"#, logText) != nil {
            return ("credit_low", Date().addingTimeInterval(6 * 3600)) // 无重置时间, 保守冷却 6h
        }
        return nil
    }

    /// 把 claude 的重置文案(本机时区)解析成时间。解析不出按类型保守兜底冷却。
    ///   "3:45pm" -> 今天/明天该时刻的下一次; "Mon 12:00am" -> 下一个该星期几该时刻。
    func parseResetToEpoch(_ text: String, kind: String) -> Date {
        let longKind = firstMatch(#"week|7|seven|opus"#, kind) != nil
        let fallback = Date().addingTimeInterval((longKind ? 24 : 5) * 3600)
        if text.isEmpty { return fallback }
        guard let tm = firstMatch(#"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#, text), let h = tm[1].flatMap({ Int($0) }) else {
            return fallback
        }
        var hh = h
        let mm = tm[2].flatMap { Int($0) } ?? 0
        let ap = (tm[3] ?? "").lowercased()
        if ap == "pm" && hh < 12 { hh += 12 }
        if ap == "am" && hh == 12 { hh = 0 }
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = hh; comps.minute = mm; comps.second = 0
        guard var target = cal.date(from: comps) else { return fallback }
        // 星期几: Sun=1 ... Sat=7(Calendar 口径)。
        let wdNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        if let wg = firstMatch(#"\b(sun|mon|tue|wed|thu|fri|sat)"#, text.lowercased()),
           let want = wg[1].flatMap({ wdNames.firstIndex(of: $0) }).map({ $0 + 1 }) {
            let cur = cal.component(.weekday, from: target)
            var add = (want - cur + 7) % 7
            if add == 0 && target <= now { add = 7 }
            target = cal.date(byAdding: .day, value: add, to: target) ?? target
        } else if target <= now {
            target = cal.date(byAdding: .day, value: 1, to: target) ?? target
        }
        return target
    }

    // MARK: - 前瞻式快照

    /// 读 statusline 写的 rate_limits 快照。返回 ok:false/ok:true; 无快照/过期/未启用 -> nil。
    func readSnapshotQuota(config: Config) -> QuotaStatus? {
        let raw = config.quotaSnapshotPath.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return nil }
        let path = raw.hasPrefix("~") ? NSHomeDirectory() + String(raw.dropFirst()) : raw
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let updStr = obj["updated_at"] as? String, let upd = isoDate(updStr) else { return nil }
        if Date().timeIntervalSince(upd) * 1000 > Double(config.quotaSnapshotFreshnessMs) { return nil } // 过期不采信
        func pct(_ w: Any?) -> Int? {
            guard let d = w as? [String: Any] else { return nil }
            if let i = d["used_percentage"] as? Int { return i }
            if let f = d["used_percentage"] as? Double { return Int(f) }
            return nil
        }
        func resetMs(_ w: Any?) -> Int? {
            guard let v = (w as? [String: Any])?["resets_at"] else { return nil }
            if let f = v as? Double { return Int(f > 1e12 ? f : f * 1000) }
            if let i = v as? Int { return i > 1_000_000_000_000 ? i : i * 1000 }
            if let s = v as? String, let d = isoDate(s) { return Int(d.timeIntervalSince1970 * 1000) }
            return nil
        }
        if let f5 = pct(obj["five_hour"]), f5 >= config.quotaFiveHourThreshold {
            return QuotaStatus(ok: false, reason: "five_hour_\(f5)pct", resetAtMs: resetMs(obj["five_hour"]))
        }
        if let d7 = pct(obj["seven_day"]), d7 >= config.quotaSevenDayThreshold {
            return QuotaStatus(ok: false, reason: "seven_day_\(d7)pct", resetAtMs: resetMs(obj["seven_day"]))
        }
        return QuotaStatus(ok: true)
    }

    // MARK: - helpers

    private func ms(_ d: Date) -> Int { Int(d.timeIntervalSince1970 * 1000) }

    private func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// 返回第一处匹配的各捕获组(组 0 = 整体)。大小写不敏感。无匹配 -> nil。
    private func firstMatch(_ pattern: String, _ text: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var groups: [String?] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
        }
        return groups
    }
}

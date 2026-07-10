import Foundation

/// Claude 额度(quota)状态上报载荷。与 Node 版 currentQuota() 对齐: {ok, reason, reset_at(ms)}。
struct QuotaStatus: Equatable {
    var ok: Bool = true
    var reason: String? = nil
    var resetAtMs: Int? = nil
    var fiveHourPct: Int? = nil        // 5 小时窗已用%(仅有新鲜快照时非空), 供管理页显示
    var fiveHourResetAtMs: Int? = nil  // 5 小时窗恢复时间(ms), 始终带出供派活参考

    /// 出站 JSON 字典(nil 字段省略键, 服务端按缺失=null 处理)。
    var jsonObject: [String: Any] {
        var o: [String: Any] = ["ok": ok]
        if let reason { o["reason"] = reason }
        if let resetAtMs { o["reset_at"] = resetAtMs }
        if let fiveHourPct { o["five_hour_pct"] = fiveHourPct }
        if let fiveHourResetAtMs { o["five_hour_reset_at"] = fiveHourResetAtMs }
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

    /// `claude -p /usage` 查到的额度缓存(每 2min 由 refreshUsage 刷新)。
    private var usageFiveHourPct: Int?
    private var usageFiveHourResetMs: Int?
    private var usageSevenDayPct: Int?
    private var usageSevenDayResetMs: Int?
    private var usageAt: Date = .distantPast
    private let usageFreshSec: TimeInterval = 1500  // 25min 内视为新鲜(必须 > 轮询间隔 10min, 且容忍一次失败轮询);
                                                    // 否则值会在两次刷新之间被判过期 → hub 闪断显示 —。宁可短时展示稍旧值也持续显示到下次刷新。

    /// 每次 review 跑完喂入其输出, 命中限额则记下重置时间。
    func noteReviewOutput(_ logText: String) {
        if let hit = detectQuotaHit(logText) {
            reactiveBlock = (reason: hit.reason, resetAt: hit.resetAt)
            LogStore.shared.log("⚠️ 命中 Claude 限额(\(hit.reason)), 预计 \(hit.resetAt) 恢复; 本机将上报额度不足")
        }
    }

    /// 当前额度状态: 反应式(命中限额)优先; 否则用 /usage 的 5 小时/7 天窗判定 + 带出百分比与恢复时间。
    /// 默认 ok(拿不到 = 不拦, 交给反应式兜底; 管理页显示 —)。
    func current(config: Config) -> QuotaStatus {
        let fresh = Date().timeIntervalSince(usageAt) < usageFreshSec
        let f5 = fresh ? usageFiveHourPct : nil
        let f5r = fresh ? usageFiveHourResetMs : nil
        if let b = reactiveBlock {
            if Date() >= b.resetAt { reactiveBlock = nil }
            else { return QuotaStatus(ok: false, reason: b.reason, resetAtMs: ms(b.resetAt), fiveHourPct: f5, fiveHourResetAtMs: f5r) }
        }
        if fresh {
            if let f5, f5 >= config.quotaFiveHourThreshold {
                return QuotaStatus(ok: false, reason: "five_hour_\(f5)pct", resetAtMs: f5r, fiveHourPct: f5, fiveHourResetAtMs: f5r)
            }
            if let d7 = usageSevenDayPct, d7 >= config.quotaSevenDayThreshold {
                return QuotaStatus(ok: false, reason: "seven_day_\(d7)pct", resetAtMs: usageSevenDayResetMs, fiveHourPct: f5, fiveHourResetAtMs: f5r)
            }
        }
        return QuotaStatus(ok: true, fiveHourPct: f5, fiveHourResetAtMs: f5r)
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

    // MARK: - `claude -p /usage` 查额度(headless, 零 token, 自带重置时间)

    /// 跑 `claude -p /usage --output-format json`, 解析 session(5小时)/week 百分比+重置时间, 更新缓存。
    /// 返回是否刷新出新鲜额度(供上层决定要不要独立上报一次 .quota; 与 Node 版"仅解析成功才 send"对齐)。
    @discardableResult
    func refreshUsage(config: Config) async -> Bool {
        // --dangerously-skip-permissions: 跳过 claude 沙盒/权限初始化, 避免经 sandboxd 探测 Apple Music/媒体库
        // → 免得给成员弹"访问媒体库"授权(claude 行为被归因到本 app, 与 review 无关)。/usage 只读本地无副作用。
        let r = await ProcessRunner.run(config.claudePath, ["-p", "/usage", "--output-format", "json", "--dangerously-skip-permissions"])
        guard r.code == 0 else { LogStore.shared.log("查额度(/usage)退出码 \(r.code)"); return false }
        var text = r.stdout
        if let data = r.stdout.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let res = obj["result"] as? String { text = res }
        let ok = parseUsageText(text)
        if !ok {
            LogStore.shared.log("查额度(/usage): 未解析出 session/week 百分比(claude 版本过旧?)")
        }
        return ok
    }

    /// 解析 /usage 文本: "Current session: N% used · resets ..."(5小时窗)/ "Current week (all models): M% used · resets ..."。
    @discardableResult
    private func parseUsageText(_ text: String) -> Bool {
        var got = false
        if let g = firstMatch(#"Current session:\s*(\d+)%\s*used(?:[^\n]*?\bresets\s*([^\n(]+))?"#, text),
           let p = g[1].flatMap({ Int($0) }) {
            usageFiveHourPct = p; usageFiveHourResetMs = parseUsageReset(g[2] ?? ""); got = true
        }
        if let g = firstMatch(#"Current week \(all models\):\s*(\d+)%\s*used(?:[^\n]*?\bresets\s*([^\n(]+))?"#, text),
           let p = g[1].flatMap({ Int($0) }) {
            usageSevenDayPct = p; usageSevenDayResetMs = parseUsageReset(g[2] ?? ""); got = true
        }
        if got { usageAt = Date() }
        return got
    }

    /// 把 "Jul 10 at 3pm"(本机时区, 与 /usage 显示时区一致)解析成 epoch ms。
    private func parseUsageReset(_ s: String) -> Int? {
        guard let g = firstMatch(#"([A-Za-z]{3,})\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#, s),
              let monName = g[1], let day = g[2].flatMap({ Int($0) }), let h0 = g[3].flatMap({ Int($0) }) else { return nil }
        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        guard let mon = months[String(monName.prefix(3)).lowercased()] else { return nil }
        var hh = h0; let mm = g[4].flatMap { Int($0) } ?? 0; let ap = (g[5] ?? "").lowercased()
        if ap == "pm" && hh < 12 { hh += 12 }
        if ap == "am" && hh == 12 { hh = 0 }
        let cal = Calendar.current; let now = Date()
        var comps = DateComponents()
        comps.year = cal.component(.year, from: now); comps.month = mon; comps.day = day
        comps.hour = hh; comps.minute = mm; comps.second = 0
        guard var d = cal.date(from: comps) else { return nil }
        if d.timeIntervalSince(now) < -3 * 24 * 3600 { comps.year! += 1; d = cal.date(from: comps) ?? d }  // 跨年
        return Int(d.timeIntervalSince1970 * 1000)
    }

    // MARK: - helpers

    private func ms(_ d: Date) -> Int { Int(d.timeIntervalSince1970 * 1000) }

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

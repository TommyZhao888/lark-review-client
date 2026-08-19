import Foundation

/// Claude 额度(quota)状态上报载荷。与 Node 版 currentQuota() 对齐: {ok, reason, reset_at(ms)}。
struct QuotaStatus: Equatable {
    var ok: Bool = true
    var reason: String? = nil
    var resetAtMs: Int? = nil
    var fiveHourPct: Int? = nil        // 5 小时窗已用%(仅有新鲜快照时非空), 供管理页显示
    var fiveHourResetAtMs: Int? = nil  // 5 小时窗恢复时间(ms), 始终带出供派活参考
    var sevenDayPct: Int? = nil        // v1.9: 7 天窗已用%(独立透出, 供服务端评分选人的额度余量分项)
    var sevenDayResetAtMs: Int? = nil  // v1.9: 7 天窗恢复时间(ms)

    /// 出站 JSON 字典(nil 字段省略键, 服务端按缺失=null 处理)。
    var jsonObject: [String: Any] {
        var o: [String: Any] = ["ok": ok]
        if let reason { o["reason"] = reason }
        if let resetAtMs { o["reset_at"] = resetAtMs }
        if let fiveHourPct { o["five_hour_pct"] = fiveHourPct }
        if let fiveHourResetAtMs { o["five_hour_reset_at"] = fiveHourResetAtMs }
        if let sevenDayPct { o["seven_day_pct"] = sevenDayPct }
        if let sevenDayResetAtMs { o["seven_day_reset_at"] = sevenDayResetAtMs }
        return o
    }
}

/// 一个额度窗的展示值(设置页「额度」tab; 与 Node /quota 的 five_hour/seven_day/model_windows 对齐)。
struct QuotaWindow: Identifiable, Equatable {
    var name: String
    var pct: Int?
    var resetAtMs: Int?
    var id: String { name }
    var resetAt: Date? { resetAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
}

/// 查额度失败记录(设置页据此解释"为何没有百分比")。
struct QuotaFailNote: Equatable {
    var at: Date
    var reason: String
}

/// 额度快照(仅展示, 不上报): 百分比给缓存原值 —— 过期也照给, 由 fresh/updatedAt 让 UI 标注,
/// 而 ok/reason/resetAt 与上报服务端的判定完全一致(过期即视为未知)。
struct QuotaSnapshot {
    var ok = true
    var reason: String?
    var resetAt: Date?
    var fiveHour = QuotaWindow(name: "5 小时窗(current session)")
    var sevenDay = QuotaWindow(name: "周窗(7 天, 全部模型)")
    var modelWindows: [QuotaWindow] = []
    var updatedAt: Date?
    var fresh = false
    var lastError: QuotaFailNote?
    var raw = ""
}

/// 本机 claude 的账号套餐/版本(`claude auth status` + `--version`; 设置页展示用)。
struct ClaudeAccountInfo {
    var loggedIn: Bool?
    var authMethod: String?
    var subscriptionType: String?
    var email: String?
    var orgName: String?
    var version: String?
    var error: String?
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
    private var usageModelWindows: [QuotaWindow] = []   // 「按模型」周窗(如 Opus), 仅展示
    private var usageRawText = ""                       // 最近一次 /usage 原文(仅展示/排查, 不上报)
    private var usageLastError: QuotaFailNote?          // 最近一次查额度失败(成功即清空)
    private var usageNoPersist = true                   // 本机 claude 认 --no-session-persistence(不认则首次失败后关掉)

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
        let d7 = fresh ? usageSevenDayPct : nil
        let d7r = fresh ? usageSevenDayResetMs : nil
        if let b = reactiveBlock {
            if Date() >= b.resetAt { reactiveBlock = nil }
            else { return QuotaStatus(ok: false, reason: b.reason, resetAtMs: ms(b.resetAt), fiveHourPct: f5, fiveHourResetAtMs: f5r, sevenDayPct: d7, sevenDayResetAtMs: d7r) }
        }
        if fresh {
            if let f5, f5 >= config.quotaFiveHourThreshold {
                return QuotaStatus(ok: false, reason: "five_hour_\(f5)pct", resetAtMs: f5r, fiveHourPct: f5, fiveHourResetAtMs: f5r, sevenDayPct: d7, sevenDayResetAtMs: d7r)
            }
            if let d7v = d7, d7v >= config.quotaSevenDayThreshold {
                return QuotaStatus(ok: false, reason: "seven_day_\(d7v)pct", resetAtMs: d7r, fiveHourPct: f5, fiveHourResetAtMs: f5r, sevenDayPct: d7, sevenDayResetAtMs: d7r)
            }
        }
        return QuotaStatus(ok: true, fiveHourPct: f5, fiveHourResetAtMs: f5r, sevenDayPct: d7, sevenDayResetAtMs: d7r)
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

    /// 跑 `<quotaClaudePath> -p /usage --output-format json`, 解析 session(5小时)/week 百分比+重置时间, 更新缓存。
    /// 返回是否刷新出新鲜额度(供上层决定要不要独立上报一次 .quota; 与 Node 版"仅解析成功才 send"对齐)。
    @discardableResult
    func refreshUsage(config: Config, isRetry: Bool = false) async -> Bool {
        // --dangerously-skip-permissions: 跳过 claude 沙盒/权限初始化, 避免经 sandboxd 探测 Apple Music/媒体库
        // → 免得给成员弹"访问媒体库"授权(claude 行为被归因到本 app, 与 review 无关)。/usage 只读本地无副作用。
        let bin = config.effectiveQuotaClaudePath
        // 25s 超时(对齐 Node 版): 非 claude 的引擎会把 "/usage" 当普通提问跑一整轮, 不设上限会把这条轮询卡死。
        let r = await ProcessRunner.run(bin, Self.usageArgs(noSessionPersistence: usageNoPersist), timeoutMs: 25000)
        var text = r.stdout
        if let data = r.stdout.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let res = obj["result"] as? String { text = res }
        if parseUsageText(text) {
            usageRawText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            usageLastError = nil
            return true
        }
        // 老版 claude 不认 --no-session-persistence → 去掉重试一次(重试时该开关已关, 不会再递归)。
        if !isRetry, usageNoPersist, Self.isUnknownOptionError(r.stderr + text) {
            usageNoPersist = false
            LogStore.shared.log("查额度(/usage): 本机 claude 不认 --no-session-persistence, 去掉该开关重试"
                                + "(此后每次查额度会在 ~/.claude 留一条会话记录)")
            return await refreshUsage(config: config, isRetry: true)
        }
        let reason = usageFailReason(code: r.code, text: text, stderr: r.stderr)
        usageLastError = QuotaFailNote(at: Date(), reason: reason)
        LogStore.shared.log("查额度(/usage)失败[\(bin)]: \(reason)")
        return false
    }

    /// 探针参数。默认带 --no-session-persistence: 不加的话 claude 会把每次 /usage 存成一条会话记录
    /// (实测 claude 2.1.235: 每次 ~55KB, 每 10 分钟一条 → 一天 ~8MB, 还把成员的 `claude --resume`
    /// 列表刷满零轮次的 /usage 会话)。与 Node 版 usageArgs() 逐字对齐。
    static func usageArgs(noSessionPersistence: Bool) -> [String] {
        var a = ["-p", "/usage", "--output-format", "json", "--dangerously-skip-permissions"]
        if noSessionPersistence { a.append("--no-session-persistence") }
        return a
    }

    /// 命令行开关不被识别(老版 claude / 非 claude 引擎)。与 Node 版 /unknown (option|flag)/i 对齐。
    static func isUnknownOptionError(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("unknown option") || t.contains("unknown flag")
    }

    /// 额度查询失败时给出可行动的原因(别笼统甩"解析失败": 排查全靠这一行日志)。与 Node 版 usageFailReason 对齐。
    private func usageFailReason(code: Int32, text: String, stderr: String) -> String {
        func cut(_ s: String) -> String {
            String(s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(160))
        }
        let notClaude = "(/usage 是 Claude Code 独有能力: 若它不是真 claude —— 例如转发到别的引擎的适配脚本 ——"
                      + " 请把配置里的 quotaClaudePath 指向真 claude)"
        let errNote = stderr.isEmpty ? "" : "; stderr: \(cut(stderr))"
        if code == 124 { return "25s 超时被终止, 它可能把 \"/usage\" 当普通提问在跑 \(notClaude)\(errNote)" }
        if code != 0 { return "退出码 \(code) \(notClaude)\(errNote)" }
        if cut(text).isEmpty { return "无输出 \(notClaude)\(errNote)" }
        return "输出里没有 session/week 百分比 —— claude 未登录 / OAuth token 过期且刷新失败 / 额度接口被限流时,"
             + " /usage 只会打印\"用量构成\"而不带百分比行; 手工跑一次 `claude -p /usage` 复现: \(cut(text))"
    }

    /// 解析 /usage 文本: "Current session: N% used · resets ..."(5小时窗)/ "Current week (all models): M% used · resets ..."。
    /// 另收「按模型」的周窗行(如 "Current week (Opus): 12% used"): 仅供设置页展示, 不参与判定, 也不上报。
    @discardableResult
    func parseUsageText(_ text: String) -> Bool {   // internal: 供单测直接喂 /usage 文本
        var got = false
        if let g = firstMatch(#"Current session:\s*(\d+)%\s*used(?:[^\n]*?\bresets\s*([^\n(]+))?"#, text),
           let p = g[1].flatMap({ Int($0) }) {
            usageFiveHourPct = p; usageFiveHourResetMs = parseUsageReset(g[2] ?? ""); got = true
        }
        if let g = firstMatch(#"Current week \(all models\):\s*(\d+)%\s*used(?:[^\n]*?\bresets\s*([^\n(]+))?"#, text),
           let p = g[1].flatMap({ Int($0) }) {
            usageSevenDayPct = p; usageSevenDayResetMs = parseUsageReset(g[2] ?? ""); got = true
        }
        var windows: [QuotaWindow] = []
        for g in allMatches(#"Current week \(([^)\n]+)\):\s*(\d+)%\s*used(?:[^\n]*?\bresets\s*([^\n(]+))?"#, text) {
            guard let name = g[1]?.trimmingCharacters(in: .whitespaces), let p = g[2].flatMap({ Int($0) }) else { continue }
            if name.lowercased() == "all models" { continue }   // 总量那行已单独解析
            windows.append(QuotaWindow(name: name, pct: p, resetAtMs: parseUsageReset(g[3] ?? "")))
        }
        if got { usageAt = Date(); usageModelWindows = windows }
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

    // MARK: - 设置页「额度」tab

    /// 展示快照: 额度判定 + 各窗百分比/重置时间 + 数据新鲜度 + 最近失败原因 + /usage 原文。
    func snapshot(config: Config) -> QuotaSnapshot {
        let q = current(config: config)
        var s = QuotaSnapshot()
        s.ok = q.ok
        s.reason = q.reason
        s.resetAt = q.resetAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        s.fiveHour = QuotaWindow(name: "5 小时窗(current session)", pct: usageFiveHourPct, resetAtMs: usageFiveHourResetMs)
        s.sevenDay = QuotaWindow(name: "周窗(7 天, 全部模型)", pct: usageSevenDayPct, resetAtMs: usageSevenDayResetMs)
        s.modelWindows = usageModelWindows
        s.updatedAt = usageAt == .distantPast ? nil : usageAt
        s.fresh = Date().timeIntervalSince(usageAt) < usageFreshSec
        s.lastError = usageLastError
        s.raw = usageRawText
        return s
    }

    /// 账号套餐 + claude 版本(按需查 + 5min 缓存): 只在有人打开设置页时 spawn, 不进派活链路。
    private var account: ClaudeAccountInfo?
    private var accountAt: Date = .distantPast
    private let accountTtlSec: TimeInterval = 300

    func accountInfo(config: Config, force: Bool = false) async -> ClaudeAccountInfo {
        if !force, let account, Date().timeIntervalSince(accountAt) < accountTtlSec { return account }
        let bin = config.effectiveQuotaClaudePath
        async let statusRun = ProcessRunner.run(bin, ["auth", "status"], timeoutMs: 15000)
        async let versionRun = ProcessRunner.run(bin, ["--version"], timeoutMs: 15000)
        let (st, ver) = await (statusRun, versionRun)
        var info = ClaudeAccountInfo()
        if let data = st.stdout.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            info.loggedIn = obj["loggedIn"] as? Bool
            info.authMethod = obj["authMethod"] as? String
            info.subscriptionType = obj["subscriptionType"] as? String
            info.email = obj["email"] as? String
            info.orgName = obj["orgName"] as? String
        } else {
            info.error = "`\(bin) auth status` 没给出 JSON(退出码 \(st.code)) —— claude 版本过旧, 或它不是真 claude"
        }
        if ver.code == 0 {
            info.version = ver.stdout.split(separator: "\n").first
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        account = info
        accountAt = Date()
        return info
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

    /// 返回所有匹配的各捕获组(组 0 = 整体)。大小写不敏感。
    private func allMatches(_ pattern: String, _ text: String) -> [[String?]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
        }
    }
}

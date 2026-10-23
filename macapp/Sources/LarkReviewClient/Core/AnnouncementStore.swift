import Foundation

/// 服务端公告的本机已读状态(与 Node 版同一文件、同一格式: ~/.lark-review-client.json.announcements.json)。
/// seen = 已弹过通知(重连/重启不再弹); dismissed = 点过「知道了」(面板横幅不再显示)。各只留最近 200 条。
struct AnnouncementStore {
    static let keep = 200
    let path: String
    private(set) var seen: [String] = []
    private(set) var dismissed: [String] = []

    private struct File: Codable { var seen: [String]?; var dismissed: [String]? }

    init(path: String = ConfigStore.configPath + ".announcements.json") {
        self.path = path
        if let data = FileManager.default.contents(atPath: path),
           let f = try? JSONDecoder().decode(File.self, from: data) {
            seen = f.seen ?? []
            dismissed = f.dismissed ?? []
        }
    }

    /// 首次见到返回 true(并记为已弹过); 已见过返回 false。
    mutating func markSeen(_ id: String) -> Bool {
        guard !seen.contains(id) else { return false }
        seen.append(id)
        save()
        return true
    }

    mutating func dismiss(_ id: String) {
        guard !dismissed.contains(id) else { return }
        dismissed.append(id)
        save()
    }

    private mutating func save() {
        seen = Array(seen.suffix(Self.keep))
        dismissed = Array(dismissed.suffix(Self.keep))
        guard let data = try? JSONEncoder().encode(File(seen: seen, dismissed: dismissed)) else { return }
        let tmp = path + ".tmp"
        if (try? data.write(to: URL(fileURLWithPath: tmp))) != nil { _ = rename(tmp, path) }
    }
}

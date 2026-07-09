import Foundation

/// 读写 ~/.lark-review-client.json（与 Node 版完全同一文件，可来回切换）。
/// 保存时保留未知键（如 configPort），删除历史遗留 name/openId/promptOverride，原子写。
enum ConfigStore {

    static var configPath: String {
        if CommandLine.arguments.count > 1, CommandLine.arguments[1].hasSuffix(".json") {
            return CommandLine.arguments[1]
        }
        if let p = ProcessInfo.processInfo.environment["LARK_REVIEW_CLIENT_CONFIG"], !p.isEmpty {
            return p
        }
        return NSHomeDirectory() + "/.lark-review-client.json"
    }

    /// 容错读取：文件不存在 / 非法 JSON 都不失败，以空配置启动（对齐 Node loadConfig）。
    static func load() -> Config {
        var cfg = Config()
        guard let data = FileManager.default.contents(atPath: configPath),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return cfg
        }
        cfg.serverUrl = (obj["serverUrl"] as? String) ?? ""
        cfg.token = (obj["token"] as? String) ?? ""
        if let rm = obj["reviewModel"] as? String, !rm.isEmpty { cfg.reviewModel = rm }
        if let cp = obj["claudePath"] as? String, !cp.isEmpty { cfg.claudePath = cp }
        if let hb = obj["heartbeatMs"] as? Int, hb > 0 { cfg.heartbeatMs = hb }
        if let d = obj["worktreeMaxAgeDays"] as? Int, d > 0 { cfg.worktreeMaxAgeDays = d }
        if let n = obj["notify"] as? Bool { cfg.notify = n }
        if let s = obj["notifySound"] as? String { cfg.notifySound = s }
        if let repos = obj["repos"] as? [String: Any] {
            for (name, v) in repos {
                guard let rc = v as? [String: Any] else { continue }
                var entry = RepoConfig(
                    mainRepo: (rc["mainRepo"] as? String) ?? "",
                    worktreeBase: (rc["worktreeBase"] as? String) ?? ""
                )
                if let p = rc["prompt"] as? String,
                   !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    entry.prompt = p
                }
                cfg.repos[name] = entry
            }
        }
        return cfg
    }

    /// 只写技术性字段；name/openId 归服务端下发，永不写入本地配置（对齐 Node persistConfig）。
    static func save(_ cfg: Config) throws {
        var cur: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: configPath),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            cur = obj
        }
        cur["serverUrl"] = cfg.serverUrl.trimmingCharacters(in: .whitespaces)
        cur["token"] = cfg.token.trimmingCharacters(in: .whitespaces)
        let claudePath = cfg.claudePath.trimmingCharacters(in: .whitespaces)
        cur["claudePath"] = claudePath.isEmpty ? "claude" : claudePath
        let model = cfg.reviewModel.trimmingCharacters(in: .whitespaces)
        cur["reviewModel"] = model.isEmpty ? "claude-opus-4-8" : model
        cur["worktreeMaxAgeDays"] = cfg.worktreeMaxAgeDays > 0 ? cfg.worktreeMaxAgeDays : 14
        cur["heartbeatMs"] = cfg.heartbeatMs > 0 ? cfg.heartbeatMs : 15000
        cur["notify"] = cfg.notify
        if cfg.notifySound.isEmpty { cur.removeValue(forKey: "notifySound") }
        else { cur["notifySound"] = cfg.notifySound }

        // repos 入库前收敛字段：{mainRepo, worktreeBase, prompt?}；prompt 空白则不落盘。
        var repos: [String: Any] = [:]
        for (name, rc) in cfg.repos {
            var e: [String: Any] = [
                "mainRepo": rc.mainRepo.trimmingCharacters(in: .whitespaces),
                "worktreeBase": rc.worktreeBase.trimmingCharacters(in: .whitespaces),
            ]
            if let p = rc.prompt, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                e["prompt"] = p
            }
            repos[name] = e
        }
        cur["repos"] = repos

        // 身份归服务端，清掉历史遗留字段；全局提示词已废弃。
        cur.removeValue(forKey: "name")
        cur.removeValue(forKey: "openId")
        cur.removeValue(forKey: "promptOverride")

        let data = try JSONSerialization.data(withJSONObject: cur, options: [.prettyPrinted, .sortedKeys])
        let tmp = configPath + ".tmp"
        try (String(data: data, encoding: .utf8)! + "\n").write(toFile: tmp, atomically: false, encoding: .utf8)
        guard rename(tmp, configPath) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "rename \(tmp) → \(configPath) 失败"])
        }
    }
}

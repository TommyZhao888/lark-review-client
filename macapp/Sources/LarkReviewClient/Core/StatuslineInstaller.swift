import Foundation

/// 清理旧版(1.3~1.5.5)对 Claude statusLine 的改动。
/// 现在改用 `claude -p /usage` 查额度(headless, 不依赖 statusLine), 不再需要动 statusLine。
/// 若此前把 statusLine 设成/包装成了额度脚本 → 还原你原来的 statusLine(inner-statusline.json)
/// 或移除我们加的, 并删掉临时脚本/inner, 保持你的 Claude 环境干净。
enum StatuslineInstaller {

    static func cleanup() {
        let home = NSHomeDirectory()
        let dir = home + "/.lark-review-client"
        let innerFile = dir + "/inner-statusline.json"
        let settingsPath = home + "/.claude/settings.json"
        let fm = FileManager.default
        do {
            if let data = fm.contents(atPath: settingsPath),
               var settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let sl = settings["statusLine"] as? [String: Any],
               let cmd = sl["command"] as? String, cmd.contains("statusline-quota.sh") {
                if let idata = fm.contents(atPath: innerFile),
                   let inner = (try? JSONSerialization.jsonObject(with: idata)) as? [String: Any],
                   let icmd = inner["command"] as? String {
                    settings["statusLine"] = ["type": (inner["type"] as? String) ?? "command", "command": icmd]  // 还原原来的
                } else {
                    settings.removeValue(forKey: "statusLine")                                                    // 当初无 statusline → 移除
                }
                let out = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                try out.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
                LogStore.shared.log("已还原此前为额度快照修改的 Claude statusLine(现改用 /usage 查额度)")
            }
        } catch {
            LogStore.shared.log("清理旧 statusline 配置失败(不影响 review): \(error.localizedDescription)")
        }
        try? fm.removeItem(atPath: innerFile)
        try? fm.removeItem(atPath: dir + "/statusline-quota.sh")
    }
}

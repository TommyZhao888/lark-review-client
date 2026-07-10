import Foundation

/// 自动把额度快照脚本配成 Claude Code 的 statusLine, 免逐台手动设置(对齐 Node 版 ensureStatuslineInstalled)。
/// 仅当【未配过】statusLine 才装(绝不覆盖已有的, 如 claude-hud); 脚本写到 ~/.lark-review-client/statusline-quota.sh。
/// 注意: statusLine 只在【交互】使用 Claude 时触发 → 纯跑 review、平时不交互用 Claude 的机器快照不会刷新
/// (>15min 过期, hub 显示 —, 属正常, 非 bug)。config.autoStatusline=false 可关闭。
enum StatuslineInstaller {

    static func ensure(config: Config) {
        guard config.autoStatusline else { return }
        let home = NSHomeDirectory()
        let dir = home + "/.lark-review-client"
        let scriptPath = dir + "/statusline-quota.sh"
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try SCRIPT.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        } catch {
            LogStore.shared.log("额度快照脚本写入失败(不影响 review): \(error.localizedDescription)")
            return
        }

        let settingsPath = home + "/.claude/settings.json"
        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            settings = obj
        }
        let innerFile = dir + "/inner-statusline.json"
        var innerToSave: [String: Any]? = nil
        if let sl = settings["statusLine"] as? [String: Any], let cmd = sl["command"] as? String {
            if cmd.contains("statusline-quota.sh") { return }                                   // 已是我们的(可能已包装)→ 幂等
            // 任何已有 statusLine(含 claude-hud)→ 包装: 我们的脚本每次自己从 stdin 的 rate_limits 写快照
            // (不依赖对方工具写), 再链式调用原命令显示其输出(共存)。比桥接第三方配置更稳。
            innerToSave = ["type": (sl["type"] as? String) ?? "command", "command": cmd]
        }
        if let inner = innerToSave {
            if let d = try? JSONSerialization.data(withJSONObject: inner, options: [.prettyPrinted]) {
                try? d.write(to: URL(fileURLWithPath: innerFile), options: .atomic)
            }
        } else {
            try? fm.removeItem(atPath: innerFile)   // 之前包过、现在没原 statusline 了 → 清理
        }
        settings["statusLine"] = ["type": "command", "command": "bash '\(scriptPath)'"]
        do {
            try fm.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            LogStore.shared.log(innerToSave != nil
                ? "已把你原有的 statusline 包进来(屏幕仍显示它)并顺带写额度快照 → \(settingsPath)"
                : "已自动配置 Claude statusLine 写额度快照 → \(settingsPath); 交互用 Claude 时刷新 5 小时额度, hub 即可显示百分比")
        } catch {
            LogStore.shared.log("自动配置 statusLine 失败(不影响 review): \(error.localizedDescription)")
        }
    }

    /// 精简版 statusline 脚本(与仓库根 statusline-quota.sh 等效: 落 rate_limits 快照 + 打印状态行)。
    /// 用 Swift 原始字符串 #"""..."""# 内嵌, 避免 \( 被当成插值。
    private static let SCRIPT = #"""
    #!/usr/bin/env bash
    # 由 lark-review-client(macapp)自动安装。把 Claude statusLine 的 rate_limits 落成快照,
    # 供 review 客户端前瞻式判断额度(5小时窗已用%)。仅交互用 Claude 时刷新。
    set -uo pipefail
    SNAP="${LARK_QUOTA_SNAPSHOT:-$HOME/.claude/lark-quota.json}"
    IN="$(cat)"; [ -z "$IN" ] && { echo "lark-quota"; exit 0; }
    if ! command -v jq >/dev/null 2>&1; then echo "claude"; exit 0; fi
    if [ "$(printf '%s' "$IN" | jq -r 'if .rate_limits then 1 else 0 end' 2>/dev/null)" = "1" ]; then
      mkdir -p "$(dirname "$SNAP")" 2>/dev/null || true
      T="$SNAP.$$.tmp"
      printf '%s' "$IN" | jq -c '{updated_at:(now|todate),five_hour:{used_percentage:(.rate_limits.five_hour.used_percentage//null),resets_at:(.rate_limits.five_hour.resets_at//null)},seven_day:{used_percentage:(.rate_limits.seven_day.used_percentage//null),resets_at:(.rate_limits.seven_day.resets_at//null)}}' > "$T" 2>/dev/null && mv "$T" "$SNAP" 2>/dev/null || rm -f "$T" 2>/dev/null || true
    fi
    # 若客户端把你原有的 statusline 包了进来, 就把 stdin 喂给它、显示它的输出(共存, 不抢占你的显示)。
    INNER_FILE="$HOME/.lark-review-client/inner-statusline.json"
    INNER=""
    [ -f "$INNER_FILE" ] && INNER=$(jq -r '.command // empty' "$INNER_FILE" 2>/dev/null)
    if [ -n "$INNER" ]; then
      OUT=$(printf '%s' "$IN" | eval "$INNER" 2>/dev/null) && [ -n "$OUT" ] && { printf '%s' "$OUT"; exit 0; }
    fi
    printf '%s' "$IN" | jq -r '(.model.display_name//"claude") as $m|(.rate_limits.five_hour.used_percentage) as $f|(.rate_limits.seven_day.used_percentage) as $d|if $f!=null then "\($m) | 5h \($f)% | 7d \($d//0)%" else $m end' 2>/dev/null || echo claude
    """#
}

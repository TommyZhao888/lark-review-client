import Foundation

/// 客户端版本：升级功能时手动 +1（与 Info.plist 保持一致）。服务端据此判断是否提示升级。
let CLIENT_VERSION = "1.8.0"

/// 单个 repo 的本机配置（~/.lark-review-client.json 的 repos["owner/repo"]）。
/// v1.7 起路径均可留空 = 自动模式（clone 到 repoBaseDir/<owner-repo>）。
struct RepoConfig: Codable, Equatable {
    var mainRepo: String = ""
    var worktreeBase: String = ""
    /// 该项目的本机提示词覆盖；空白不落盘。
    var prompt: String?
    var isEmpty: Bool {
        mainRepo.trimmingCharacters(in: .whitespaces).isEmpty
            && worktreeBase.trimmingCharacters(in: .whitespaces).isEmpty
            && (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 某项目在本机的生效路径（手动配置优先，缺省按 repoBaseDir 自动解析，与 Node resolveRepoConf 一致）。
struct ResolvedRepo {
    var mainRepo: String
    var worktreeBase: String
    var prompt: String?
    var auto: Bool
}

/// 本机配置，字段名与 Node 版 JSON 完全一致。
/// 身份 open_id/name 由服务端按 token 下发，永不写入本地。
struct Config: Equatable {
    var serverUrl: String = ""
    var token: String = ""
    var repos: [String: RepoConfig] = [:]
    var reviewModel: String = "claude-opus-4-8"
    var claudePath: String = "claude"
    var heartbeatMs: Int = 15000
    var worktreeMaxAgeDays: Int = 14
    /// 单次 review 的 claude 执行超时(ms): 超时自动终止并按失败上报(交服务端改派), 避免卡死占住队列。
    /// 默认 30min; 0 = 不限时(旧行为)。与 Node cfg.reviewTimeoutMs 对齐。
    var reviewTimeoutMs: Int = 1800000
    var notify: Bool = true
    var notifySound: String = ""
    /// 空闲(无在跑/排队 review)且连上时, 检测到新版本自动更新(下载 Releases dmg 原地替换 + 重启)。默认关。
    var autoUpdate: Bool = false

    // ---- v1.7: 项目自动参与 + 自动 clone + 提示词两级 ----
    /// 自动参与服务端下发的全部受管项目(路径留空的项目首次派单时自动 clone)。false = 只参与 repos 里配置的。
    var autoRepos: Bool = true
    /// 默认克隆根目录：未单独配置路径的项目 clone 到 <repoBaseDir>/<owner-repo>。
    var repoBaseDir: String = NSHomeDirectory() + "/LarkReviewRepos"
    /// 全局 review 提示词(所有项目生效; 单项目 repos[].prompt 优先)。空 = 不启用。
    var globalPrompt: String = ""

    // ---- Claude 额度(quota)相关 ----
    /// 前瞻式额度快照路径(statusline 写的 rate_limits)。默认指向标准路径(自动启用前瞻式):
    /// 快照不存在/过期时读到无百分比(hub 显示 —), 有 statusline 写入后自动出现百分比。设为 "" 关闭。
    var quotaSnapshotPath: String = NSHomeDirectory() + "/.claude/lark-quota.json"
    /// 5 小时窗已用 >= 此% 视为额度不足(不再被派 review)。
    var quotaFiveHourThreshold: Int = 90
    /// 7 天窗已用 >= 此% 视为额度不足。
    var quotaSevenDayThreshold: Int = 95
    /// 快照超过此毫秒数未更新视为过期(不采信, 退回反应式)。
    var quotaSnapshotFreshnessMs: Int = 900000
    /// 自动把额度快照脚本配成 Claude statusLine(仅当未配过 statusLine); false 关闭。
    var autoStatusline: Bool = true

    /// 配置是否完整到可以连接服务端。repos 不是硬性条件：
    /// 项目清单由服务端下发，没配 repo 也允许连接注册（只是不会被派单）。
    var isReady: Bool { !serverUrl.isEmpty && !token.isEmpty }

    var heartbeatInterval: TimeInterval { Double(heartbeatMs) / 1000.0 }

    /// 设置页以「分钟」编辑超时(内部仍存 ms)。0 = 不限时。
    var reviewTimeoutMinutes: Int {
        get { reviewTimeoutMs / 60000 }
        set { reviewTimeoutMs = max(0, newValue) * 60000 }
    }

    // ---- v1.7 项目解析(与 Node 版 repoDirName/resolveRepoConf/effectiveRepoNames/repoParticipating 一致) ----

    /// repo 目录名: owner/repo → owner-repo(全名替换分隔符, 避免不同 owner 的同名 repo 撞目录)。
    static func repoDirName(_ repoName: String) -> String {
        repoName.replacingOccurrences(of: #"[\\/]+"#, with: "-", options: .regularExpression)
    }

    /// 解析某项目在本机的生效路径/提示词。配置了 mainRepo = 手动模式(旧行为);
    /// 未配置 = 自动: <repoBaseDir>/<owner-repo>; worktreeBase 缺省 = mainRepo + "-worktrees"。
    func resolveRepo(_ repoName: String) -> ResolvedRepo {
        let rc = repos[repoName] ?? RepoConfig()
        let manualMain = rc.mainRepo.trimmingCharacters(in: .whitespaces)
        let base = repoBaseDir.trimmingCharacters(in: .whitespaces).isEmpty
            ? NSHomeDirectory() + "/LarkReviewRepos" : repoBaseDir
        let mainRepo = manualMain.isEmpty ? base + "/" + Self.repoDirName(repoName) : manualMain
        let wt = rc.worktreeBase.trimmingCharacters(in: .whitespaces)
        return ResolvedRepo(
            mainRepo: mainRepo,
            worktreeBase: wt.isEmpty ? mainRepo + "-worktrees" : wt,
            prompt: rc.prompt,
            auto: manualMain.isEmpty
        )
    }

    /// 本客户端实际参与(会被派单/上报)的项目名集合。服务端受管清单为权威:
    /// - 有清单时: autoRepos → 全部受管项目; 否则 → 受管 ∩ 本机配置(手动 opt-in 子集)。
    ///   本机多配的、服务端未受管的项目【不参与、也不上报】——避免把无关项目 advertise 给服务端。
    /// - 无清单时(旧服务端 / 尚未收到 register_ack): 回退旧行为, 本机配置的都算(兼容手动配置)。
    func effectiveRepoNames(managed: [ManagedRepo]) -> [String] {
        let managedNames = Set(managed.map(\.repo))
        if managedNames.isEmpty { return repos.keys.sorted() }
        if autoRepos { return managedNames.sorted() }
        return managedNames.intersection(repos.keys).sorted()
    }

    /// 是否参与某项目(会接它的单)。服务端受管清单为权威(语义同 effectiveRepoNames)。
    func participates(_ repoName: String, managed: [ManagedRepo]) -> Bool {
        let managedNames = Set(managed.map(\.repo))
        if managedNames.isEmpty { return repos[repoName] != nil }
        guard managedNames.contains(repoName) else { return false }
        return autoRepos || repos[repoName] != nil
    }
}

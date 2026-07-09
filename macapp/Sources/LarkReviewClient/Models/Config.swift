import Foundation

/// 客户端版本：升级功能时手动 +1（与 Info.plist 保持一致）。服务端据此判断是否提示升级。
let CLIENT_VERSION = "1.4.4"

/// 单个 repo 的本机配置（~/.lark-review-client.json 的 repos["owner/repo"]）。
struct RepoConfig: Codable, Equatable {
    var mainRepo: String
    var worktreeBase: String
    /// 该项目的本机提示词覆盖；空白不落盘。
    var prompt: String?
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
    var notify: Bool = true
    var notifySound: String = ""
    /// 空闲(无在跑/排队 review)且连上时, 检测到新版本自动更新(git pull + make bundle + 重启)。默认关。
    var autoUpdate: Bool = false

    /// 配置是否完整到可以连接服务端。repos 不是硬性条件：
    /// 项目清单由服务端下发，没配 repo 也允许连接注册（只是不会被派单）。
    var isReady: Bool { !serverUrl.isEmpty && !token.isEmpty }

    var heartbeatInterval: TimeInterval { Double(heartbeatMs) / 1000.0 }
}

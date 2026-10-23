import Foundation
import Observation

/// UI 唯一数据源。所有 Core 模块通过 MainActor 更新它，SwiftUI 自动刷新。
@MainActor
@Observable
final class AppState {

    enum ConnectionState: Equatable {
        case disconnected      // 未连接（含重连间隙）
        case connecting
        case connected         // WS 已连上，等 register_ack
        case registered        // 已注册，正常待命
        case halted(String)    // 注册被拒（bad_token 等）：暂停自动重连，等改 token
    }

    struct Identity: Equatable {
        var openId: String
        var name: String
        var recommendedVersion: String?
    }

    struct RunningJob: Equatable {
        var repo: String
        var prNum: Int
        var branch: String
        var stage: String      // "worktree" | "claude"
        var since: Date
    }

    /// 自更新阶段（UI 展示 + 防重复触发）。
    enum UpdatePhase: Equatable {
        case idle
        /// 进行中：当前步骤文案（下载/解包/替换…）+ 下载进度（仅下载阶段有，其余为 nil）。
        case running(String, SelfUpdater.DownloadProgress?)
        case failed(String)    // 失败，附原因
    }

    var connection: ConnectionState = .disconnected
    var identity: Identity?                 // 服务端下发，只读展示，绝不本地持久化
    /// 服务端统一下发的 review 模型(register_ack / review_model_updated)。非 nil → 设置页只读显示它;
    /// nil(旧 hub 未下发 / 尚未注册)→ 本机配置可改。只读展示，不本地持久化。
    var serverReviewModel: String?
    /// 当前有效的服务端公告(最近一次 ack 下发 + 之后推送的); 点过「知道了」的不在面板横幅显示。
    var announcements: [Announcement] = []
    var dismissedAnnouncementIds: Set<String> = []
    var visibleAnnouncements: [Announcement] {
        announcements.filter { !dismissedAnnouncementIds.contains($0.id) && !$0.isExpired }
    }
    var upgrade: UpgradeInfo?
    var updatePhase: UpdatePhase = .idle
    var managedRepos: [ManagedRepo] = []
    var runningJob: RunningJob?
    /// 用户已请求终止当前 review(菜单栏据此显示「终止中…」并禁用按钮)。
    var cancelling: Bool = false
    var queuedJobs: [(repo: String, prNum: Int)] = []
    var config: Config = Config()
    /// 运行日志内存镜像（供 LogsView 实时显示）。
    var recentLogLines: [String] = []

    /// WebSocket 消息帧日志（收/发原文，供 LogsView「WS 消息」tab 排查协议问题）。
    struct WSLogEntry: Identifiable, Equatable {
        let id: Int
        let date: Date
        let outbound: Bool     // true = client→server
        let text: String
        var isHeartbeat: Bool { text.contains("\"type\":\"heartbeat\"") }
    }
    var wsMessages: [WSLogEntry] = []
    private var wsSeq = 0

    var isRegistered: Bool { connection == .registered }

    /// 菜单栏标题：🦁⚡N 在跑 / 🦁🟢 在线待命 / 🦁🔴 离线，末尾 🆙 有新版本。
    var menuBarTitle: String {
        var t = "🦁"
        let activeCount = (runningJob != nil ? 1 : 0) + queuedJobs.count
        if activeCount > 0 {
            t += "⚡\(activeCount)"
        } else if isRegistered {
            t += "🟢"
        } else {
            t += "🔴"
        }
        if upgrade != nil { t += "🆙" }
        return t
    }

    var connectionLabel: String {
        switch connection {
        case .disconnected: return "未连接"
        case .connecting: return "连接中…"
        case .connected: return "已连接，注册中…"
        case .registered: return "在线待命"
        case .halted(let reason): return "注册被拒（\(reason)），请更换 token"
        }
    }

    func appendWSMessage(outbound: Bool, text: String) {
        wsSeq += 1
        wsMessages.append(WSLogEntry(id: wsSeq, date: Date(), outbound: outbound, text: text))
        if wsMessages.count > 500 {
            wsMessages.removeFirst(wsMessages.count - 500)
        }
    }

    func clearWSMessages() {
        wsMessages.removeAll()
    }

    func appendLog(_ line: String) {
        recentLogLines.append(line)
        if recentLogLines.count > 2000 {
            recentLogLines.removeFirst(recentLogLines.count - 2000)
        }
    }
}

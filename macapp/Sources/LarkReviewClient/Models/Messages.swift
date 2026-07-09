import Foundation

// ==================== WS 协议（与 Node 版逐字段对齐） ====================
// 出站消息手工构造 JSON 字典再序列化（review_result 的 inline_count 必须保持字符串、
// reconnected 的 pr_num 是数字或空串，Codable 表达这种两态反而绕）。
// 入站消息先解信封 type，再二次 decode；失败/未知一律静默丢弃。

// ---------- 出站 ----------

enum OutboundMessage {
    case register(token: String, hostname: String, repos: [String], version: String)
    case heartbeat
    case reviewProgress(jobId: String, stage: String)   // stage: "worktree" | "claude"
    case reviewResult(jobId: String, result: ReviewResult)
    case reconnected(wasBusy: Bool, repo: String, prNum: Int?)   // prNum 无任务时发 ""

    var jsonObject: [String: Any] {
        switch self {
        case let .register(token, hostname, repos, version):
            return ["type": "register", "token": token, "hostname": hostname,
                    "repos": repos, "version": version]
        case .heartbeat:
            return ["type": "heartbeat"]
        case let .reviewProgress(jobId, stage):
            return ["type": "review_progress", "job_id": jobId, "stage": stage]
        case let .reviewResult(jobId, r):
            return ["type": "review_result", "job_id": jobId,
                    "exit_code": r.exitCode, "log_tail": r.logTail,
                    "result_line": r.resultLine, "verdict": r.verdict,
                    "general_comment_url": r.generalCommentUrl, "inline_count": r.inlineCount]
        case let .reconnected(wasBusy, repo, prNum):
            return ["type": "reconnected", "was_busy": wasBusy, "repo": repo,
                    "pr_num": prNum.map { $0 as Any } ?? ""]
        }
    }

    func encodedString() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// 一次 review 的结果（review_result 的载荷）。
/// inline_count 是字符串：正则捕获的数字串，无匹配时为 "?"（服务端兼容，不能改成 Int）。
struct ReviewResult: Equatable {
    var exitCode: Int
    var logTail: String
    var resultLine: String = ""
    var verdict: String = ""
    var generalCommentUrl: String = ""
    var inlineCount: String = "?"
}

// ---------- 入站 ----------

struct ManagedRepo: Codable, Equatable, Identifiable {
    var repo: String
    var prompt: String?
    var provider: String?
    var id: String { repo }
}

struct UpgradeInfo: Codable, Equatable {
    var recommended: String?
    var min: String?
    var below_min: Bool?
    var message: String?
}

struct RegisterAck: Codable {
    var open_id: String?
    var name: String?
    var recommended_version: String?
    var upgrade: UpgradeInfo?
    var managed_repos: [ManagedRepo]?
}

struct ReposUpdated: Codable {
    var managed_repos: [ManagedRepo]?
}

struct RegisterReject: Codable {
    var reason: String?
}

struct ReviewJob: Codable, Equatable {
    var job_id: String
    var pr_num: Int
    var repo: String
    var branch: String?
    var provider: String?          // "azdo" 表示 Azure DevOps
    var pr_url: String?
    var ci_overall: String?
    var ci_failed_names: String?
    var review_model: String?
    var prompt_template: String?
}

struct PrClosed: Codable {
    var repo: String
    var pr_num: Int
}

enum InboundMessage {
    case registerAck(RegisterAck)
    case reposUpdated(ReposUpdated)
    case registerReject(RegisterReject)
    case reviewJob(ReviewJob)
    case prClosed(PrClosed)

    /// 解析入站帧。JSON 非法 / type 未知 / 二次 decode 失败都返回 nil（对齐 Node：静默丢弃）。
    static func parse(_ text: String) -> InboundMessage? {
        guard let data = text.data(using: .utf8) else { return nil }
        struct Envelope: Codable { var type: String? }
        let dec = JSONDecoder()
        guard let env = try? dec.decode(Envelope.self, from: data), let type = env.type else { return nil }
        switch type {
        case "register_ack":    return (try? dec.decode(RegisterAck.self, from: data)).map { .registerAck($0) }
        case "repos_updated":   return (try? dec.decode(ReposUpdated.self, from: data)).map { .reposUpdated($0) }
        case "register_reject": return (try? dec.decode(RegisterReject.self, from: data)).map { .registerReject($0) }
        case "review_job":      return (try? dec.decode(ReviewJob.self, from: data)).map { .reviewJob($0) }
        case "pr_closed":       return (try? dec.decode(PrClosed.self, from: data)).map { .prClosed($0) }
        default:                return nil
        }
    }
}

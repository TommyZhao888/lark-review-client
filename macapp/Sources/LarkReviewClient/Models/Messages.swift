import Foundation

// ==================== WS 协议（与 Node 版逐字段对齐） ====================
// 出站消息手工构造 JSON 字典再序列化（review_result 的 inline_count 必须保持字符串、
// reconnected 的 pr_num 是数字或空串，Codable 表达这种两态反而绕）。
// 入站消息先解信封 type，再二次 decode；失败/未知一律静默丢弃。

// ---------- 出站 ----------

enum OutboundMessage {
    case register(token: String, hostname: String, repos: [String], version: String, quota: QuotaStatus)
    case heartbeat(quota: QuotaStatus)
    case reviewProgress(jobId: String, stage: String)   // stage: "worktree" | "claude"
    case reviewResult(jobId: String, result: ReviewResult)
    case reconnected(wasBusy: Bool, repo: String, prNum: Int?)   // prNum 无任务时发 ""

    var jsonObject: [String: Any] {
        switch self {
        case let .register(token, hostname, repos, version, quota):
            return ["type": "register", "token": token, "hostname": hostname,
                    "repos": repos, "version": version, "quota": quota.jsonObject]
        case let .heartbeat(quota):
            return ["type": "heartbeat", "quota": quota.jsonObject]
        case let .reviewProgress(jobId, stage):
            return ["type": "review_progress", "job_id": jobId, "stage": stage]
        case let .reviewResult(jobId, r):
            return ["type": "review_result", "job_id": jobId,
                    "exit_code": r.exitCode, "log_tail": r.logTail,
                    "result_line": r.resultLine, "verdict": r.verdict,
                    "general_comment_url": r.generalCommentUrl, "inline_count": r.inlineCount,
                    "quota": r.quota.jsonObject, "declined_quota": r.declinedQuota]
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
    /// 本机 Claude 额度状态(随结果上报; 命中限额那次尤其关键)。
    var quota: QuotaStatus = QuotaStatus()
    /// 派活前自查额度不足 → 拒接本单(未跑 review), 交服务端改派。
    var declinedQuota: Bool = false
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

/// 宽容解码 Int：服务端（JS 无类型）对 pr_num 等字段可能发数字也可能发字符串
/// （生产实测 review_job.pr_num 为 "593" 字符串），两种都必须接受。
private func decodeLenientInt<K: CodingKey>(
    _ c: KeyedDecodingContainer<K>, _ key: K
) throws -> Int {
    if let i = try? c.decode(Int.self, forKey: key) { return i }
    if let s = try? c.decode(String.self, forKey: key), let i = Int(s) { return i }
    throw DecodingError.typeMismatch(Int.self, DecodingError.Context(
        codingPath: c.codingPath + [key],
        debugDescription: "既不是数字也不是数字字符串"))
}

// 自定义 init(from:) 放 extension，保留 struct 的 memberwise init。
extension ReviewJob {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        job_id = try c.decode(String.self, forKey: .job_id)
        pr_num = try decodeLenientInt(c, CodingKeys.pr_num)
        repo = try c.decode(String.self, forKey: .repo)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        pr_url = try c.decodeIfPresent(String.self, forKey: .pr_url)
        ci_overall = try c.decodeIfPresent(String.self, forKey: .ci_overall)
        ci_failed_names = try c.decodeIfPresent(String.self, forKey: .ci_failed_names)
        review_model = try c.decodeIfPresent(String.self, forKey: .review_model)
        prompt_template = try c.decodeIfPresent(String.self, forKey: .prompt_template)
    }
}

extension PrClosed {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decode(String.self, forKey: .repo)
        pr_num = try decodeLenientInt(c, CodingKeys.pr_num)
    }
}

enum InboundMessage {
    case registerAck(RegisterAck)
    case reposUpdated(ReposUpdated)
    case registerReject(RegisterReject)
    case reviewJob(ReviewJob)
    case prClosed(PrClosed)

    /// 解析入站帧。JSON 非法 / type 未知返回 nil（对齐 Node：静默丢弃）。
    /// 已知类型但载荷解码失败也返回 nil，但会调用 onDecodeFailure——
    /// 完全静默会掩盖协议不兼容（如服务端 pr_num 发字符串），必须留痕。
    nonisolated(unsafe) static var onDecodeFailure: ((_ type: String, _ error: Error) -> Void)?

    static func parse(_ text: String) -> InboundMessage? {
        guard let data = text.data(using: .utf8) else { return nil }
        struct Envelope: Codable { var type: String? }
        let dec = JSONDecoder()
        guard let env = try? dec.decode(Envelope.self, from: data), let type = env.type else { return nil }

        func decode<T: Codable>(_ t: T.Type, _ wrap: (T) -> InboundMessage) -> InboundMessage? {
            do { return wrap(try dec.decode(t, from: data)) }
            catch {
                onDecodeFailure?(type, error)
                return nil
            }
        }
        switch type {
        case "register_ack":    return decode(RegisterAck.self) { .registerAck($0) }
        case "repos_updated":   return decode(ReposUpdated.self) { .reposUpdated($0) }
        case "register_reject": return decode(RegisterReject.self) { .registerReject($0) }
        case "review_job":      return decode(ReviewJob.self) { .reviewJob($0) }
        case "pr_closed":       return decode(PrClosed.self) { .prClosed($0) }
        default:                return nil
        }
    }
}

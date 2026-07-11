import Foundation

/// 自动 clone（对齐 Node 版 deriveCloneUrl/ensureRepoCloned）：
/// 未配置路径的项目在首次被派单时 clone 到 repoBaseDir/<owner-repo>。
/// GitHub 优先 `gh repo clone`（用成员已登录的 gh 鉴权）；Azure DevOps 从派单的 pr_url 剥出
/// /_git/ 远端，优先用 AZURE_DEVOPS_EXT_PAT（az 同款 PAT）注入 http.extraheader Basic 认证——
/// 绕开本机 keychain 里坏凭证的干扰，clone 成功后写入该 repo 本地配置让后续 fetch 免交互。
/// GIT_TERMINAL_PROMPT=0：headless 下 git 弹凭证输入会永久挂死，宁可快速失败把原因带回。
enum RepoCloner {

    struct CloneOutcome {
        var ok: Bool
        var cloned: Bool = false
        var detail: String = ""
    }

    /// 从 review_job 推导仓库远端地址。github → https://github.com/<owner/repo>.git；
    /// azdo → pr_url 去掉 /pullrequest/<id> 即 git 远端。推不出返回 nil。
    static func deriveCloneUrl(repo: String, provider: String?, prUrl: String?) -> String? {
        if provider == "azdo" {
            guard let prUrl,
                  let range = prUrl.range(of: #"^(https?://.+/_git/[^/]+)/pull[Rr]equest/\d+"#,
                                          options: .regularExpression) else { return nil }
            let matched = String(prUrl[range])
            // 去掉尾部 /pullrequest/<id>
            return matched.replacingOccurrences(of: #"/pull[Rr]equest/\d+$"#, with: "",
                                                options: .regularExpression)
        }
        return "https://github.com/\(repo).git"
    }

    /// GUI app 拿不到 shell profile 的环境变量（launchd 会话），PAT 需经登录 shell 查询一次并缓存。
    nonisolated(unsafe) private static var cachedAzdoPat: String??

    static func azdoPat() -> String? {
        if let cached = cachedAzdoPat { return cached }
        // 先看进程环境（终端里直接跑 app / 测试注入时有效）
        let env = ProcessInfo.processInfo.environment
        if let p = env["AZURE_DEVOPS_EXT_PAT"], !p.isEmpty { cachedAzdoPat = p; return p }
        if let p = env["AZDO_PAT"], !p.isEmpty { cachedAzdoPat = p; return p }
        // 再经登录 shell 展开（成员按 README 把 PAT 写在 shell profile 里）
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "printf %s \"${AZURE_DEVOPS_EXT_PAT:-${AZDO_PAT:-}}\""]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { cachedAzdoPat = .some(nil); return nil }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
        if done.wait(timeout: .now() + 5) == .timedOut { p.terminate(); cachedAzdoPat = .some(nil); return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let result = out.isEmpty ? nil : out
        cachedAzdoPat = .some(result)
        return result
    }

    /// 确保 mainRepo 是可用的 git clone；不存在则自动 clone（自动模式的首个 job / 手动配了路径但没 clone）。
    static func ensureRepoCloned(repo: String, provider: String?, prUrl: String?, mainRepo: String) async -> CloneOutcome {
        if FileManager.default.fileExists(atPath: mainRepo + "/.git") {
            return CloneOutcome(ok: true)
        }
        guard let url = deriveCloneUrl(repo: repo, provider: provider, prUrl: prUrl) else {
            return CloneOutcome(ok: false, detail:
                "无法从派单信息推导 \(repo) 的远端地址(pr_url 缺失/异常)。请手动 clone 后在设置里为该项目填写本机路径。")
        }
        try? FileManager.default.createDirectory(
            atPath: (mainRepo as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        LogStore.shared.log("auto-clone \(repo) ← \(url) → \(mainRepo)")

        let noPrompt = ["GIT_TERMINAL_PROMPT": "0"]
        func rmPartial() { try? FileManager.default.removeItem(atPath: mainRepo) }
        var r: ProcessResult

        if provider == "azdo" {
            var authArgs: [String] = []
            var authHeader = ""
            if let pat = azdoPat() {
                authHeader = "AUTHORIZATION: Basic " + Data(":\(pat)".utf8).base64EncodedString()
                authArgs = ["-c", "http.extraheader=\(authHeader)"]
            }
            // --filter=blob:none 大仓库快得多; 老 ADO Server 不支持时服务端自动忽略。
            r = await ProcessRunner.run("git", authArgs + ["clone", "--filter=blob:none", url, mainRepo], extraEnv: noPrompt)
            if r.code != 0 {
                rmPartial()
                r = await ProcessRunner.run("git", authArgs + ["clone", url, mainRepo], extraEnv: noPrompt)
            }
            if r.code == 0, !authHeader.isEmpty {
                // 认证头写进该 repo 本地配置: 之后的 fetch / worktree 操作(含 refs/pull 兜底)同样免交互。
                _ = await ProcessRunner.run("git", ["-C", mainRepo, "config", "http.extraheader", authHeader])
                LogStore.shared.log("auto-clone: 已用 AZURE_DEVOPS_EXT_PAT 认证并写入该 repo 的 http.extraheader(后续 fetch 免交互)")
            }
        } else {
            // github 优先 gh(用成员已登录的 gh 鉴权, 私有仓库无需另配凭证); 无 gh/失败再回退裸 git。
            r = await ProcessRunner.run("gh", ["repo", "clone", repo, mainRepo, "--", "--filter=blob:none"], extraEnv: noPrompt)
            if r.code != 0 {
                rmPartial()
                r = await ProcessRunner.run("git", ["clone", url, mainRepo], extraEnv: noPrompt)
            }
        }
        if r.code != 0 {
            rmPartial()
            let errTail = String((r.stdout + r.stderr).suffix(1500))
            LogStore.shared.log("auto-clone \(repo) 失败(exit=\(r.code)): \(String(errTail.suffix(300)).replacingOccurrences(of: "\n", with: " "))")
            return CloneOutcome(ok: false, detail:
                "自动 clone 失败(\(url)):\n" + errTail + "\n"
                + "请确认本机对该仓库有访问权限(github 需 gh auth login; ADO 需 AZURE_DEVOPS_EXT_PAT 或 git 凭证), 或手动 clone 后在设置里为该项目填写本机路径。")
        }
        LogStore.shared.log("auto-clone \(repo) 完成")
        return CloneOutcome(ok: true, cloned: true)
    }
}

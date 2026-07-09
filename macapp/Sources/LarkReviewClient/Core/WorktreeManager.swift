import Foundation

/// worktree 管理（逐行复刻 Node 版 ensureWorktree/removeWorktree/pruneStaleWorktrees，
/// 原始出处是服务端 worker.sh STAGE 6）。所有 git 命令带 GIT_LFS_SKIP_SMUDGE=1
/// （ProcessRunner 统一注入），只拉源码不拉 LFS 大文件。
enum WorktreeManager {

    struct EnsureResult {
        var worktreePath: String
        var ok: Bool
        var detail: String
    }

    static func ensureWorktree(
        mainRepo: String, worktreeBase: String, prNum: Int, branch: String?, provider: String?
    ) async -> EnsureResult {
        let worktreePath = worktreeBase + "/pr-\(prNum)"
        let branch = branch ?? ""
        let exists = FileManager.default.fileExists(atPath: worktreePath)
        var r: ProcessResult

        if exists {
            LogStore.shared.log("worktree exists, refreshing to origin/\(branch)")
            _ = await ProcessRunner.run("git", ["-C", mainRepo, "fetch", "origin", branch])
            r = await ProcessRunner.run("git", ["-C", worktreePath, "reset", "--hard", "origin/\(branch)"])
            if r.code == 0 {
                _ = await ProcessRunner.run("git", ["-C", worktreePath, "clean", "-fd"])
            }
        } else {
            LogStore.shared.log("creating worktree \(worktreePath)")
            _ = await ProcessRunner.run("git", ["-C", mainRepo, "fetch", "origin", branch])
            r = await ProcessRunner.run("git", ["-C", mainRepo, "worktree", "add", worktreePath, branch])
            if r.code != 0 {
                r = await ProcessRunner.run("git", ["-C", mainRepo, "worktree", "add", "--detach", worktreePath, "origin/\(branch)"])
            }
        }

        // Azure DevOps 兜底：按源分支名 fetch 失败（分支名带特殊字符/权限差异）时，
        // 改用 ADO 发布的 PR 合并引用 refs/pull/<id>/merge（等价 GitHub 的 pull/N/merge）。
        if r.code != 0, provider == "azdo" {
            LogStore.shared.log("azdo fallback: fetch refs/pull/\(prNum)/merge")
            let f = await ProcessRunner.run("git", ["-C", mainRepo, "fetch", "origin", "refs/pull/\(prNum)/merge"])
            if f.code == 0 {
                if FileManager.default.fileExists(atPath: worktreePath) {
                    r = await ProcessRunner.run("git", ["-C", worktreePath, "reset", "--hard", "FETCH_HEAD"])
                    if r.code == 0 {
                        _ = await ProcessRunner.run("git", ["-C", worktreePath, "clean", "-fd"])
                    }
                } else {
                    r = await ProcessRunner.run("git", ["-C", mainRepo, "worktree", "add", "--detach", worktreePath, "FETCH_HEAD"])
                }
            }
        }

        return EnsureResult(worktreePath: worktreePath, ok: r.code == 0, detail: r.stdout + r.stderr)
    }

    static func removeWorktree(mainRepo: String, worktreeBase: String, prNum: Int) async {
        let worktreePath = worktreeBase + "/pr-\(prNum)"
        guard FileManager.default.fileExists(atPath: worktreePath) else { return }
        LogStore.shared.log("removing worktree \(worktreePath)")
        let r = await ProcessRunner.run("git", ["-C", mainRepo, "worktree", "remove", "--force", worktreePath])
        if r.code != 0 {
            try? FileManager.default.removeItem(atPath: worktreePath)
        }
        _ = await ProcessRunner.run("git", ["-C", mainRepo, "worktree", "prune"])
    }

    /// 定期清理超过 N 天没动过的 pr-* worktree。
    static func pruneStaleWorktrees(repos: [String: RepoConfig], maxAgeDays: Int) async {
        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86400)
        let fm = FileManager.default
        for (repo, conf) in repos {
            guard let entries = try? fm.contentsOfDirectory(atPath: conf.worktreeBase) else { continue }
            for name in entries {
                guard name.range(of: #"^pr-\d+$"#, options: .regularExpression) != nil else { continue }
                let p = conf.worktreeBase + "/" + name
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue,
                      let attrs = try? fm.attributesOfItem(atPath: p),
                      let mtime = attrs[.modificationDate] as? Date, mtime < cutoff else { continue }
                LogStore.shared.log("pruning stale worktree \(p) (repo \(repo))")
                let r = await ProcessRunner.run("git", ["-C", conf.mainRepo, "worktree", "remove", "--force", p])
                if r.code != 0 {
                    try? fm.removeItem(atPath: p)
                }
                _ = await ProcessRunner.run("git", ["-C", conf.mainRepo, "worktree", "prune"])
            }
        }
    }
}

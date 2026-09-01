import Foundation

/// worktree 管理（逐行复刻 Node 版 ensureWorktree/removeWorktree/pruneStaleWorktrees，
/// 原始出处是服务端 worker.sh STAGE 6）。所有 git 命令带 GIT_LFS_SKIP_SMUDGE=1
/// （ProcessRunner 统一注入），只拉源码不拉 LFS 大文件。
/// 建树一律 `worktree add --detach origin/<branch>`，不用本地分支：本地分支只靠工作树里那句
/// `reset --hard origin/<branch>` 推进，而重建的前提正是那句挂了 → `add <path> <branch>` 会静默
/// 检出一个旧 commit 并返回成功，拿旧代码跑完整 review 发到 PR（比响亮失败更糟）。
enum WorktreeManager {

    struct EnsureResult {
        var worktreePath: String
        var ok: Bool
        var detail: String
        /// 本次评审的 head（worktree 已 reset 到该 PR 分支最新提交）：同 head 重复派单去重 + 日志头标注。
        var head: String = ""
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
            } else {
                // 刷新失败多半是工作树本身坏了，最常见的是主仓 .git/worktrees/<name> admin 目录被
                // 并发的 worktree remove/prune 清掉：目录还在但已不是 git 仓库 → reset 永远 fatal，
                // 该 PR 每次重派都必然失败（2026-09-01 PR #916 实测，连续重派全挂在这里）。
                // 删掉重建，别让一次损坏把这个 PR 永久卡死。
                LogStore.shared.log("worktree 刷新失败, 删除后重建: " + LogStore.oneLine(r.stdout + r.stderr))
                try? FileManager.default.removeItem(atPath: worktreePath)
                _ = await ProcessRunner.run("git", ["-C", mainRepo, "worktree", "prune"])
                r = await ProcessRunner.run("git", ["-C", mainRepo, "worktree", "add", "--detach", worktreePath, "origin/\(branch)"])
            }
        } else {
            LogStore.shared.log("creating worktree \(worktreePath)")
            _ = await ProcessRunner.run("git", ["-C", mainRepo, "fetch", "origin", branch])
            r = await ProcessRunner.run("git", ["-C", mainRepo, "worktree", "add", "--detach", worktreePath, "origin/\(branch)"])
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

        var head = ""
        if r.code == 0 {
            let h = await ProcessRunner.run("git", ["-C", worktreePath, "rev-parse", "HEAD"])
            if h.code == 0 { head = h.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return EnsureResult(worktreePath: worktreePath, ok: r.code == 0, detail: r.stdout + r.stderr, head: head)
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

import Foundation
import AppKit

/// Mac app 从源码本地编译，"更新" = git pull + make bundle 重编译 + 重启。
/// 由菜单栏「更新并重启」按钮(一键)或配置「空闲时自动更新」触发。全程用 ProcessRunner 跑 git/make。
enum SelfUpdater {

    /// 下载安装(dmg)版的升级引导页(GitHub Releases)。
    static let releasesURL = URL(string: "https://github.com/TommyZhao888/lark-review-client/releases/latest")!

    /// 是否"源码(git clone)安装"——只有这种才能源码式自更新(git pull + make bundle)。
    /// dmg/下载安装没有 git 仓库, 应引导去 Releases 下新包, 而不是尝试本地编译。
    static func isGitInstall() -> Bool {
        guard let root = repoRoot() else { return false }
        return FileManager.default.fileExists(atPath: root + "/.git")
    }

    /// 定位仓库根目录：app bundle 在 <root>/macapp/build/LarkReviewClient.app，
    /// 故向上找到含 `macapp/Makefile` 的目录即根。开发(swift run)下也尽量兜住。
    static func repoRoot() -> String? {
        let fm = FileManager.default
        var start = Bundle.main.bundlePath
        if start.isEmpty { start = CommandLine.arguments.first ?? FileManager.default.currentDirectoryPath }
        var dir = URL(fileURLWithPath: start)
        for _ in 0..<8 {
            if fm.fileExists(atPath: dir.path + "/macapp/Makefile") { return dir.path }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }   // 到根了
            dir = parent
        }
        return nil
    }

    /// 自更新前置条件检查。返回 nil = OK，否则给出原因文案。
    static func preflight(_ root: String) -> String? {
        if !FileManager.default.fileExists(atPath: root + "/.git") {
            return "客户端目录不是 git 仓库(\(root))，无法自动更新；请手动 git pull + make bundle。"
        }
        for cmd in ["git", "make", "swift"] where ProcessRunner.resolveExecutable(cmd) == nil {
            return "找不到 \(cmd)，无法本地编译更新；请装好 Xcode 命令行工具或手动更新。"
        }
        return nil
    }

    struct UpdateOutcome { var ok: Bool; var changed: Bool; var message: String }

    /// 执行更新：git pull --ff-only →（有变化时）make bundle → 重启。
    /// onStep 回报步骤文案（非主线程调用，调用方自行切主线程更新 UI）。
    /// 返回结果；ok && changed 时已触发重启（进程即将退出）。
    static func run(onStep: @escaping (String) -> Void) async -> UpdateOutcome {
        guard let root = repoRoot() else {
            return UpdateOutcome(ok: false, changed: false, message: "定位不到客户端源码目录，无法自动更新；请手动更新。")
        }
        if let err = preflight(root) {
            return UpdateOutcome(ok: false, changed: false, message: err)
        }

        onStep("git pull…")
        let before = await ProcessRunner.run("git", ["-C", root, "rev-parse", "HEAD"])
        let pull = await ProcessRunner.run("git", ["-C", root, "pull", "--ff-only"])
        if pull.code != 0 {
            let detail = String((pull.stdout + pull.stderr).trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))
            return UpdateOutcome(ok: false, changed: false, message: "git pull 失败: \(detail)")
        }
        let after = await ProcessRunner.run("git", ["-C", root, "rev-parse", "HEAD"])
        let beforeSha = before.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let afterSha = after.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !beforeSha.isEmpty, beforeSha == afterSha {
            return UpdateOutcome(ok: true, changed: false, message: "已是最新，无需更新。")
        }

        onStep("make bundle 编译中…")
        let build = await ProcessRunner.run("make", ["-C", root + "/macapp", "bundle"])
        if build.code != 0 {
            let detail = String((build.stdout + build.stderr).trimmingCharacters(in: .whitespacesAndNewlines).suffix(500))
            return UpdateOutcome(ok: false, changed: true, message: "编译失败(代码已拉取但未生效): \(detail)")
        }

        onStep("重启中…")
        await relaunch(appPath: root + "/macapp/build/LarkReviewClient.app")
        return UpdateOutcome(ok: true, changed: true, message: "更新完成，正在重启…")
    }

    /// 脱离当前进程重启：起一个 detached shell，等本进程退出后 `open` 新 app，然后本进程退出。
    @MainActor
    private static func relaunch(appPath: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"\(appPath)\""]
        try? p.run()   // detached，不等待
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }
}

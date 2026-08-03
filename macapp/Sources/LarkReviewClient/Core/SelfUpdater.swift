import Foundation
import AppKit

/// 自更新（任意安装位置可用）：从 GitHub Releases 下载目标版本 dmg →
/// 取出新 .app → 原地替换正在运行的 bundle → 重启。
/// 由菜单栏「更新并重启」按钮(一键)或配置「空闲时自动更新」触发。
/// 目标版本来自服务端 register_ack 的 upgrade.recommended，缺失时回退查 Releases 最新 tag。
enum SelfUpdater {

    /// Releases 页（更新失败时的手动逃生口）。
    static let releasesURL = URL(string: "https://github.com/TommyZhao888/lark-review-client/releases/latest")!

    /// recommended 缺失时回退查最新 release 的 API。
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/TommyZhao888/lark-review-client/releases/latest")!

    /// dmg 附件命名与 .github/workflows/release.yml 的「编译 + 打 DMG」步骤是契约，两边同步改。
    static func dmgURL(version: String) -> URL {
        URL(string: "https://github.com/TommyZhao888/lark-review-client/releases/download/v\(version)/LarkReviewClient-v\(version).dmg")!
    }

    struct UpdateOutcome {
        var ok: Bool
        var changed: Bool
        var message: String
        /// true = 未遂而非失败（安装包未就绪/更新中来单），自动更新允许下次重连再试。
        var retryable: Bool = false
    }

    /// dmg 下载进度：只有下载阶段有，其余阶段回报 nil（UI 画不定进度小转圈）。
    struct DownloadProgress: Equatable {
        var received: Int64
        var total: Int64          // 服务器未给 Content-Length 时为 0
        var fraction: Double?     // total>0 时 0...1；未知时 nil（UI 不画确定进度条）
    }

    // ---------- 纯函数（无网络/Bundle 依赖，供单测） ----------

    /// 去空白、去可选 v/V 前缀；空串返回 nil。
    static func normalizeVersion(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        return v.isEmpty ? nil : v
    }

    /// 解析 GitHub API releases/latest 响应的 tag_name（如 "v1.5.3"）；解析失败返回 nil。
    static func latestTag(fromJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["tag_name"] as? String
    }

    /// 已下载/总大小 → 0...1（越界夹回）；total 未知(≤0) 或 received<0 时返回 nil = 画不定进度。
    static func fraction(received: Int64, total: Int64) -> Double? {
        guard total > 0, received >= 0 else { return nil }
        return min(1.0, Double(received) / Double(total))
    }

    /// 字节数人读文案：≥1MB → "12.3 MB"，否则 "870 KB"
    /// （ByteCountFormatter 随系统语言/进制变体太多，进度条文案要稳定所以手写）。
    static func formatBytes(_ n: Int64) -> String {
        let bytes = max(0, n)
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", (Double(bytes) / 1024).rounded())
    }

    /// 进度副文案："12.3 MB / 29.4 MB"；total 未知时只给已下载量。
    static func progressText(received: Int64, total: Int64) -> String {
        total > 0 ? "\(formatBytes(received)) / \(formatBytes(total))" : formatBytes(received)
    }

    /// Gatekeeper 把带 quarantine 的 app 搬去只读随机挂载点运行——该路径不可原地替换。
    static func isTranslocated(_ bundlePath: String) -> Bool {
        bundlePath.contains("/AppTranslocation/")
    }

    /// 拆出替换目标 (.app 完整路径, 其父目录)；swift run 开发态（非 .app）返回 nil。
    static func installDestination(bundlePath: String) -> (dest: String, parent: String)? {
        guard bundlePath.hasSuffix(".app") else { return nil }
        let url = URL(fileURLWithPath: bundlePath)
        return (url.path, url.deletingLastPathComponent().path)
    }

    /// 校验新 app 的 Info.plist：bundle id 必须是本 app、版本必须等于期望版本。
    /// 这是防「忘 bump 版本 → 替换后仍旧版 → 服务端再推荐 → 无限更新重启循环」的关键防线。
    static func verifyStagedPlist(_ plist: [String: Any], expectVersion: String) -> String? {
        let bundleId = plist["CFBundleIdentifier"] as? String ?? "(缺失)"
        guard bundleId == "com.larkbot.review-client-app" else {
            return "安装包 bundle id(\(bundleId)) 不是本 app，已中止"
        }
        let version = plist["CFBundleShortVersionString"] as? String ?? "(缺失)"
        guard version == expectVersion else {
            return "安装包版本(\(version))与期望(\(expectVersion))不符，已中止；请联系发版人"
        }
        return nil
    }

    /// 同卷两步 rename 换血：dest→aside、newApp→dest（失败则 aside→dest 回滚）。
    /// aside 必须与 dest 同卷（rename 才原子）。返回 nil = 成功。
    static func swapBundle(newApp: String, dest: String, aside: String) -> String? {
        let fm = FileManager.default
        do {
            try fm.moveItem(atPath: dest, toPath: aside)
        } catch {
            return "移开旧版本失败: \(error.localizedDescription)"
        }
        do {
            try fm.moveItem(atPath: newApp, toPath: dest)
        } catch {
            let reason = error.localizedDescription
            do {
                try fm.moveItem(atPath: aside, toPath: dest)
                return "安装新版本失败(已回滚到旧版本): \(reason)"
            } catch {
                return "安装新版本失败且回滚失败！旧版本还在 \(aside)，请手动移回 \(dest)。原因: \(reason)"
            }
        }
        try? fm.removeItem(atPath: aside)   // 删不掉也无害（在系统临时目录，运行中的旧进程不受影响）
        return nil
    }

    // ---------- 前置检查 ----------

    /// 自更新前置条件检查。返回 nil = OK，否则给出原因文案。
    static func preflight(bundlePath: String) -> String? {
        if isTranslocated(bundlePath) {
            return "app 正运行在系统隔离副本(App Translocation)中，无法原地更新；请把 App 放到「应用程序」后执行 xattr -dr com.apple.quarantine /Applications/LarkReviewClient.app 再重新打开。"
        }
        guard let (dest, parent) = installDestination(bundlePath: bundlePath) else {
            return "开发模式（非 .app）运行，无法原地替换；请用打包后的 app。"
        }
        if bundlePath.hasPrefix("/Volumes/") {
            return "你正在从 dmg 挂载卷内直接运行，请先把 App 拖进「应用程序」再更新。"
        }
        let fm = FileManager.default
        if !fm.isWritableFile(atPath: parent) || !fm.isWritableFile(atPath: dest) {
            return "当前账户无权写入 \(parent)，无法自动替换；请手动下载安装。"
        }
        return nil
    }

    // ---------- 主流程 ----------

    /// 执行更新：定版本 → 下载 dmg → 挂载取 app → 校验 → 原地替换 → 重启。
    /// onStatus 回报「步骤文案 + 下载进度(仅下载阶段有)」的完整快照（非主线程调用，
    /// 调用方自行切主线程更新 UI；后到的快照覆盖先到的，不会出现阶段与进度错配的拼接态）。
    /// 返回结果；ok && changed 时已触发重启（进程即将退出）。
    static func run(targetVersion: String?,
                    onStatus: @escaping (String, DownloadProgress?) -> Void) async -> UpdateOutcome {
        let sessionConfig: URLSessionConfiguration = {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 60
            cfg.timeoutIntervalForResource = 600
            return cfg
        }()
        let session = URLSession(configuration: sessionConfig)

        // 1. 定版本：服务端 recommended 优先（服务端可固定推荐某 tag），缺失回退查最新 release。
        var version = normalizeVersion(targetVersion)
        if version == nil {
            onStatus("查询最新版本…", nil)
            if let (data, resp) = try? await session.data(from: latestReleaseAPI),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                version = normalizeVersion(latestTag(fromJSON: data))
            }
        }
        guard let version else {
            return UpdateOutcome(ok: false, changed: false, message: "无法确定目标版本（服务端未下发且查询最新版本失败），请到 Releases 手动下载。")
        }

        // 2. 已是最新短路。
        if version == CLIENT_VERSION {
            return UpdateOutcome(ok: true, changed: false, message: "已是最新，无需更新。")
        }

        // 3. 前置检查。
        let bundlePath = Bundle.main.bundlePath
        if let err = preflight(bundlePath: bundlePath) {
            return UpdateOutcome(ok: false, changed: false, message: err)
        }
        let (dest, parent) = installDestination(bundlePath: bundlePath)!   // preflight 已保证

        // 工作目录 + 挂载点；任何失败分支统一 cleanup。
        let fm = FileManager.default
        let workdir = fm.temporaryDirectory.appendingPathComponent("lrc-update-\(UUID().uuidString)").path
        let mnt = workdir + "/mnt"
        var mounted = false
        func cleanup() async {
            if mounted { await detach(mnt); mounted = false }
            try? fm.removeItem(atPath: workdir)
        }
        do {
            try fm.createDirectory(atPath: mnt, withIntermediateDirectories: true)
        } catch {
            return UpdateOutcome(ok: false, changed: false, message: "创建临时目录失败: \(error.localizedDescription)")
        }

        // 4. 下载 dmg。LARK_REVIEW_UPDATE_DMG_URL 为 e2e 测试钩子（本地假 hub + 假包）。
        //    dmg 是整个更新里最慢的一步 → 回报确定进度，UI 画进度条。
        let downloadStep = "下载 v\(version) 安装包…"
        onStatus(downloadStep, nil)
        let url = ProcessInfo.processInfo.environment["LARK_REVIEW_UPDATE_DMG_URL"]
            .flatMap { URL(string: $0) } ?? dmgURL(version: version)
        let dmgPath = workdir + "/update.dmg"
        do {
            let downloader = DMGDownloader(destPath: dmgPath) { received, total in
                onStatus(downloadStep, DownloadProgress(received: received, total: total,
                                                        fraction: fraction(received: received, total: total)))
            }
            let status = try await downloader.run(url: url, config: sessionConfig)
            if status == 404 {
                await cleanup()
                return UpdateOutcome(ok: false, changed: false,
                    message: "未找到 v\(version) 安装包（可能还在构建中，CI 未完成），稍后重试或手动下载。URL: \(url.absoluteString)",
                    retryable: true)
            }
            guard status == 200 else {
                await cleanup()
                return UpdateOutcome(ok: false, changed: false, message: "下载安装包失败(HTTP \(status)): \(url.absoluteString)")
            }
            let bytes = ((try? fm.attributesOfItem(atPath: dmgPath))?[.size] as? NSNumber)?.int64Value ?? 0
            LogStore.shared.log("self-update: 安装包下载完成 \(formatBytes(bytes))")
        } catch {
            await cleanup()
            return UpdateOutcome(ok: false, changed: false, message: "下载安装包失败: \(error.localizedDescription)")
        }

        // 5. 挂载（UDZO checksum 校验自动兜住下载损坏，勿加 -noverify）。
        onStatus("解包安装包…", nil)
        let attach = await ProcessRunner.run("/usr/bin/hdiutil",
            ["attach", dmgPath, "-nobrowse", "-readonly", "-mountpoint", mnt])
        if attach.code != 0 {
            let detail = String((attach.stdout + attach.stderr).trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))
            await cleanup()
            return UpdateOutcome(ok: false, changed: false, message: "安装包损坏或无法挂载: \(detail)")
        }
        mounted = true

        // 6. 找出 dmg 里的 .app（不写死名字，容忍未来改名）。
        guard let appName = (try? fm.contentsOfDirectory(atPath: mnt))?.first(where: { $0.hasSuffix(".app") }) else {
            await cleanup()
            return UpdateOutcome(ok: false, changed: false, message: "安装包内没有找到 .app。")
        }

        // 7. 暂存到与安装目录同卷的临时目录（同卷保证 rename 原子；ditto 保 symlink/xattr/签名）。
        onStatus("安装新版本…", nil)
        let stagingDir: String
        do {
            stagingDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: URL(fileURLWithPath: parent), create: true).path
        } catch {
            await cleanup()
            return UpdateOutcome(ok: false, changed: false, message: "创建暂存目录失败: \(error.localizedDescription)")
        }
        func cleanupStaging() { try? fm.removeItem(atPath: stagingDir) }
        let staged = stagingDir + "/LarkReviewClient-new.app"
        let dittoResult = await ProcessRunner.run("/usr/bin/ditto", [mnt + "/" + appName, staged])
        if dittoResult.code != 0 {
            let detail = String((dittoResult.stdout + dittoResult.stderr).trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))
            cleanupStaging(); await cleanup()
            return UpdateOutcome(ok: false, changed: false, message: "拷贝新版本失败: \(detail)")
        }

        // 8. 校验：bundle id + 版本（防死循环）+ 架构。
        if let err = await verifyStagedApp(staged, expectVersion: version) {
            cleanupStaging(); await cleanup()
            return UpdateOutcome(ok: false, changed: false, message: err)
        }

        // 9. 防御性去 quarantine（环境不可控时可能被补打；best-effort）+ 签名完整性。
        _ = await ProcessRunner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged])
        let sign = await ProcessRunner.run("/usr/bin/codesign", ["--verify", "--deep", staged])
        if sign.code != 0 {
            let detail = String((sign.stdout + sign.stderr).trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))
            cleanupStaging(); await cleanup()
            return UpdateOutcome(ok: false, changed: false, message: "新版本签名校验失败: \(detail)")
        }

        // 10. 换血前主动卸载 dmg、清下载目录（staging 不动）。
        await cleanup()

        // 11. 空闲复查：下载期间可能来了 review，宁可中止更新也不腰斩 review。
        let stillIdle = await MainActor.run {
            let s = AppRuntime.shared.state
            return s.runningJob == nil && s.queuedJobs.isEmpty
        }
        guard stillIdle else {
            cleanupStaging()
            return UpdateOutcome(ok: false, changed: false,
                message: "更新期间收到 review 任务，已中止更新；空闲后重试。", retryable: true)
        }

        // 12. 原地替换。
        onStatus("替换旧版本…", nil)
        let aside = stagingDir + "/LarkReviewClient-old.app"
        if let err = swapBundle(newApp: staged, dest: dest, aside: aside) {
            cleanupStaging()
            return UpdateOutcome(ok: false, changed: false, message: err)
        }
        cleanupStaging()

        // 13. 重启（进程即将退出）。
        onStatus("重启中…", nil)
        await relaunch(appPath: dest)
        return UpdateOutcome(ok: true, changed: true, message: "更新完成，正在重启…")
    }

    /// 读 staged app 的 Info.plist 做校验，另用 lipo 确认二进制含本机架构
    /// （CI 产物为 arm64 单架构，防止把能跑的旧版换成跑不起来的新版）。
    private static func verifyStagedApp(_ appPath: String, expectVersion: String) async -> String? {
        guard let data = FileManager.default.contents(atPath: appPath + "/Contents/Info.plist"),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return "读取新版本 Info.plist 失败，已中止。"
        }
        if let err = verifyStagedPlist(plist, expectVersion: expectVersion) { return err }

        let exeName = plist["CFBundleExecutable"] as? String ?? "LarkReviewClient"
        #if arch(arm64)
        let requiredArch = "arm64"
        #else
        let requiredArch = "x86_64"
        #endif
        let lipo = await ProcessRunner.run("/usr/bin/lipo", ["-archs", appPath + "/Contents/MacOS/" + exeName])
        if lipo.code == 0, !lipo.stdout.contains(requiredArch) {
            return "新版本不含本机架构(\(requiredArch))，已中止；实际: \(lipo.stdout.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return nil
    }

    /// 卸载挂载点：失败重试 2 次后 -force，仍失败仅记日志（残留挂载无害，重启消失）。
    private static func detach(_ mountPoint: String) async {
        for attempt in 0..<3 {
            let args = attempt < 2 ? ["detach", mountPoint] : ["detach", mountPoint, "-force"]
            let r = await ProcessRunner.run("/usr/bin/hdiutil", args)
            if r.code == 0 { return }
            try? await Task.sleep(for: .seconds(1))
        }
        LogStore.shared.log("self-update: hdiutil detach \(mountPoint) 失败(已忽略，重启后自动消失)")
    }

    /// 脱离当前进程重启：detached shell 等旧进程真正退出后再 open 新 app
    /// （直接 sleep 固定秒数会踩「open 只 activate 将死的旧实例 → 零实例」竞态）。
    /// 不注册 ChildProcessRegistry——shutdown 的 terminateAll 会把接力进程杀掉。
    @MainActor
    static func relaunch(appPath: String) {
        LogStore.shared.log("self-update: 即将重启到 \(appPath)")
        AppRuntime.shared.notifications.notify("🆙 正在更新客户端", "即将自动重启；若 10 秒内未重启请手动打开 App")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c",
            "i=0; while kill -0 \"$1\" 2>/dev/null && [ \"$i\" -lt 150 ]; do sleep 0.2; i=$((i+1)); done; sleep 0.3; " +
            "open \"$2\" || echo \"[self-update] relaunch FAILED: $2\" >> \"$HOME/.lark-review-client.log\"",
            "_", String(ProcessInfo.processInfo.processIdentifier), appPath]
        try? p.run()   // detached，不等待
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    /// 带进度回报的 dmg 下载：session 级 delegate + downloadTask + continuation。
    /// 为什么不用更短的 `session.download(from:delegate:)`：实测（macOS 27）传给它的
    /// per-task delegate 收不到 didWriteData 进度回调（下载能成功但一次进度都不报），
    /// 只有把 delegate 挂在 session 上才有进度。改回便捷 API 前请先验证进度是否还在。
    /// 回调落在 session 的串行 delegate 队列上，故 @unchecked Sendable、内部状态无需加锁；
    /// 进度节流到「百分点变化 或 ≥200ms」一次——不节流会几十 KB 一次地刷 MainActor。
    private final class DMGDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destPath: String
        private let onProgress: (Int64, Int64) -> Void
        private var session: URLSession?
        private var continuation: CheckedContinuation<Int, Error>?
        private var status = -1
        private var moveError: Error?
        private var finished = false            // 防重复 resume（invalidate 后还会来 didBecomeInvalid）
        private var lastPercent = -1
        private var lastAt = Date.distantPast
        private var loggedTotal = false

        init(destPath: String, onProgress: @escaping (Int64, Int64) -> Void) {
            self.destPath = destPath
            self.onProgress = onProgress
        }

        /// 下载到 destPath；返回 HTTP 状态码（404/非 200 由调用方给文案），网络层失败抛错。
        func run(url: URL, config: URLSessionConfiguration) async throws -> Int {
            try await withCheckedThrowingContinuation { cont in
                continuation = cont           // 必在 resume() 之前设好，回调才有 continuation 可用
                let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                session = s
                s.downloadTask(with: url).resume()
            }
        }

        private func finish(_ result: Result<Int, Error>) {
            guard !finished else { return }
            finished = true
            let cont = continuation
            continuation = nil
            session?.finishTasksAndInvalidate()   // 断开 session 对 delegate(self) 的强引用
            session = nil
            switch result {
            case .success(let code): cont?.resume(returning: code)
            case .failure(let err): cont?.resume(throwing: err)
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64,
                        totalBytesWritten written: Int64,
                        totalBytesExpectedToWrite expected: Int64) {
            let total = expected > 0 ? expected : 0   // 未知长度(NSURLSessionTransferSizeUnknown=-1) → 0
            if !loggedTotal, total > 0 {
                loggedTotal = true
                LogStore.shared.log("self-update: 安装包大小 \(SelfUpdater.formatBytes(total))，开始下载")
            }
            let percent = total > 0 ? Int(Double(written) / Double(total) * 100) : -1
            let now = Date()
            guard percent != lastPercent || now.timeIntervalSince(lastAt) >= 0.2 else { return }
            lastPercent = percent
            lastAt = now
            onProgress(written, total)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
            // 本回调返回后临时文件即被删 → 必须在这里同步搬走。
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: destPath) { try fm.removeItem(atPath: destPath) }
                try fm.moveItem(atPath: location.path, toPath: destPath)
            } catch {
                moveError = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)); return }
            if let moveError { finish(.failure(moveError)); return }
            finish(.success(status))
        }
    }
}

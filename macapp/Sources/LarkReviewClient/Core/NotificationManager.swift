import Foundation
import UserNotifications

/// macOS 通知（对齐 Node notify()）：cfg.notify=false 时跳过，notifySound 可选。
/// 优先 UNUserNotificationCenter；授权被拒/异常时回退 osascript（Node 版同款）。
@MainActor
final class NotificationManager {

    var currentConfig: () -> Config = { Config() }
    /// 点了带公告 id 的系统通知 → 回调(打开公告详情窗口)。
    var onAnnouncementClicked: ((String) -> Void)?
    private(set) var authorized = false
    private var requested = false
    private let clickHandler = NotificationClickHandler()

    func requestAuthorization() {
        guard !requested else { return }
        requested = true
        clickHandler.onClick = { [weak self] id in self?.onAnnouncementClicked?(id) }
        UNUserNotificationCenter.current().delegate = clickHandler
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    /// 服务端公告的系统通知: 带公告 id, 点击回调 onAnnouncementClicked 打开详情窗口。
    /// 返回 false = 系统通知不可用(未授权/用户关了通知) —— 调用方应直接弹详情窗口, 保证看得到。
    /// osascript 兜底不用于公告: 那种通知点了只会打开「脚本编辑器」, 看不到全文。
    @discardableResult
    func notifyAnnouncement(_ a: Announcement) -> Bool {
        guard authorized, currentConfig().notify else { return false }
        notify((a.isImportant ? "⚠️ " : "📢 ") + a.title, a.message, announcementId: a.id)
        return true
    }

    func notify(_ title: String, _ message: String, announcementId: String? = nil) {
        let cfg = currentConfig()
        guard cfg.notify else { return }
        if authorized {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            if let id = announcementId { content.userInfo = ["announcement_id": id] }
            if !cfg.notifySound.isEmpty {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(cfg.notifySound))
            } else {
                content.sound = .default
            }
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req) { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in self?.osascriptNotify(title, message, sound: cfg.notifySound) }
            }
        } else {
            osascriptNotify(title, message, sound: cfg.notifySound)
        }
    }

    private func osascriptNotify(_ title: String, _ message: String, sound: String) {
        let esc = { (s: String) in
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: " ")
        }
        var script = "display notification \"\(esc(message))\" with title \"\(esc(title))\""
        if !sound.isEmpty { script += " sound name \"\(esc(sound))\"" }
        Task { _ = await ProcessRunner.run("/usr/bin/osascript", ["-e", script]) }
    }
}

/// UNUserNotificationCenter 代理: 点击通知时取出公告 id 回调; 前台时也照常弹横幅。
final class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    @MainActor var onClick: ((String) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["announcement_id"] as? String
        Task { @MainActor in
            if let id { self.onClick?(id) }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

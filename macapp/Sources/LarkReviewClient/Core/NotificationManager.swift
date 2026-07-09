import Foundation
import UserNotifications

/// macOS 通知（对齐 Node notify()）：cfg.notify=false 时跳过，notifySound 可选。
/// 优先 UNUserNotificationCenter；授权被拒/异常时回退 osascript（Node 版同款）。
@MainActor
final class NotificationManager {

    var currentConfig: () -> Config = { Config() }
    private var authorized = false
    private var requested = false

    func requestAuthorization() {
        guard !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    func notify(_ title: String, _ message: String) {
        let cfg = currentConfig()
        guard cfg.notify else { return }
        if authorized {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
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

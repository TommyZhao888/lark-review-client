import Foundation
import ServiceManagement

/// 开机自启（SMAppService 登录项，替代 Node 版的 launchd plist）。
/// ad-hoc 签名 + app 不在 /Applications 时可能 requiresApproval，UI 上显示状态并给提示。
@MainActor
enum LoginItemManager {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已启用"
        case .requiresApproval: return "待批准（系统设置 › 通用 › 登录项）"
        case .notRegistered: return "未启用"
        case .notFound: return "不可用（请把 app 移到 /Applications）"
        @unknown default: return "未知"
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

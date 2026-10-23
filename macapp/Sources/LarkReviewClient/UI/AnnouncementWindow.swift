import SwiftUI
import AppKit

/// 公告详情窗口: 点系统通知 / 面板横幅打开, 显示完整正文(系统通知只显示开头一段)。
/// 由 AppRuntime 等非视图代码直接调用, 故用 AppKit 窗口承载 SwiftUI 视图(单例复用, 只开一个)。
@MainActor
enum AnnouncementWindow {
    private static var window: NSWindow?

    static func show(_ a: Announcement, onDismiss: @escaping () -> Void) {
        let view = AnnouncementDetailView(announcement: a) {
            onDismiss()
            window?.close()
        }
        let w = window ?? {
            let nw = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            nw.isReleasedWhenClosed = false
            nw.center()
            return nw
        }()
        w.title = "服务端公告"
        w.contentViewController = NSHostingController(rootView: view)
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct AnnouncementDetailView: View {
    let announcement: Announcement
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(announcement.isImportant ? "⚠️ 重要" : "📢 公告")
                    .font(.caption.bold())
                    .foregroundStyle(announcement.isImportant ? .red : .accentColor)
                if let ts = announcement.ts, let d = ISO8601DateFormatter.lenient(ts) {
                    Text(d.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(announcement.title)
                .font(.title3.bold())
                .textSelection(.enabled)
            ScrollView {
                Text(announcement.message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("知道了", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 260)
    }
}

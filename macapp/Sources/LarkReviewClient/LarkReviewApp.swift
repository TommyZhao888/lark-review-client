import SwiftUI

@main
struct LarkReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(AppRuntime.shared.state)
        } label: {
            Text(AppRuntime.shared.state.menuBarTitle)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(AppRuntime.shared.state)
        }

        Window("日志", id: "logs") {
            LogsView()
                .environment(AppRuntime.shared.state)
        }
        .defaultSize(width: 860, height: 560)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppRuntime.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppRuntime.shared.shutdown()
    }
}

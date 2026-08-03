import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 번들 없이(swift run) 실행해도 독 아이콘이 뜨지 않도록
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct VinceStatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            DashboardView()
                .environment(appState)
        } label: {
            MenuBarLabel(state: appState)
        }
        .menuBarExtraStyle(.window)
    }
}

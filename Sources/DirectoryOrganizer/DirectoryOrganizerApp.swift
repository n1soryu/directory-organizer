import AppKit
import SwiftUI
import UserNotifications

@main
struct DirectoryOrganizerApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    private let model = AppModel.shared

    var body: some Scene {
        // The dashboard: the detailed view of everything. Opens at launch.
        Window("Directory Organizer", id: "dashboard") {
            DashboardView()
                .environment(model)
        }
        .defaultSize(width: 1240, height: 780)
        // Don't let a tall page (Settings) grow the window; pages scroll instead.
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Now") { model.requestScan() }
                    .keyboardShortcut("r")
                Button("Approve All") { model.approveAll() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(model.pending.isEmpty || model.isApplying)
            }
        }

        // The menu-bar icon with the compact view.
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Notifier.isBundled {
            UNUserNotificationCenter.current().delegate = self
        }
        Task { @MainActor in
            #if DEBUG
            if DebugSnapshot.runIfRequested(model: AppModel.shared) { return }
            #endif
            AppModel.shared.start()
        }
    }

    /// Closing the dashboard leaves the app running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Show notifications even while the app is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking a notification opens the page it's about.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo["page"] as? String
        await MainActor.run {
            AppModel.shared.open(raw.flatMap(AppModel.Page.init(rawValue:)) ?? .overview)
        }
    }
}

#if DEBUG
import AppKit
import OrganizerCore
import SwiftUI

/// Development aid: renders every dashboard page to PNGs (light and dark) and quits,
/// without Screen Recording permission. Debug builds only.
///
///     DO_SNAPSHOT=/tmp/shots swift run DirectoryOrganizer
enum DebugSnapshot {
    /// Returns true if a snapshot run was started (the app then quits by itself).
    @MainActor static func runIfRequested(model: AppModel) -> Bool {
        if ProcessInfo.processInfo.environment["DO_E2E"] != nil {
            endToEnd(model: model)
            return true
        }
        guard let outDir = ProcessInfo.processInfo.environment["DO_SNAPSHOT"] else { return false }
        Task { @MainActor in
            model.start()
            // Wait for the dashboard window and the first scan.
            try? await Task.sleep(for: .seconds(1))
            while model.isScanning || model.lastScan == nil { try? await Task.sleep(for: .milliseconds(200)) }
            if let size = ProcessInfo.processInfo.environment["DO_WINDOW"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                window()?.setContentSize(NSSize(width: size[0], height: size[1]))
            }
            for page in AppModel.Page.allCases {
                model.page = page
                if page == .pending, let first = model.pending.first(where: { !$0.alerts.isEmpty }) ?? model.pending.first {
                    model.selection = [first.id]
                }
                try? await Task.sleep(for: .seconds(1))
                await capture(to: "\(outDir)/\(page.rawValue)")
                // Off-screen capture can't draw the translucent sidebar, so also report what the
                // tables and lists really contain.
                if let root = window()?.contentView {
                    let tables = Self.tables(in: root).map { "\(type(of: $0)):\($0.numberOfRows)" }
                    print("snapshot \(page.rawValue): tables \(tables.joined(separator: ", "))")
                }
            }
            await captureMenuBarView(model: model, to: "\(outDir)/menubar")
            model.organizeNow()
            // Early in the run: text recognition of the images is the slow part.
            while (model.organizing?.progress?.done ?? 0) < 2, model.organizing != nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await captureMenuBarView(model: model, to: "\(outDir)/menubar-running")
            model.cancelOrganize()
            NSApp.terminate(nil)
        }
        return true
    }

    /// `DO_E2E=1`: drives the app model like a user would, on the sandbox, and prints what happened:
    /// quick scan, Organize Now (and a cancelled one), approve all, a new download arrives
    /// (the watcher must notice), undo everything.
    @MainActor private static func endToEnd(model: AppModel) {
        func say(_ text: String) { print("e2e: \(text)"); fflush(stdout) }
        func settle() async {
            try? await Task.sleep(for: .milliseconds(500))
            while model.isScanning || model.isApplying { try? await Task.sleep(for: .milliseconds(200)) }
        }
        Task { @MainActor in
            model.settings.useModel = false   // fast and repeatable (a throwaway settings file)
            model.start()
            await settle()
            say("quick scan: \(model.pending.count) pending, \(model.waiting.count) waiting for Organize Now, \(model.alertActions.count) with alerts, watching=\(model.isWatching)")

            model.organizeNow()
            try? await Task.sleep(for: .milliseconds(300))
            model.cancelOrganize()
            while model.organizing != nil { try? await Task.sleep(for: .milliseconds(100)) }
            await settle()
            say("cancelled run: cancelled=\(model.lastFullRun?.cancelled == true), still waiting \(model.waiting.count)")

            model.organizeNow()
            var maxProgress = 0.0
            while model.organizing != nil {
                maxProgress = max(maxProgress, model.organizing?.fraction ?? 0)
                try? await Task.sleep(for: .milliseconds(100))
            }
            await settle()
            let secure = model.pending.first { $0.originalName == "IMG_5012.jpg" }?.destinationFolder ?? "-"
            say("Organize Now: progress reached \(Int(maxProgress * 100))%, \(model.lastFullRun?.text ?? "-"); now \(model.pending.count) pending, \(model.waiting.count) waiting; IMG_5012.jpg → \(secure)")

            model.reject([model.pending.first { $0.originalName == "notes.txt" }!.id])
            model.approveAll()
            await settle()
            say("approved: \(model.movedRecords.count) moved, \(model.pending.count) pending, \(model.rejected.count) rejected, review folder \(model.reviewItems.count)")

            let incoming = model.watchedURL.appending(path: "ECO204 Lecture 07.pdf")
            try? Data("%PDF-1.4 fake".utf8).write(to: incoming)
            // It's not a real PDF (just "%PDF-1.4 fake"), so it can't be read: it waits instead of
            // being filed by its name (unread isn't clean). Either way, the watcher saw it.
            @MainActor func found() -> String? {
                if let action = model.pending.first(where: { $0.originalName == incoming.lastPathComponent }) {
                    return "pending → \(action.destinationPath)"
                }
                return model.waiting.first { $0.name == incoming.lastPathComponent }.map { "waiting (\($0.reason))" }
            }
            for _ in 0..<60 where found() == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            await settle()
            say("watcher: new download \(found().map { "seen, \($0)" } ?? "NOT seen")")

            model.undo(model.movedRecords)
            await settle()
            say("undone: \(model.movedRecords.count) still moved, \(model.pending.count) pending again")
            try? FileManager.default.removeItem(at: incoming)
            say("activity log: \(model.activity.count) events, newest: \(model.activity.first?.text ?? "-")")
            NSApp.terminate(nil)
        }
    }

    /// The menu-bar popover can't be captured where it lives, so show the same view in a window.
    @MainActor private static func captureMenuBarView(model: AppModel, to basePath: String) async {
        let host = NSHostingView(rootView: MenuBarView().environment(model))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // ARC owns it; AppKit releasing it too would crash
        window.contentView = host
        window.orderFront(nil)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(for: .seconds(0.6))
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(basePath)-\(suffix).png"))
        }
        window.close()
    }

    @MainActor private static func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? [] + view.subviews.flatMap { tables(in: $0) }
    }

    @MainActor private static func window() -> NSWindow? {
        // The title follows the page ("Overview"...), so find the dashboard as the main-capable window.
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    @MainActor private static func capture(to basePath: String) async {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(for: .seconds(0.6))
            guard let window = window(), let view = window.contentView?.superview ?? window.contentView else { continue }
            view.layoutSubtreeIfNeeded()
            view.display()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: "\(basePath)-\(suffix).png"))
        }
        NSApp.appearance = nil
    }
}
#endif

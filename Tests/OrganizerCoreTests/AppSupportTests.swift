import Foundation
import Testing
@testable import OrganizerCore

/// The app's background logic: watching, auto-apply, reminders, settings, caching.
@Suite struct AppSupportTests {
    func action(_ source: DecisionSource, confidence: Double = 0.95, alerts: [Alert] = []) -> ProposedAction {
        ProposedAction(source: URL(filePath: "/tmp/x.mp4"), originalName: "x.mp4", sourceSize: 1, sourceModified: nil,
                       destinationFolder: "Movies/Films", finalName: "x.mp4", tags: [], confidence: confidence,
                       reason: "", decidedBy: source, alerts: alerts, createsFolders: [])
    }

    @Test func autoApplyIsOffByDefault() {
        #expect(!AutoApplyPolicy().allows(action(.rule("video"))))
    }

    @Test func autoApplyOnlyConfidentRuleDecisionsWithoutAlerts() {
        let policy = AutoApplyPolicy(enabled: ["films"])
        #expect(policy.allows(action(.rule("video"))))
        #expect(!policy.allows(action(.rule("image"))))                         // category not enabled
        #expect(!policy.allows(action(.rule("video"), confidence: 0.85)))      // not confident enough
        #expect(!policy.allows(action(.rule("video"), alerts: [Alert(.nameClash, "x")])))
        #expect(!policy.allows(action(.classifier("apple"))))                  // model: always asks
        #expect(!policy.allows(action(.safety("duplicate"))))                  // safety: always asks
        // Even with every category on.
        let all = AutoApplyPolicy(enabled: Set(AutoApplyPolicy.categories.map(\.id)))
        #expect(!all.allows(action(.classifier("apple"))))
        #expect(!all.allows(action(.safety("sensitive file"))))
    }

    @Test func reviewReminderEveryEightHoursWhileNotEmpty() {
        let now = Date()
        let eight: TimeInterval = 8 * 3600
        #expect(!ReviewReminder.isDue(itemCount: 0, lastSent: nil, now: now, interval: eight))
        #expect(ReviewReminder.isDue(itemCount: 2, lastSent: nil, now: now, interval: eight))
        #expect(!ReviewReminder.isDue(itemCount: 2, lastSent: now.addingTimeInterval(-7 * 3600), now: now, interval: eight))
        #expect(ReviewReminder.isDue(itemCount: 2, lastSent: now.addingTimeInterval(-8 * 3600), now: now, interval: eight))
        #expect(ReviewReminder.nextDue(lastSent: now.addingTimeInterval(-3600), now: now, interval: eight)
                == now.addingTimeInterval(7 * 3600))
    }

    @Test func settingsRoundTrip() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var settings = AppSettings(watchedFolder: "/tmp/in", homeRoot: "/tmp/home")
        settings.autoApply.enabled = ["films"]
        settings.lastReviewReminder = Date(timeIntervalSince1970: 1_800_000_000)
        settings.rejected = [FileIdentity(action(.rule("video")))]
        try settings.save(to: file)
        #expect(AppSettings.load(from: file) == settings)
        #expect(settings.journalURL.path == "/tmp/moves.jsonl")
        // A missing or broken file gives the defaults (the sandbox).
        #expect(AppSettings.load(from: file.appending(path: "missing")) == AppSettings())
    }

    /// HIGH-4: a rejection saved to disk must still match the unchanged file after a relaunch.
    @Test func aSavedRejectionStillMatchesTheFile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let precise = Date(timeIntervalSince1970: 1_800_000_000.734)   // file dates have fractions
        let identity = FileIdentity(path: "/tmp/x.pdf", size: 10, modified: precise)
        var settings = AppSettings(watchedFolder: "/tmp/in", homeRoot: "/tmp/home")
        settings.rejected = [identity]
        try settings.save(to: file)
        let reloaded = AppSettings.load(from: file).rejected
        #expect(reloaded.first?.modified != precise)          // the seconds-only format loses it…
        #expect(Set(reloaded).contains(identity))              // …but it's the same file
        #expect(identity != FileIdentity(path: "/tmp/x.pdf", size: 10, modified: precise.addingTimeInterval(1)))
    }

    @Test func settingsFromOlderVersionsStillLoad() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        // 0.5.0 settings: no realUseSince.
        try Data(#"""
            {"autoApply":{"enabled":["films"]},"homeRoot":"/tmp/home","notifyNewFiles":true,"rejected":[],
             "reviewReminderHours":8,"useModel":true,"watchedFolder":"/tmp/in","watching":true}
            """#.utf8).write(to: file)
        let settings = AppSettings.load(from: file)
        #expect(settings.homeRoot == "/tmp/home")
        #expect(settings.autoApply.enabled == ["films"])
        #expect(settings.realUseSince == nil)
    }

    @Test func realHomeKeepsItsMoveLogInApplicationSupport() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(MoveJournal.url(forHome: home).path
                == home.appending(path: "Library/Application Support/DirectoryOrganizer/moves.jsonl").path)
        let sandbox = AppSettings.sandboxRoot.appending(path: "Home")
        #expect(MoveJournal.url(forHome: sandbox).path == AppSettings.sandboxRoot.appending(path: "moves.jsonl").path)
    }

    @Test func realFoldersAreRecognized() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(FolderAccess.isRealUserFolder(home))
        #expect(FolderAccess.isRealUserFolder(home.appending(path: "Downloads")))
        #expect(FolderAccess.isRealUserFolder(home.appending(path: "Documents/University")))
        #expect(!FolderAccess.isRealUserFolder(AppSettings.sandboxRoot.appending(path: "Downloads")))
        #expect(!FolderAccess.isRealUserFolder(home.appending(path: "Developer")))
    }
}

@Suite struct FolderWatcherTests {
    @Test func noticesANewFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        actor Flag { var fired = false; func set() { fired = true } }
        let flag = Flag()
        let watcher = FolderWatcher(url: folder, latency: 0.2) { Task { await flag.set() } }
        #expect(watcher.start())
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(300))
        try Data("new download".utf8).write(to: folder.appending(path: "file.pdf"))
        for _ in 0..<50 where await !flag.fired {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await flag.fired)
    }

    @Test func refusesAMissingFolder() {
        let watcher = FolderWatcher(url: URL(filePath: "/nonexistent-\(UUID().uuidString)")) {}
        #expect(!watcher.start())
        #expect(!watcher.isRunning)
    }
}

import AppKit
import Foundation
import Observation
import OrganizerCore
import SwiftUI

/// Something that happened, for the activity feed.
struct ActivityEvent: Identifiable {
    enum Kind { case info, success, warning, error }

    let id = UUID()
    let date = Date()
    let kind: Kind
    let text: String

    var systemImage: String {
        switch kind {
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    var color: Color {
        switch kind {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

/// An Organize Now run in progress.
struct FullRun {
    let started = Date()
    var progress: Planner.Progress?

    /// 0...1, only ever growing.
    var fraction: Double { progress?.fraction ?? 0 }
}

/// How the last Organize Now run went.
struct FullRunSummary {
    let date: Date
    let duration: TimeInterval
    let files: Int
    let byRules: Int
    let bySafety: Int
    let byModel: Int
    let alerts: Int
    let toReview: Int
    let cancelled: Bool

    private var seconds: String { String(format: duration < 10 ? "%.1f" : "%.0f", duration) }

    var text: String {
        if cancelled { return "Cancelled after \(seconds) s" }
        return "\(files) files in \(seconds) s: \(byRules) by rules, \(bySafety) by safety checks, \(byModel) by the model; \(alerts) alert\(alerts == 1 ? "" : "s")"
    }
}

/// A file in the review folder, with why it's there (from the move log, if the app put it there).
struct ReviewItem: Identifiable {
    var id: String { url.path }
    let url: URL
    let size: Int64
    let added: Date?
    let reason: String?
    let record: MoveRecord?
}

/// All app state, and the only place that starts scans, moves and undos.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    enum Page: String, Hashable, CaseIterable, Identifiable {
        case overview, pending, alerts, history, review, folders, settings
        var id: Self { self }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .pending: "Pending Approval"
            case .alerts: "Alerts"
            case .history: "History"
            case .review: "Review Folder"
            case .folders: "Folders"
            case .settings: "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .overview: "gauge.with.dots.needle.33percent"
            case .pending: "tray.full"
            case .alerts: "exclamationmark.triangle"
            case .history: "clock.arrow.circlepath"
            case .review: "archivebox"
            case .folders: "folder"
            case .settings: "gearshape"
            }
        }
    }

    // MARK: State shown in the UI

    var settings: AppSettings { didSet { saveSettings() } }
    var page: Page = .overview
    var selection = Set<ProposedAction.ID>()

    /// The current plan, minus files you rejected.
    private(set) var pending: [ProposedAction] = []
    /// Files you rejected that are still in the watched folder.
    private(set) var rejected: [ProposedAction] = []
    private(set) var skipped: [SkippedItem] = []
    /// Files the quick scan couldn't decide: they wait for Organize Now.
    private(set) var waiting: [WaitingItem] = []
    /// Set while Organize Now runs.
    private(set) var organizing: FullRun?
    private(set) var lastFullRun: FullRunSummary?
    private(set) var records: [MoveRecord] = []
    private(set) var reviewItems: [ReviewItem] = []
    private(set) var folderOptions: [FolderOption] = []
    private(set) var activity: [ActivityEvent] = []

    private(set) var isScanning = false
    private(set) var isApplying = false
    private(set) var lastScan: Date?
    private(set) var lastScanDuration: TimeInterval?
    private(set) var isWatching = false
    /// nil when Apple's model is available, otherwise why not.
    private(set) var modelUnavailableReason: String?
    private(set) var modelSeesImages = false
    var notificationStatus: Notifier.Status = .unknown
    /// A message shown at the top of the dashboard until dismissed.
    var banner: ActivityEvent?

    /// Set by the first SwiftUI view that appears, so the app can open the dashboard
    /// (from a notification, or the menu) even when no window is showing.
    var openDashboardAction: (() -> Void)?

    // MARK: Derived

    var alertActions: [ProposedAction] { pending.filter { !$0.alerts.isEmpty } }
    var alertCount: Int { pending.reduce(0) { $0 + $1.alerts.count } }
    var movedRecords: [MoveRecord] { records.filter { $0.state == .moved } }
    var movedToday: Int { records.filter { $0.state == .moved && Calendar.current.isDateInToday($0.time) }.count }
    var watchedURL: URL { URL(filePath: settings.watchedFolder) }
    var homeURL: URL { URL(filePath: settings.homeRoot) }
    var reviewURL: URL { homeURL.appending(path: OrganizerConfig().reviewFolder) }
    var journal: MoveJournal { MoveJournal(url: settings.journalURL) }
    var nextReminder: Date {
        ReviewReminder.nextDue(lastSent: settings.lastReviewReminder, interval: settings.reviewReminderHours * 3600)
    }
    /// True while either folder is one of your real folders.
    var isUsingRealFolders: Bool {
        FolderAccess.isRealUserFolder(watchedURL) || FolderAccess.isRealUserFolder(homeURL)
    }
    var isRealUseOn: Bool { settings.realUseSince != nil }
    /// Real folders chosen without switching to real use (e.g. by editing the settings file):
    /// everything stops.
    var isLocked: Bool { isUsingRealFolders && !isRealUseOn }

    // MARK: Private

    private let notifier = Notifier()
    /// Results of the last Organize Now run, per file version. Quick scans reuse them, so
    /// the model's answers stay until the file changes or leaves the folder.
    private var deepResults: [FileIdentity: ProposedAction] = [:]
    /// Folders Organize Now unpacked (by path), with the moves planned for what's inside.
    /// Quick scans only see the folder, so they show these instead while they still apply.
    private var deepUnpacked: [String: [ProposedAction]] = [:]
    private var retryTask: Task<Void, Never>?
    /// Auto-apply as it was in the sandbox, restored when switching back to it.
    private var sandboxAutoApply: AutoApplyPolicy?
    /// What's known about your folders (purposes learned by Organize Now), kept on disk.
    private var profiles: [FolderProfile] = []
    var profileStore: ProfileStore { ProfileStore(forHome: homeURL) }
    private var organizeTask: Task<Void, Never>?
    private var watcher: FolderWatcher?
    private var scanRequested = false
    private var knownPendingIDs = Set<String>()
    private var notifiedAlertIDs = Set<String>()
    private var reminderTask: Task<Void, Never>?
    private var started = false
    private var reportedDamagedLines = 0

    /// Debug runs (DO_SNAPSHOT, DO_E2E) use a throwaway settings file, never yours.
    static let settingsURL: URL = {
        let env = ProcessInfo.processInfo.environment
        guard env["DO_SNAPSHOT"] != nil || env["DO_E2E"] != nil else { return AppSettings.defaultURL }
        let url = FileManager.default.temporaryDirectory.appending(path: "directory-organizer-debug-settings.json")
        try? FileManager.default.removeItem(at: url)
        return url
    }()

    private init() {
        settings = AppSettings.load(from: Self.settingsURL)
    }

    /// Called once at launch.
    func start() {
        guard !started else { return }
        started = true
        log(.info, "Directory Organizer started (sandbox: \(display(watchedURL)))")
        refreshModelStatus()
        reloadJournal()
        profiles = profileStore.load()
        refreshReviewFolder()
        updateWatcher()
        startReminderLoop()
        // Text recognition's first use can take ~26 s; get it out of the way now.
        Task.detached(priority: .utility) { await TextRecognition.warmUp() }
        Task {
            notificationStatus = await notifier.status()
            if notificationStatus == .notDetermined { notificationStatus = await notifier.requestAuthorization() }
        }
        requestScan()
    }

    // MARK: - Scanning

    /// Asks for a scan. If one is running, another runs right after it (changes are never missed,
    /// and a burst of changes causes at most one extra scan).
    func requestScan() {
        if isScanning || organizing != nil { scanRequested = true; return }
        // Claimed here, not when the task starts: a second request in the meantime must wait.
        isScanning = true
        Task { await runScans() }
    }

    /// Scans until no more were asked for meanwhile (a burst of changes: one extra scan at
    /// most). The caller has set `isScanning`; it's cleared here.
    private func runScans() async {
        defer { isScanning = false }
        repeat {
            scanRequested = false
            await scan()
        } while scanRequested && organizing == nil
    }

    private func scan() async {
        guard !isLocked else {
            show(.error, "Your real folders are locked; switch to them in Settings, or choose folders inside TestData.")
            return
        }
        guard FileManager.default.fileExists(atPath: watchedURL.path) else {
            show(.warning, "The watched folder doesn't exist: \(display(watchedURL)). Run `swift run make-testdata`.")
            return
        }
        let started = Date()

        // Quick scan: rules only, no text recognition, no model. Heavy work waits for Organize Now.
        var planner = Planner(homeRoot: homeURL, mode: .quick)
        planner.onlyAddedAfter = settings.realUseSince
        planner.profiles = profiles
        planner.corrections = Correction.from(records, homeRoot: homeURL)
        let plan: Plan
        do {
            plan = try await planner.plan(folder: watchedURL)
        } catch {
            show(.error, "Couldn't read \(display(watchedURL)): \(error.localizedDescription)")
            return
        }

        // Where Organize Now already analysed a file (and it hasn't changed), its result wins.
        let present = Set(plan.actions.map(FileIdentity.init) + plan.waiting.map(\.identity))
        deepResults = deepResults.filter { present.contains($0.key) }
        let waitingPaths = Set(plan.waiting.map(\.source.path))
        deepUnpacked = deepUnpacked.filter { waitingPaths.contains($0.key) }
        // An unpacked folder: its contents' moves, for the items still there unchanged.
        let fromUnpacked = plan.waiting.flatMap { item in
            (deepUnpacked[item.source.path] ?? []).filter { FileIdentity.current($0.source) == FileIdentity($0) }
        }
        let allActions = plan.actions.map { deepResults[FileIdentity($0)] ?? $0 }
            + plan.waiting.compactMap { deepResults[$0.identity] }
            + fromUnpacked
        waiting = plan.waiting.filter { deepResults[$0.identity] == nil && deepUnpacked[$0.source.path] == nil }

        let rejectedIDs = Set(settings.rejected)
        pending = allActions.filter { !rejectedIDs.contains(FileIdentity($0)) }
        rejected = allActions.filter { rejectedIDs.contains(FileIdentity($0)) }
        // Forget rejections for files that are gone or changed.
        let current = Set(allActions.map(FileIdentity.init))
        if settings.rejected.contains(where: { !current.contains($0) }) {
            settings.rejected.removeAll { !current.contains($0) }
        }
        skipped = plan.skipped
        scheduleRetry(plan.skipped.compactMap(\.retryAfter).min())
        selection = selection.intersection(Set(pending.map(\.id)))
        keepProfiles(plan.profiles)
        folderOptions = FolderCatalog.options(profiles: profiles, config: planner.config)
        lastScan = Date()
        lastScanDuration = Date().timeIntervalSince(started)

        let newOnes = pending.filter { !knownPendingIDs.contains($0.id) }
        knownPendingIDs = Set(pending.map(\.id))
        if !newOnes.isEmpty {
            log(.info, "Scan found \(newOnes.count) new file\(newOnes.count == 1 ? "" : "s") (\(pending.count) waiting)")
        }
        // Auto-filing first: no "ready to file" for files that were just filed.
        let filed = await autoApply()
        await notifyAbout(newOnes.filter { !filed.contains($0.id) })
    }

    /// Saves what the last plan learned about your folders, if anything changed.
    private func keepProfiles(_ fresh: [FolderProfile]) {
        guard fresh != profiles else { return }
        profiles = fresh
        do { try profileStore.save(fresh) } catch { log(.warning, "Couldn't save what was learned about your folders: \(error.localizedDescription)") }
    }

    /// A folder was still changing: look again once it should have settled. (Nothing else
    /// would trigger a scan, since the watcher only reports changes.)
    private func scheduleRetry(_ seconds: TimeInterval?) {
        retryTask?.cancel()
        guard let seconds else { return }
        retryTask = Task {
            try? await Task.sleep(for: .seconds(seconds + 1))
            guard !Task.isCancelled else { return }
            requestScan()
        }
    }

    // MARK: - Organize Now

    /// The full run: text recognition for images and scans, the model for leftovers and
    /// unclear names, all asked fresh.
    func organizeNow() {
        guard organizing == nil, !isLocked else { return }
        organizing = FullRun()
        organizeTask = Task { await runFullOrganize() }
    }

    func cancelOrganize() {
        organizeTask?.cancel()
    }

    private func runFullOrganize() async {
        while isScanning { try? await Task.sleep(for: .milliseconds(100)) }
        let started = Date()
        refreshModelStatus()
        var planner = Planner(homeRoot: homeURL, mode: .full)
        planner.onlyAddedAfter = settings.realUseSince
        planner.profiles = profiles
        planner.corrections = Correction.from(records, homeRoot: homeURL)
        if settings.useModel, modelUnavailableReason == nil {
            planner.classifier = AppleClassifier()
        }
        let fullPlanner = planner
        let folder = watchedURL
        log(.info, "Organize Now started\(planner.classifier is StubClassifier ? " (without the model)" : "")")

        do {
            let plan = try await fullPlanner.plan(folder: folder) { progress in
                // Updates hop to the main actor in no set order: an older one mustn't win.
                Task { @MainActor in
                    guard let run = AppModel.shared.organizing, progress.fraction >= run.fraction else { return }
                    AppModel.shared.organizing?.progress = progress
                }
            }
            deepResults = Dictionary(plan.actions.map { (FileIdentity($0), $0) }, uniquingKeysWith: { $1 })
            keepProfiles(plan.profiles)
            // Only the outermost unpacked folders show up in quick scans.
            let outermost = plan.unpacked.filter { $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL }
            deepUnpacked = Dictionary(outermost.map { unpacked in
                (unpacked.path, plan.actions.filter { $0.source.path.hasPrefix(unpacked.path + "/") })
            }, uniquingKeysWith: { $1 })
            let summary = FullRunSummary(
                date: Date(), duration: Date().timeIntervalSince(started), files: plan.actions.count,
                byRules: plan.actions.filter { if case .rule = $0.decidedBy { true } else { false } }.count,
                bySafety: plan.actions.filter { if case .safety = $0.decidedBy { true } else { false } }.count,
                // Placed or named by the model; "none" is the no-model stand-in, not a decision.
                byModel: plan.actions.filter {
                    if case .classifier(let name) = $0.decidedBy { name != "none" } else { $0.reason.contains("by the model") }
                }.count,
                alerts: plan.actions.filter { !$0.alerts.isEmpty }.count,
                toReview: plan.actions.filter { $0.destinationFolder == OrganizerConfig().reviewFolder }.count,
                cancelled: false)
            lastFullRun = summary
            organizing = nil
            log(.success, "Organize Now finished: \(summary.text)")
            await notifier.send(title: "Organize Now finished",
                                body: summary.text + ". Ready for your approval.", page: .pending)
        } catch {
            let cancelled = error is CancellationError
            lastFullRun = FullRunSummary(date: Date(), duration: Date().timeIntervalSince(started), files: 0, byRules: 0,
                                         bySafety: 0, byModel: 0, alerts: 0, toReview: 0, cancelled: cancelled)
            organizing = nil
            if cancelled {
                log(.warning, "Organize Now cancelled; nothing was changed")
            } else {
                show(.error, "Organize Now failed: \(error.localizedDescription)")
            }
        }
        // Fold the results into the plan (and catch up on anything that arrived meanwhile).
        if isScanning {
            scanRequested = true
        } else {
            isScanning = true
            await runScans()
        }
    }

    private func notifyAbout(_ newOnes: [ProposedAction]) async {
        // Sensitive files: always, once per file.
        for action in pending where action.alerts.contains(where: { $0.kind == .sensitive }) && !notifiedAlertIDs.contains(action.id) {
            notifiedAlertIDs.insert(action.id)
            let message = action.alerts.first { $0.kind == .sensitive }?.message ?? "Sensitive file"
            log(.warning, "\(action.originalName): \(message)")
            await notifier.send(title: "Sensitive file: \(action.originalName)", body: message, page: .alerts)
        }
        let ordinary = newOnes.filter { !$0.alerts.contains { $0.kind == .sensitive } }
        guard settings.notifyNewFiles, !ordinary.isEmpty, !NSApp.isActive else { return }
        let names = ordinary.prefix(3).map(\.originalName).joined(separator: ", ")
        await notifier.send(title: "\(ordinary.count) new file\(ordinary.count == 1 ? "" : "s") ready to file",
                            body: names + (ordinary.count > 3 ? "…" : ""), page: .pending)
    }

    /// Files the auto-apply settings allow, filed now. Returns the ones moved.
    private func autoApply() async -> Set<ProposedAction.ID> {
        let eligible = pending.filter(settings.autoApply.allows)
        // Not while you're applying or undoing something yourself; the next scan catches up.
        guard !eligible.isEmpty, !isApplying else { return [] }
        let results = await apply(eligible, automatic: true)
        return Set(results.filter { $0.outcome == .moved }.map(\.action.id))
    }

    // MARK: - Approving and rejecting

    func approve(_ ids: Set<ProposedAction.ID>) {
        let actions = pending.filter { ids.contains($0.id) }
        // One apply or undo at a time (a double-click mustn't start two).
        guard !actions.isEmpty, !isApplying else { return }
        isApplying = true
        Task { await apply(actions, automatic: false) }
    }

    func approveAll() { approve(Set(pending.map(\.id))) }

    func reject(_ ids: Set<ProposedAction.ID>) {
        guard !isApplying else { return }
        let actions = pending.filter { ids.contains($0.id) }
        settings.rejected.append(contentsOf: actions.map(FileIdentity.init))
        pending.removeAll { ids.contains($0.id) }
        rejected.append(contentsOf: actions)
        selection.subtract(ids)
        log(.info, "Rejected \(actions.count) file\(actions.count == 1 ? "" : "s"): they stay where they are")
    }

    /// Puts rejected files back into the plan.
    func reconsider(_ ids: Set<ProposedAction.ID>) {
        guard !isApplying else { return }
        let actions = rejected.filter { ids.contains($0.id) }
        let identities = Set(actions.map(FileIdentity.init))
        settings.rejected.removeAll { identities.contains($0) }
        rejected.removeAll { ids.contains($0.id) }
        pending.append(contentsOf: actions)
    }

    @discardableResult
    private func apply(_ actions: [ProposedAction], automatic: Bool) async -> [ApplyResult] {
        guard !isLocked else { isApplying = false; return [] }
        isApplying = true
        let applier = Applier(homeRoot: homeURL, journal: journal)
        let results = await Task.detached { applier.apply(actions) }.value
        isApplying = false

        let moved = results.filter { $0.outcome == .moved }
        for result in results {
            switch result.outcome {
            case .moved:
                log(.success, "\(automatic ? "Auto-filed" : "Moved") \(result.action.originalName) → \(result.action.destinationPath)")
            case .skipped(let why):
                log(.warning, "Skipped \(result.action.originalName): \(why)")
            case .failed(let why):
                log(.error, "Couldn't move \(result.action.originalName): \(why)")
            }
            for warning in result.warnings { log(.warning, "\(result.action.originalName): \(warning)") }
        }
        if moved.count < results.count {
            show(.warning, "\(moved.count) of \(results.count) moved; see Overview → Activity for the rest.")
        }
        if automatic, !moved.isEmpty {
            await notifier.send(title: "Auto-filed \(moved.count) file\(moved.count == 1 ? "" : "s")",
                                body: moved.prefix(3).map(\.action.originalName).joined(separator: ", "), page: .history)
        }
        afterChange()
        return results
    }

    // MARK: - Undo

    func undo(_ moves: [MoveRecord]) {
        let undoable = moves.filter { $0.state == .moved }
        guard !undoable.isEmpty, !isLocked, !isApplying else { return }
        let undoer = Undoer(journal: journal)
        isApplying = true
        Task {
            let results = await Task.detached { undoer.undo(undoable) }.value
            isApplying = false
            for result in results {
                let name = URL(filePath: result.record.movedPath).lastPathComponent
                if let to = result.restoredTo {
                    log(.success, "Put back \(name) → \(display(to))")
                } else {
                    log(.error, "Couldn't undo \(name): \(result.error ?? "unknown error")")
                }
                for note in result.notes { log(.warning, "\(name): \(note)") }
            }
            afterChange()
        }
    }

    func undoBatch(_ batchID: UUID) {
        undo(records.filter { $0.batchID == batchID })
    }

    private func afterChange() {
        reloadJournal()
        refreshReviewFolder()
        requestScan()
    }

    // MARK: - Journal, review folder, model

    func reloadJournal() {
        do {
            try journal.recover()
            records = try journal.records()
            let damaged = try journal.damagedLineCount()
            if damaged > reportedDamagedLines {
                show(.warning, "\(damaged) line\(damaged == 1 ? "" : "s") of the move log couldn't be read and were skipped; the rest of the history is fine.")
            }
            reportedDamagedLines = damaged
        } catch {
            records = []
            show(.error, "Couldn't read the move log (\(display(journal.url))): \(error.localizedDescription)")
        }
    }

    func refreshReviewFolder() {
        let byPath = Dictionary(records.filter { $0.state == .moved }.map { ($0.movedPath, $0) }, uniquingKeysWith: { $1 })
        reviewItems = ReviewReminder.items(in: reviewURL).map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .addedToDirectoryDateKey])
            let record = byPath[url.path]
            return ReviewItem(url: url, size: Int64(values?.fileSize ?? 0), added: values?.addedToDirectoryDate,
                              reason: record?.reason, record: record)
        }
    }

    func refreshModelStatus() {
        modelUnavailableReason = AppleClassifier.unavailableReason()
        modelSeesImages = AppleClassifier.canSeeImages
    }

    // MARK: - Watching

    func setWatching(_ on: Bool) {
        settings.watching = on
        updateWatcher()
        log(.info, on ? "Watching \(display(watchedURL))" : "Paused watching")
    }

    func updateWatcher() {
        watcher?.stop()
        watcher = nil
        isWatching = false
        guard settings.watching, !isLocked else { return }
        let watcher = FolderWatcher(url: watchedURL) {
            Task { @MainActor in AppModel.shared.requestScan() }
        }
        isWatching = watcher.start()
        self.watcher = watcher
        if !isWatching { show(.error, "Can't watch \(display(watchedURL)).") }
    }

    /// Points the app at different folders. Your real folders only after switching to real use.
    func setFolders(watched: URL? = nil, home: URL? = nil) {
        for url in [watched, home].compactMap(\.self) where FolderAccess.isRealUserFolder(url) && !isRealUseOn {
            show(.error, "\(url.path) is one of your real folders. Use \"Switch to My Real Folders\" first.")
            return
        }
        if let watched { settings.watchedFolder = watched.path }
        if let home { settings.homeRoot = home.path }
        knownPendingIDs = []
        pending = []
        profiles = profileStore.load()
        reloadJournal()
        refreshReviewFolder()
        updateWatcher()
        requestScan()
    }

    /// Starts real use: watches ~/Downloads and files into your home folder, but only files
    /// downloaded from now on. Auto-filing is turned off, so the first real moves all ask you.
    func switchToRealFolders() {
        guard !isRealUseOn else { return }
        organizeTask?.cancel()
        let real = AppSettings.real()
        settings.realUseSince = Date()
        sandboxAutoApply = settings.autoApply
        settings.autoApply.enabled = []
        settings.rejected = []
        deepResults = [:]
        deepUnpacked = [:]
        log(.info, "Switched to your real folders: only files downloaded from now on are organized")
        setFolders(watched: URL(filePath: real.watchedFolder), home: URL(filePath: real.homeRoot))
    }

    /// Back to the test folders. Moves already made stay in your folders (undo them first in
    /// History if you want them back); their log stays in Application Support.
    func switchToSandbox() {
        organizeTask?.cancel()
        let sandbox = AppSettings()
        settings.realUseSince = nil
        settings.rejected = []
        if let saved = sandboxAutoApply { settings.autoApply = saved }
        deepResults = [:]
        deepUnpacked = [:]
        log(.info, "Switched back to the sandbox")
        setFolders(watched: URL(filePath: sandbox.watchedFolder), home: URL(filePath: sandbox.homeRoot))
    }

    // MARK: - Reminders and notifications

    private func startReminderLoop() {
        reminderTask = Task {
            while !Task.isCancelled {
                await checkReviewReminder()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    /// Sends the review-folder reminder if it's due (or now, if `force`).
    func checkReviewReminder(force: Bool = false) async {
        refreshReviewFolder()
        let due = ReviewReminder.isDue(itemCount: reviewItems.count, lastSent: settings.lastReviewReminder,
                                       interval: settings.reviewReminderHours * 3600)
        guard force || due, !reviewItems.isEmpty else { return }
        let count = reviewItems.count
        log(.info, "Review reminder: \(count) item\(count == 1 ? "" : "s") waiting")
        // Only a reminder that was shown counts (not one blocked by notification settings).
        if await notifier.send(title: "\(count) item\(count == 1 ? "" : "s") in To Delete (Review)",
                               body: "Installers, duplicates, code projects and unsure files are waiting for you to check.",
                               page: .review) {
            settings.lastReviewReminder = Date()
        }
    }

    func requestNotificationPermission() {
        Task { notificationStatus = await notifier.requestAuthorization() }
    }

    func open(_ page: Page) {
        self.page = page
        openDashboardAction?()
        NSApp.activate()
    }

    // MARK: - Helpers

    func log(_ kind: ActivityEvent.Kind, _ text: String) {
        activity.insert(ActivityEvent(kind: kind, text: text), at: 0)
        if activity.count > 300 { activity.removeLast(activity.count - 300) }
    }

    func show(_ kind: ActivityEvent.Kind, _ text: String) {
        log(kind, text)
        banner = ActivityEvent(kind: kind, text: text)
    }

    /// A path shortened for display: relative to the sandbox, or with ~ for the home folder.
    func display(_ url: URL) -> String { display(url.path) }

    func display(_ path: String) -> String {
        // In the sandbox, relative to TestData ("Home/Documents/…").
        if !isRealUseOn {
            let sandbox = URL(filePath: settings.homeRoot).deletingLastPathComponent().path + "/"
            if path.hasPrefix(sandbox) { return String(path.dropFirst(sandbox.count)) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A path relative to the home folder ("Documents/FSAE/x.pdf"), or the path itself if outside it.
    func homeRelative(_ path: String) -> String {
        let home = homeURL.path + "/"
        return path.hasPrefix(home) ? String(path.dropFirst(home.count)) : path
    }

    func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func saveSettings() {
        do { try settings.save(to: Self.settingsURL) } catch { log(.error, "Couldn't save settings: \(error.localizedDescription)") }
    }
}

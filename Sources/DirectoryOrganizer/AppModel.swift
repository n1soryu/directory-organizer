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
    /// True while either folder is one of your real folders: everything stops until real use is unlocked.
    var isUsingRealFolders: Bool {
        FolderAccess.isRealUserFolder(watchedURL) || FolderAccess.isRealUserFolder(homeURL)
    }

    // MARK: Private

    private let notifier = Notifier()
    private let classifier = CachingClassifier(AppleClassifier())
    private var watcher: FolderWatcher?
    private var scanRequested = false
    private var knownPendingIDs = Set<String>()
    private var notifiedAlertIDs = Set<String>()
    private var reminderTask: Task<Void, Never>?
    private var started = false

    private init() {
        settings = AppSettings.load()
    }

    /// Called once at launch.
    func start() {
        guard !started else { return }
        started = true
        log(.info, "Directory Organizer started (sandbox: \(display(watchedURL)))")
        refreshModelStatus()
        reloadJournal()
        refreshReviewFolder()
        updateWatcher()
        startReminderLoop()
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
        if isScanning { scanRequested = true; return }
        Task { await scan() }
    }

    private func scan() async {
        guard !isUsingRealFolders else {
            show(.error, "Your real folders are locked for now; choose folders inside TestData in Settings.")
            return
        }
        guard FileManager.default.fileExists(atPath: watchedURL.path) else {
            show(.warning, "The watched folder doesn't exist: \(display(watchedURL)). Run `swift run make-testdata`.")
            return
        }
        isScanning = true
        let started = Date()
        defer { isScanning = false }

        refreshModelStatus()
        var planner = Planner(homeRoot: homeURL)
        if settings.useModel, modelUnavailableReason == nil {
            planner.classifier = classifier
        }
        let plan: Plan
        do {
            plan = try await planner.plan(folder: watchedURL)
        } catch {
            show(.error, "Couldn't read \(display(watchedURL)): \(error.localizedDescription)")
            return
        }

        let rejectedIDs = Set(settings.rejected)
        pending = plan.actions.filter { !rejectedIDs.contains(FileIdentity($0)) }
        rejected = plan.actions.filter { rejectedIDs.contains(FileIdentity($0)) }
        // Forget rejections for files that are gone or changed.
        let current = Set(plan.actions.map(FileIdentity.init))
        if settings.rejected.contains(where: { !current.contains($0) }) {
            settings.rejected.removeAll { !current.contains($0) }
        }
        skipped = plan.skipped
        selection = selection.intersection(Set(pending.map(\.id)))
        folderOptions = FolderCatalog.options(homeRoot: homeURL, config: planner.config)
        lastScan = Date()
        lastScanDuration = Date().timeIntervalSince(started)

        let newOnes = pending.filter { !knownPendingIDs.contains($0.id) }
        knownPendingIDs = Set(pending.map(\.id))
        if !newOnes.isEmpty {
            log(.info, "Scan found \(newOnes.count) new file\(newOnes.count == 1 ? "" : "s") (\(pending.count) waiting)")
        }
        await notifyAbout(newOnes)
        await autoApply()

        if scanRequested {
            scanRequested = false
            await scan()
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

    private func autoApply() async {
        let eligible = pending.filter(settings.autoApply.allows)
        guard !eligible.isEmpty else { return }
        await apply(eligible, automatic: true)
    }

    // MARK: - Approving and rejecting

    func approve(_ ids: Set<ProposedAction.ID>) {
        let actions = pending.filter { ids.contains($0.id) }
        guard !actions.isEmpty else { return }
        Task { await apply(actions, automatic: false) }
    }

    func approveAll() { approve(Set(pending.map(\.id))) }

    func reject(_ ids: Set<ProposedAction.ID>) {
        let actions = pending.filter { ids.contains($0.id) }
        settings.rejected.append(contentsOf: actions.map(FileIdentity.init))
        pending.removeAll { ids.contains($0.id) }
        rejected.append(contentsOf: actions)
        selection.subtract(ids)
        log(.info, "Rejected \(actions.count) file\(actions.count == 1 ? "" : "s"): they stay where they are")
    }

    /// Puts rejected files back into the plan.
    func reconsider(_ ids: Set<ProposedAction.ID>) {
        let actions = rejected.filter { ids.contains($0.id) }
        let identities = Set(actions.map(FileIdentity.init))
        settings.rejected.removeAll { identities.contains($0) }
        rejected.removeAll { ids.contains($0.id) }
        pending.append(contentsOf: actions)
    }

    private func apply(_ actions: [ProposedAction], automatic: Bool) async {
        guard !isUsingRealFolders else { return }
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
    }

    // MARK: - Undo

    func undo(_ moves: [MoveRecord]) {
        let undoable = moves.filter { $0.state == .moved }
        guard !undoable.isEmpty, !isUsingRealFolders else { return }
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
        _ = try? journal.recover()
        records = (try? journal.records()) ?? []
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
        guard settings.watching, !isUsingRealFolders else { return }
        let watcher = FolderWatcher(url: watchedURL) {
            Task { @MainActor in AppModel.shared.requestScan() }
        }
        isWatching = watcher.start()
        self.watcher = watcher
        if !isWatching { show(.error, "Can't watch \(display(watchedURL)).") }
    }

    /// Points the app at different folders (must not be your real folders, for now).
    func setFolders(watched: URL? = nil, home: URL? = nil) {
        for url in [watched, home].compactMap(\.self) where FolderAccess.isRealUserFolder(url) {
            show(.error, "\(url.path) is one of your real folders. They stay locked until you decide to switch.")
            return
        }
        if let watched { settings.watchedFolder = watched.path }
        if let home { settings.homeRoot = home.path }
        knownPendingIDs = []
        pending = []
        reloadJournal()
        refreshReviewFolder()
        updateWatcher()
        requestScan()
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
        settings.lastReviewReminder = Date()
        let count = reviewItems.count
        log(.info, "Review reminder: \(count) item\(count == 1 ? "" : "s") waiting")
        await notifier.send(title: "\(count) item\(count == 1 ? "" : "s") in To Delete (Review)",
                            body: "Installers, duplicates, code projects and unsure files are waiting for you to check.",
                            page: .review)
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
        let sandbox = URL(filePath: settings.homeRoot).deletingLastPathComponent().path + "/"
        if path.hasPrefix(sandbox) { return String(path.dropFirst(sandbox.count)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func saveSettings() {
        do { try settings.save() } catch { log(.error, "Couldn't save settings: \(error.localizedDescription)") }
    }
}

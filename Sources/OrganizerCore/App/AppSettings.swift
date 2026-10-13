import Foundation

/// Identifies one version of a file: same path, size and modification date. Used to
/// remember files you rejected, so they don't come back on every scan (until they change).
public struct FileIdentity: Codable, Hashable, Sendable {
    public var path: String
    public var size: Int64
    public var modified: Date?

    public init(_ action: ProposedAction) {
        path = action.source.path
        size = action.sourceSize
        modified = action.sourceModified
    }
}

/// Which kinds of rule decisions may be applied without asking. Off by default. Only
/// confident rule decisions (90%+) without any alert qualify; model decisions, safety
/// decisions, duplicates and anything with an alert always wait for you.
public struct AutoApplyPolicy: Codable, Equatable, Sendable {
    public struct Category: Identifiable, Sendable {
        public var id: String
        public var title: String
        public var detail: String
        /// Rule names (`Rule.name`) in this category.
        public var rules: Set<String>
    }

    public static let categories: [Category] = [
        Category(id: "films", title: "Films, TV and clips", detail: "Movies/Films, TV Shows, Clips, with cleaned-up names", rules: ["video"]),
        Category(id: "images", title: "Images and screenshots", detail: "Pictures/Downloaded Images", rules: ["image"]),
        Category(id: "courses", title: "Course files", detail: "University/<course>, when the course code is in the file name", rules: ["course"]),
        Category(id: "records", title: "NSU records", detail: "University/Records/…, dated", rules: ["NSU record"]),
        Category(id: "fsae", title: "FSAE files", detail: "Documents/FSAE, when FSAE is in the file name", rules: ["FSAE"]),
        Category(id: "installers", title: "Installers and firmware", detail: "to the review folder", rules: ["installer"]),
        Category(id: "code", title: "Code projects", detail: "to the review folder", rules: ["code project"]),
    ]

    public var enabled: Set<String> = []
    public static let minimumConfidence = 0.9

    public init(enabled: Set<String> = []) {
        self.enabled = enabled
    }

    public func allows(_ action: ProposedAction) -> Bool {
        guard case .rule(let rule) = action.decidedBy,
              action.alerts.isEmpty,
              action.confidence >= Self.minimumConfidence else { return false }
        return Self.categories.contains { enabled.contains($0.id) && $0.rules.contains(rule) }
    }
}

/// The review-folder reminder: due when the folder has something in it and the last
/// reminder was at least `interval` ago.
public enum ReviewReminder {
    public static func isDue(itemCount: Int, lastSent: Date?, now: Date = Date(), interval: TimeInterval) -> Bool {
        guard itemCount > 0 else { return false }
        guard let lastSent else { return true }
        return now.timeIntervalSince(lastSent) >= interval
    }

    public static func nextDue(lastSent: Date?, now: Date = Date(), interval: TimeInterval) -> Date {
        guard let lastSent else { return now }
        return max(now, lastSent.addingTimeInterval(interval))
    }

    /// Visible items in the review folder.
    public static func items(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .addedToDirectoryDateKey], options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// Whether the app can read a folder. Reading a protected folder (Downloads, Documents,
/// Desktop) for the first time makes macOS ask you for permission.
public enum FolderAccess {
    public enum Status: Equatable, Sendable {
        case granted
        case denied
        case missing
    }

    public static func status(of url: URL) -> Status {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .missing
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
            return .granted
        } catch {
            return .denied
        }
    }

    /// Your real folders. The app refuses to use them until real use is switched on.
    public static func isRealUserFolder(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path == home { return true }
        return ["Downloads", "Documents", "Desktop", "Pictures", "Movies", "Music"]
            .map { home + "/" + $0 }
            .contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

/// The app's settings, saved as JSON in ~/Library/Application Support/DirectoryOrganizer.
public struct AppSettings: Codable, Equatable, Sendable {
    /// The folder watched for new downloads.
    public var watchedFolder: String
    /// The folder destinations are relative to (the stand-in home while testing).
    public var homeRoot: String
    public var watching = true
    public var useModel = true
    public var autoApply = AutoApplyPolicy()
    public var reviewReminderHours: Double = 8
    public var lastReviewReminder: Date?
    public var notifyNewFiles = true
    /// Files you rejected; they stay out of the plan until they change.
    public var rejected: [FileIdentity] = []

    /// The sandbox inside the project: ~/Developer/directory-organizer/TestData.
    public static var sandboxRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Developer/directory-organizer/TestData")
    }

    public init(watchedFolder: String = AppSettings.sandboxRoot.appending(path: "Downloads").path,
                homeRoot: String = AppSettings.sandboxRoot.appending(path: "Home").path) {
        self.watchedFolder = watchedFolder
        self.homeRoot = homeRoot
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/DirectoryOrganizer/settings.json")
    }

    public static func load(from url: URL = defaultURL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? decoder.decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    public func save(to url: URL = AppSettings.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The move log sits next to the home folder, shared with the `organize` command.
    public var journalURL: URL {
        URL(filePath: homeRoot).deletingLastPathComponent().appending(path: "moves.jsonl")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

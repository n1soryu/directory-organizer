import Foundation

/// One proposed move, fully checked and resolved: this is what you approve.
public struct ProposedAction: Codable, Sendable, Identifiable {
    public var id: String { source.path }

    public var source: URL
    public var originalName: String
    /// Size and modification date when planned. Checked again just before moving:
    /// if either changed (still downloading, edited), the move is skipped.
    public var sourceSize: Int64
    public var sourceModified: Date?
    /// Folder relative to the home root.
    public var destinationFolder: String
    /// Final file name, after cleaning, renaming and clash handling.
    public var finalName: String
    public var tags: [Tag]
    public var confidence: Double
    public var reason: String
    public var decidedBy: DecisionSource
    public var alerts: [Alert]
    /// Folders (relative to the home root) that don't exist yet and would be created.
    public var createsFolders: [String]
    /// Everything read from the file, for showing in the app.
    public var facts: FileFacts?

    public var isRenamed: Bool { finalName != originalName }
    public var destinationPath: String { destinationFolder + "/" + finalName }
}

/// Something in the folder that was deliberately left alone.
public struct SkippedItem: Codable, Sendable {
    public var name: String
    public var reason: String
    /// Worth another look after this many seconds (a folder still being written), or nil.
    public var retryAfter: TimeInterval?

    public init(name: String, reason: String, retryAfter: TimeInterval? = nil) {
        self.name = name
        self.reason = reason
        self.retryAfter = retryAfter
    }
}

/// A file a quick scan couldn't decide: it needs text recognition or the model (Organize Now).
public struct WaitingItem: Codable, Sendable, Identifiable {
    public var id: String { source.path }
    public var source: URL
    public var name: String
    public var identity: FileIdentity
    public var reason: String
}

public struct Plan: Codable, Sendable {
    public var createdAt: Date
    public var inputFolder: URL
    public var homeRoot: URL
    public var actions: [ProposedAction]
    public var skipped: [SkippedItem]
    /// Quick scans only: files left for a full run.
    public var waiting: [WaitingItem] = []
    /// Folders the model unpacked: their contents are planned item by item (and appear in
    /// `actions` with sources inside these folders).
    public var unpacked: [URL] = []
    /// Your folders as this plan saw them, with purposes learned so far: keep them for next time.
    public var profiles: [FolderProfile] = []
    /// New catalog entries (files carded and embedded by this run): append them to the catalog.
    /// Not part of the plan's JSON.
    public var catalogEntries: [CatalogEntry] = []

    enum CodingKeys: String, CodingKey {
        case createdAt, inputFolder, homeRoot, actions, skipped, waiting, unpacked, profiles
    }

    public var alerts: [(action: ProposedAction, alert: Alert)] {
        actions.flatMap { action in action.alerts.map { (action, $0) } }
    }
}

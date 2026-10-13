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
}

public struct Plan: Codable, Sendable {
    public var createdAt: Date
    public var inputFolder: URL
    public var homeRoot: URL
    public var actions: [ProposedAction]
    public var skipped: [SkippedItem]

    public var alerts: [(action: ProposedAction, alert: Alert)] {
        actions.flatMap { action in action.alerts.map { (action, $0) } }
    }
}

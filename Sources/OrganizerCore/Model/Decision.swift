import Foundation

/// A Finder tag. Stored on disk (Milestone 2) as "Name\n<color number>".
public struct Tag: Codable, Hashable, Sendable {
    public var name: String
    public var color: TagColor

    public init(_ name: String, _ color: TagColor) {
        self.name = name
        self.color = color
    }

    public static let personal = Tag("Personal", .purple)
    public static let secure = Tag("Secure", .red)
}

/// Finder's tag color numbers.
public enum TagColor: Int, Codable, Sendable {
    case none = 0, gray, green, purple, blue, yellow, red, orange
}

/// Something you should know about a file, whatever happens to it.
public struct Alert: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Password export, recovery phrase, private key, credentials.
        case sensitive
        /// Byte-for-byte identical to another file (same SHA-256).
        case duplicate
        /// Same name as an existing, different file: the new one gets a dated name.
        case nameClash
        /// The proposal broke a safety rule and was redirected to review.
        case rejected
    }

    public var kind: Kind
    public var message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Who made a decision. Shown in the plan so every move can be explained.
public enum DecisionSource: Codable, Hashable, Sendable, CustomStringConvertible {
    case safety(String)
    case rule(String)
    case classifier(String)

    public var description: String {
        switch self {
        case .safety(let name): "safety: \(name)"
        case .rule(let name): "rule: \(name)"
        case .classifier(let name): "model: \(name)"
        }
    }
}

/// A rule's (or the classifier's) answer for one file, before the planner checks it.
public struct Decision: Sendable {
    /// Folder relative to the home root, e.g. "Documents/Bills/Water".
    public var destination: String
    /// New name without extension, or nil to keep the current name.
    public var newBaseName: String?
    public var tags: [Tag]
    /// 0...1. Rules that matched on solid evidence use 0.9 or more.
    public var confidence: Double
    public var reason: String
    public var source: DecisionSource
    public var alerts: [Alert]

    public init(
        destination: String,
        newBaseName: String? = nil,
        tags: [Tag] = [],
        confidence: Double,
        reason: String,
        source: DecisionSource,
        alerts: [Alert] = []
    ) {
        self.destination = destination
        self.newBaseName = newBaseName
        self.tags = tags
        self.confidence = confidence
        self.reason = reason
        self.source = source
        self.alerts = alerts
    }
}

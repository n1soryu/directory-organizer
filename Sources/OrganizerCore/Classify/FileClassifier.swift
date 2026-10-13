import Foundation

/// What a model may say about a file: a suggestion, never an action.
/// The planner checks it (allowed folder, sane name, confidence) before it reaches the plan.
public struct ClassifierSuggestion: Codable, Sendable {
    /// Folder relative to the home root, e.g. "Documents/Essays".
    public var destination: String
    public var newBaseName: String?
    public var tags: [String]
    /// 0...1.
    public var confidence: Double
    public var reason: String

    public init(destination: String, newBaseName: String? = nil, tags: [String] = [],
                confidence: Double, reason: String) {
        self.destination = destination
        self.newBaseName = newBaseName
        self.tags = tags
        self.confidence = confidence
        self.reason = reason
    }
}

/// Anything that can suggest where a file belongs: Apple's on-device model, Ollama,
/// or the stub below. One protocol so they can be swapped and compared.
public protocol FileClassifier: Sendable {
    var name: String { get }
    /// Returns nil when the classifier can't help (e.g. no model available).
    func suggest(for facts: FileFacts, config: OrganizerConfig) async throws -> ClassifierSuggestion?
}

/// Milestone 1 placeholder: no model yet, so leftovers go to review.
public struct StubClassifier: FileClassifier {
    public let name = "stub"
    public init() {}

    public func suggest(for facts: FileFacts, config: OrganizerConfig) async throws -> ClassifierSuggestion? {
        nil
    }
}

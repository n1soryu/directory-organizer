import Foundation

/// Remembers the model's answers per file version, so rescanning a folder (the app does it
/// every time something changes) doesn't ask the model about the same file again.
public struct CachingClassifier: FileClassifier {
    public let base: any FileClassifier
    private let cache = Cache()

    public var name: String { base.name }

    public init(_ base: any FileClassifier) {
        self.base = base
    }

    public func suggest(_ request: ClassificationRequest) async throws -> ClassifierSuggestion {
        // The offered folders are part of the question, so they're part of the key.
        let key = Self.key(request.facts) + "|" + request.folders.map(\.path).joined(separator: ",")
        if let known = await cache.suggestions[key] { return known }
        let answer = try await base.suggest(request)
        await cache.store(answer, for: key)
        return answer
    }

    public func suggestName(for facts: FileFacts) async throws -> NameSuggestion {
        let key = Self.key(facts)
        if let known = await cache.names[key] { return known }
        let answer = try await base.suggestName(for: facts)
        await cache.store(answer, for: key)
        return answer
    }

    private static func key(_ facts: FileFacts) -> String {
        "\(facts.url.path)|\(facts.size)|\(facts.modified?.timeIntervalSince1970 ?? 0)"
    }

    /// An actor: safe to use from several tasks at once.
    private actor Cache {
        var suggestions: [String: ClassifierSuggestion] = [:]
        var names: [String: NameSuggestion] = [:]

        func store(_ suggestion: ClassifierSuggestion, for key: String) { suggestions[key] = suggestion }
        func store(_ name: NameSuggestion, for key: String) { names[key] = name }
    }
}

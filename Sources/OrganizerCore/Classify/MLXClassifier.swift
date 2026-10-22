import Foundation

/// What a file is, in the language model's words (the benchmark's Task 1 "card").
/// One card per file replaces the old "describe" and "suggest a name" questions.
public struct FileCard: Codable, Sendable, Equatable {
    public var kind: String
    public var issuer: String?
    public var subject: String
    public var date: String?
    public var people: [String]
    public var suggestedName: String
    public var summary: String

    enum CodingKeys: String, CodingKey {
        case kind, issuer, subject, date, people, summary
        case suggestedName = "suggested_name"
    }

    public init(kind: String, issuer: String? = nil, subject: String, date: String? = nil, people: [String] = [],
                suggestedName: String, summary: String) {
        self.kind = kind
        self.issuer = issuer
        self.subject = subject
        self.date = date
        self.people = people
        self.suggestedName = suggestedName
        self.summary = summary
    }

    /// The card as one line, for other prompts ("About this file: …").
    public var line: String {
        var parts = ["kind: \(kind)"]
        if let issuer { parts.append("issuer: \(issuer)") }
        parts.append("subject: \(subject)")
        parts.append("summary: \(summary)")
        return parts.joined(separator: "; ")
    }
}

/// The organizer's questions, asked of a local language model (Qwen3 8B through MLX in the app;
/// a scripted fake in tests). Answers are JSON, read leniently and asked again up to twice when
/// invalid; a question still unanswered then throws, and the file waits in Downloads.
///
/// Thinking is off for describing (cards, folder purposes) and on for decisions (which folder,
/// unpack or not): the benchmark showed decisions need it. In JSON that chooses, `reason` comes
/// first, because the order of the fields changes the decision.
public actor MLXClassifier: FileClassifier {
    public nonisolated let name = "qwen3"
    private let model: any LanguageModel
    /// nil when the model can be used; otherwise why not (not downloaded, no GPU shaders).
    private let unavailable: @Sendable () -> String?
    /// Characters of document text a card sees (the benchmark used 4,000).
    public static let textLimit = 4_000
    private var cards: [URL: FileCard] = [:]

    public init(model: any LanguageModel, unavailable: @escaping @Sendable () -> String? = { nil }) {
        self.model = model
        self.unavailable = unavailable
    }

    static let confidenceLevels: [String: Double] = ["high": 0.9, "medium": 0.75, "low": 0.4]

    // MARK: - Cards

    static let cardSystem = """
        You read one file that a person downloaded and describe it so it can be filed later.
        Answer with one JSON object only, no other text, with these fields:
        {"kind": string, "issuer": string or null, "subject": string, "date": string or null, "people": [string], "suggested_name": string, "summary": string}
        Field rules:
        - kind: what sort of document this is, in 1 to 3 lowercase words.
        - issuer: the organisation or person that produced it, or null if the file does not say.
        - subject: what it is about, at most 8 words.
        - date: the most relevant date as YYYY-MM-DD or YYYY-MM, or null.
        - people: names of people the document is for or about; [] if none.
        - suggested_name: a clear file name without extension; include the issuer and date when they help.
        - summary: one sentence.
        Use only what the file says. Do not guess.
        """

    /// The file's card, asked once per file and kept for the rest of the run.
    public func card(for facts: FileFacts) async throws -> FileCard {
        if let card = facts.visionCard ?? facts.knownCard ?? cards[facts.url] { return card }
        if facts.kind == .image, !Self.hasText(facts) {
            // Nothing to read; describing a picture needs the vision model (Milestone C).
            throw ClassifierError.unavailable("an image without text needs the vision model")
        }
        let card = try await ask(FileCard.self, thinking: false, [
            .system(Self.cardSystem),
            .user(FactSummary.describe(facts, textLimit: Self.textLimit)),
        ]) { card in
            if card.kind.trimmingCharacters(in: .whitespaces).isEmpty { return "\"kind\" is empty" }
            if card.suggestedName.trimmingCharacters(in: .whitespaces).isEmpty { return "\"suggested_name\" is empty" }
            return nil
        }
        cards[facts.url] = card
        return card
    }

    static func hasText(_ facts: FileFacts) -> Bool {
        !(facts.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func suggestName(for facts: FileFacts) async throws -> NameSuggestion {
        let card = try await card(for: facts)
        // A name from the file's own text, or from what the vision model saw, is trustworthy;
        // one from its name and type alone isn't.
        let seen = facts.visionCard != nil || Self.hasText(facts)
        return NameSuggestion(title: card.suggestedName, confidence: seen ? 0.9 : 0.5)
    }

    // MARK: - Where does this file go? (the benchmark's Task 2, with the catalog's neighbours)

    /// The benchmark's decision prompt (11/12 with thinking on), with two changes: rule 3 names
    /// the parents a new folder may go under, and rule 8 explains files waiting in Downloads
    /// (there's no Documents/Unsorted). Folder purposes and your corrections come in the message.
    static func decisionSystem(newFolderParents: [String]) -> String {
        let parents = newFolderParents.map { "\"\($0)/\"" }.joined(separator: " or ")
        return """
            You help file documents on a Mac. A new file has arrived. You are shown the new file, up to five earlier files that may be related (with the folder each one is in now), and the folders that already exist. Decide where the new file should go.
            Answer with one JSON object only, no other text, with these fields in this order:
            {"reason": string, "action": "join" or "new_folder" or "wait", "folder": string or null, "move_earlier": [string], "new_file_name": string}
            Rules:
            1. Nothing is ever deleted. You only choose folders and names.
            2. "join": put the new file in an existing folder. "folder" must be copied exactly from the list of existing folders.
            3. "new_folder": create a folder for the new file together with earlier files that are clearly the same kind of thing and that a person would want kept together. "folder" is the new folder's full path; it must start with \(parents) and must not already exist. It may be inside an existing folder. "move_earlier" must list at least one earlier file id.
            4. "move_earlier": ids of earlier files that should move into the chosen folder. Use only ids from the list. Leave out files that are already in that folder. It may be [] for "join".
            5. "wait": nothing belongs with this file yet. "folder" is null and "move_earlier" is [].
            6. Files belong together when they are the same kind of document for the same purpose, not just because they share a word or come from the same company.
            7. Prefer an existing folder when it fits.
            8. An earlier file shown as "Downloads (waiting)" has not been filed yet; it can be moved like any other earlier file. Never choose Downloads as "folder".
            9. Write "reason" first, in one or two sentences.
            10. "new_file_name": a clear file name for the new file, without extension.
            """
    }

    static func decisionMessage(_ request: DecisionRequest, card: FileCard?) -> String {
        let folders = request.folders.map { folder in
            var line = "- \(folder.path)"
            if let purpose = folder.purpose { line += ": \(purpose)" }
            return line
        }.joined(separator: "\n")
        let earlier = request.earlier.isEmpty ? "(none)" : request.earlier.map {
            "- id: \($0.id) | folder: \($0.shownFolder) | name: \($0.name) | about: \($0.about)"
        }.joined(separator: "\n")
        var text = """
            Existing folders:
            \(folders)

            Earlier files:
            \(earlier)

            New file name: \(request.facts.name)

            """
        if let card { text += "About the new file: \(card.line)\n" }
        text += "New file:\n<<<\n\(FactSummary.describe(request.facts, textLimit: Self.textLimit))\n>>>"
        if !request.corrections.isEmpty {
            text += "\n\nThe owner corrected these earlier choices; don't repeat them:\n"
                + request.corrections.map { "- \($0)" }.joined(separator: "\n")
        }
        return text
    }

    public func decide(_ request: DecisionRequest) async throws -> FolderDecision {
        let card = try? await card(for: request.facts)
        return try await ask(FolderDecision.self, thinking: true, [
            .system(Self.decisionSystem(newFolderParents: request.newFolderParents)),
            .user(Self.decisionMessage(request, card: card)),
        ]) { $0.problem(in: request) }
    }

    // MARK: - Keep this folder together, or unpack it?

    struct Unpack: Decodable, Sendable {
        var reason: String
        var kind: String
        var keepTogether: Bool
        var confidence: String

        enum CodingKeys: String, CodingKey {
            case reason, kind, confidence
            case keepTogether = "keep_together"
        }
    }

    static let unpackSystem = """
        You organize downloaded folders on a Mac. Decide whether a folder is one thing that must stay \
        together, or just a container of separate items that each belong in a different place.
        Keep together when the parts depend on each other or form one collection: a software project, \
        a website, an album or photo set from one event, a course pack, a game, a document with its attachments.
        Unpack when the items are unrelated or of different kinds, so each one can be filed on its own: \
        a folder of assorted downloads, a mix of contracts, receipts and pictures.
        When in doubt, keep it together.
        Answer with one JSON object only, no other text, with these fields in this order:
        {"reason": string, "kind": string, "keep_together": true or false, "confidence": "high" or "medium" or "low"}
        - reason: first, one sentence explaining the choice.
        - kind: what this folder is, in 2 to 5 words.
        """

    public func suggestUnpack(for facts: FileFacts) async throws -> UnpackSuggestion {
        let answer = try await ask(Unpack.self, thinking: true, [
            .system(Self.unpackSystem),
            .user(FactSummary.describe(facts, textLimit: 1_500)),
        ]) { Self.confidenceLevels[$0.confidence] == nil ? "\"confidence\" must be \"high\", \"medium\" or \"low\"" : nil }
        return UnpackSuggestion(unpack: !answer.keepTogether, kind: answer.kind,
                                confidence: Self.confidenceLevels[answer.confidence] ?? 0.4, reason: answer.reason)
    }

    // MARK: - What is this folder of yours for?

    struct Purpose: Decodable, Sendable { var purpose: String }

    static let folderSystem = """
        You describe a folder on a Mac so that new files can be matched to it. Say what kind of \
        files it holds, judging by the files themselves more than by the folder's name. Be specific \
        but general enough for similar future files. No dates, no file names.
        Answer with one JSON object only, no other text: {"purpose": string}
        - purpose: what kind of files belong in this folder, 2 to 8 words, plural.
        """

    public func describeFolder(_ profile: FolderProfile) async throws -> String {
        var lines = ["Folder: \(profile.path)", "Files directly inside: \(profile.fileCount)"]
        let kinds = profile.kinds.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }
        if !kinds.isEmpty { lines.append("Kinds: \(kinds.joined(separator: ", "))") }
        if !profile.examples.isEmpty { lines.append("Examples: \(profile.examples.joined(separator: "; "))") }
        if !profile.sources.isEmpty { lines.append("Downloaded from: \(profile.sources.joined(separator: ", "))") }
        if profile.fileCount == 0 { lines.append("The folder is empty: go by its name and where it is.") }
        let answer = try await ask(Purpose.self, thinking: false, [.system(Self.folderSystem), .user(lines.joined(separator: "\n"))]) {
            $0.purpose.trimmingCharacters(in: .whitespaces).isEmpty ? "\"purpose\" is empty" : nil
        }
        return answer.purpose.trimmingCharacters(in: CharacterSet(charactersIn: " .\"'\n"))
    }

    // MARK: - Shared

    /// One fresh chat per question, so files don't influence each other.
    private func ask<T: Decodable & Sendable>(_ type: T.Type, thinking: Bool, _ messages: [ChatMessage],
                                              check: @escaping @Sendable (T) -> String?) async throws -> T {
        if let reason = unavailable() { throw ClassifierError.unavailable(reason) }
        let outcome = try await model.askJSON(T.self, messages: messages, thinking: thinking, check: check)
        guard let value = outcome.value else {
            throw ClassifierError.invalidAnswer(outcome.problems.last?.description ?? "no answer")
        }
        return value
    }
}

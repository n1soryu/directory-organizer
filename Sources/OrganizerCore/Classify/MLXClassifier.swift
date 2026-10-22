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
/// invalid; a question still unanswered then throws, and the planner sends the file to review.
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

    static let noneFits = "none of these"
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
        if let card = facts.visionCard ?? cards[facts.url] { return card }
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

    public func describe(_ facts: FileFacts) async throws -> FileDescription {
        let kind = try await card(for: facts).kind.trimmingCharacters(in: .whitespacesAndNewlines)
        // Grouping goes by the kind's main word ("electricity bill", "gas bill" → bill).
        return FileDescription(kind: kind, category: kind)
    }

    public func suggestName(for facts: FileFacts) async throws -> NameSuggestion {
        let card = try await card(for: facts)
        // A name from the file's own text, or from what the vision model saw, is trustworthy;
        // one from its name and type alone isn't.
        let seen = facts.visionCard != nil || Self.hasText(facts)
        return NameSuggestion(title: card.suggestedName, confidence: seen ? 0.9 : 0.5)
    }

    // MARK: - Where does this file go? (interim, until the catalog decisions of Milestone E)

    struct Placement: Decodable, Sendable {
        var reason: String
        var kind: String
        var folder: String
        var newFolder: String?
        var newName: String?
        var confidence: String

        enum CodingKeys: String, CodingKey {
            case reason, kind, folder, confidence
            case newFolder = "new_folder"
            case newName = "new_name"
        }
    }

    static func instructions(folders: [FolderOption], review: String, newFolderParents: [String],
                             corrections: [String] = [], group: Bool = false) -> String {
        let list = folders.map { folder in
            var line = "- \(folder.path)"
            if let purpose = folder.purpose { line += ": \(purpose)" }
            let examples = folder.examples.prefix(3).map { String($0.prefix(40)) }
            if !examples.isEmpty { line += " (holds e.g. \(examples.joined(separator: "; ")))" }
            return line
        }.joined(separator: "\n")
        let what = group ? "these files" : "this file"
        var text = """
            You sort downloaded files into folders on a Mac. You only suggest; code checks your answer \
            and the owner can undo it.

            Folders, with what they're for and files already in them:
            \(list)

            Answer with one JSON object only, no other text, with these fields in this order:
            {"reason": string, "kind": string, "folder": string, "new_folder": string or null, \
            \(group ? "" : "\"new_name\": string or null, ")"confidence": "high" or "medium" or "low"}
            Rules:
            - reason: first, in one or two sentences: which folder's purpose matches \(what) and why, or why none does.
            - kind: what \(what) \(group ? "are" : "is"), in 2 to 5 words.
            - folder: copied exactly from the list above, or "\(noneFits)".
            - A folder fits only if its purpose matches what \(what) \(group ? "are" : "is"). Compare with the files already in it.
            - Don't choose a folder because a word matches: a recipe is not a work document, a phone manual is not school material.
            - If no folder's purpose matches, folder is "\(noneFits)" and new_folder is a new folder's path: \
            one of \(newFolderParents.map { "\"\($0)/\"" }.joined(separator: ", ")) followed by a general category name \
            of 1 to 3 words, plural, so similar files can go there too. Never use a file's own name, a brand or a date.
            - Otherwise new_folder is null.
            - If you can't tell what \(what) \(group ? "are" : "is"), choose \(review) with low confidence.
            """
        if !group {
            text += "\n- new_name: a clear name for the file, without extension, only when its current name is unclear; otherwise null."
        }
        if !corrections.isEmpty {
            text += "\n\nThe owner corrected these earlier choices; don't repeat them:\n"
                + corrections.map { "- \($0)" }.joined(separator: "\n")
        }
        return text
    }

    /// What's wrong with a placement, worded for the model; nil if it can be used.
    static func problem(with answer: Placement, folders: [FolderOption], newFolderParents: [String]) -> String? {
        if confidenceLevels[answer.confidence] == nil { return "\"confidence\" must be \"high\", \"medium\" or \"low\"" }
        if answer.folder == noneFits {
            guard let path = answer.newFolder?.trimmingCharacters(in: .whitespaces), !path.isEmpty else {
                return "\"folder\" is \"\(noneFits)\", so \"new_folder\" must name the new folder"
            }
            guard let parent = newFolderParents.first(where: { path.hasPrefix($0 + "/") }) else {
                return "\"new_folder\" must start with one of: \(newFolderParents.map { $0 + "/" }.joined(separator: ", "))"
            }
            let name = newFolderName(String(path.dropFirst(parent.count + 1)))
            if name.isEmpty || name.contains("/") { return "\"new_folder\" must be the parent folder and one new folder name" }
            return nil
        }
        if !folders.contains(where: { $0.path == answer.folder }) {
            return "\"folder\" must be copied exactly from the list, or be \"\(noneFits)\""
        }
        return nil
    }

    static func newFolderName(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: " /\"'."))
    }

    static func suggestion(from answer: Placement, newFolderParents: [String], newName: String?) -> ClassifierSuggestion {
        let kind = answer.kind.trimmingCharacters(in: .whitespaces)
        let label = kind.isEmpty ? "" : kind.prefix(1).uppercased() + kind.dropFirst() + ": "
        let confidence = confidenceLevels[answer.confidence] ?? 0.4
        if answer.folder == noneFits, let path = answer.newFolder?.trimmingCharacters(in: .whitespaces),
           let parent = newFolderParents.first(where: { path.hasPrefix($0 + "/") }) {
            let folder = newFolderName(String(path.dropFirst(parent.count + 1)))
            return ClassifierSuggestion(destination: parent + "/" + folder, isNewFolder: true, newBaseName: newName,
                                        confidence: confidence,
                                        reason: "\(label)no existing folder fits, new folder \"\(folder)\". \(answer.reason)")
        }
        return ClassifierSuggestion(destination: answer.folder, newBaseName: newName, confidence: confidence,
                                    reason: label + answer.reason)
    }

    public func suggest(_ request: ClassificationRequest) async throws -> ClassifierSuggestion {
        var user = FactSummary.describe(request.facts, textLimit: Self.textLimit)
        if let card = cards[request.facts.url] { user = "About this file: \(card.line)\n\n" + user }
        let folders = request.folders, parents = request.newFolderParents
        let answer = try await ask(Placement.self, thinking: true, [
            .system(Self.instructions(folders: folders, review: request.reviewFolder, newFolderParents: parents,
                                      corrections: request.corrections)),
            .user(user),
        ]) { Self.problem(with: $0, folders: folders, newFolderParents: parents) }
        let newName = answer.newName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return Self.suggestion(from: answer, newFolderParents: parents, newName: newName)
    }

    public func placeGroup(_ request: GroupRequest) async throws -> GroupSuggestion {
        let shown = request.members.prefix(8)
        // The text budget is shared by the files shown.
        let each = max(300, min(1_500, Self.textLimit / max(shown.count, 1)))
        let list = shown.enumerated().map { index, member in
            var text = "File \(index + 1):\n"
            if let card = cards[member.url] { text += "About this file: \(card.line)\n" }
            return text + FactSummary.describe(member, textLimit: each)
        }
        let more = request.members.count > shown.count ? "\n\n(and \(request.members.count - shown.count) more like these)" : ""
        let user = "These \(request.members.count) downloaded files look like the same kind of thing (\(request.category)). "
            + "Where should they all go?\n\n" + list.joined(separator: "\n\n") + more
        let folders = request.folders, parents = request.newFolderParents
        let answer = try await ask(Placement.self, thinking: true, [
            .system(Self.instructions(folders: folders, review: request.reviewFolder, newFolderParents: parents,
                                      corrections: request.corrections, group: true)),
            .user(user),
        ]) { Self.problem(with: $0, folders: folders, newFolderParents: parents) }
        // Not asked whether they belong together: the group comes from the model's own cards.
        return GroupSuggestion(belongTogether: true,
                               suggestion: Self.suggestion(from: answer, newFolderParents: parents, newName: nil))
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

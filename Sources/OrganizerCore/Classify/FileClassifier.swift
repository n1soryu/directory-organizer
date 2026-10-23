import Foundation

/// One earlier file shown to the decision model: catalogued and similar to the new file.
public struct EarlierCandidate: Sendable, Equatable {
    /// "E1", "E2"…: what the model refers to it by.
    public var id: String
    /// Where it is now.
    public var path: String
    public var name: String
    /// Its folder relative to the home root: where it's filed, or where this plan proposes to put
    /// it. nil while it waits in Downloads.
    public var folder: String?
    /// This plan proposes the folder (it doesn't hold the file yet).
    public var isProposed: Bool
    /// What it is: its card as one line.
    public var about: String

    public init(id: String, path: String, name: String, folder: String?, isProposed: Bool = false, about: String) {
        self.id = id
        self.path = path
        self.name = name
        self.folder = folder
        self.isProposed = isProposed
        self.about = about
    }

    /// How the model sees where it is.
    public var shownFolder: String {
        guard let folder else { return "Downloads (waiting)" }
        return isProposed ? "\(folder) (proposed)" : folder
    }
}

/// Everything the model is given to decide where one leftover file goes.
public struct DecisionRequest: Sendable {
    public var facts: FileFacts
    /// Existing folders it may join (and folders this plan already proposes).
    public var folders: [FolderOption]
    /// Up to 5 similar earlier files, nearest first.
    public var earlier: [EarlierCandidate]
    /// Where a new folder may go for this kind of file ("Documents", "Pictures"…).
    public var newFolderParents: [String]
    /// Your past corrections that look relevant: "x.pdf doesn't belong in Documents/Manuals".
    public var corrections: [String] = []

    public init(facts: FileFacts, folders: [FolderOption], earlier: [EarlierCandidate], newFolderParents: [String],
                corrections: [String] = []) {
        self.facts = facts
        self.folders = folders
        self.earlier = earlier
        self.newFolderParents = newFolderParents
        self.corrections = corrections
    }
}

/// The model's decision for one file (the benchmark's Task 2 answer). A suggestion only: the
/// planner checks it again before anything reaches the plan.
public struct FolderDecision: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        /// Into an existing folder.
        case join
        /// A new folder, for this file and at least one earlier file.
        case newFolder = "new_folder"
        /// Nothing belongs with it yet: it stays in Downloads.
        case wait
    }

    public var reason: String
    public var action: Action
    /// Relative to the home root; nil for wait.
    public var folder: String?
    /// Ids of earlier files that move into `folder` too.
    public var moveEarlier: [String]
    public var newFileName: String?

    enum CodingKeys: String, CodingKey {
        case reason, action, folder
        case moveEarlier = "move_earlier"
        case newFileName = "new_file_name"
    }

    public init(reason: String, action: Action, folder: String? = nil, moveEarlier: [String] = [], newFileName: String? = nil) {
        self.reason = reason
        self.action = action
        self.folder = folder
        self.moveEarlier = moveEarlier
        self.newFileName = newFileName
    }

    /// What's wrong with the answer for this request, worded for the model; nil if it can be used.
    /// The planner checks the same things (and more: the disk) once more afterwards.
    public func problem(in request: DecisionRequest) -> String? {
        let ids = Set(request.earlier.map(\.id))
        if let unknown = moveEarlier.first(where: { !ids.contains($0) }) {
            return ids.isEmpty
                ? "\"move_earlier\" must be [] because no earlier files are listed"
                : "\"move_earlier\" may only use ids from the list (\(request.earlier.map(\.id).joined(separator: ", "))), not \"\(unknown)\""
        }
        let folder = self.folder?.trimmingCharacters(in: .whitespaces)
        switch action {
        case .wait:
            if folder != nil && folder != "" { return "for \"wait\", \"folder\" must be null" }
            if !moveEarlier.isEmpty { return "for \"wait\", \"move_earlier\" must be []" }
        case .join:
            guard let folder, request.folders.contains(where: { $0.path == folder }) else {
                return "for \"join\", \"folder\" must be copied exactly from the list of existing folders"
            }
        case .newFolder:
            guard let folder, !folder.isEmpty else { return "for \"new_folder\", \"folder\" must be a path" }
            guard request.newFolderParents.contains(where: { folder.hasPrefix($0 + "/") && folder.count > $0.count + 1 }) else {
                return "for \"new_folder\", \"folder\" must start with \(request.newFolderParents.map { "\"\($0)/\"" }.joined(separator: " or "))"
            }
            if request.folders.contains(where: { $0.path == folder }) {
                return "for \"new_folder\", \"folder\" must not already exist; use \"join\" for an existing folder"
            }
            let moving = request.earlier.filter { moveEarlier.contains($0.id) && $0.folder != folder }
            if moving.isEmpty {
                return "for \"new_folder\", \"move_earlier\" must list at least one earlier file id"
            }
        }
        return nil
    }
}

/// Whether a downloaded folder is one thing (a project, an album, a course pack) or just a
/// container of separate files that each belong somewhere else.
public struct UnpackSuggestion: Codable, Sendable {
    public var unpack: Bool
    /// What the folder is, in a few words ("photo album", "mixed downloads").
    public var kind: String
    public var confidence: Double
    public var reason: String

    public init(unpack: Bool, kind: String = "", confidence: Double, reason: String) {
        self.unpack = unpack
        self.kind = kind
        self.confidence = confidence
        self.reason = reason
    }
}

/// A suggested name for a file whose own name says nothing ("IMG_4821", "download").
public struct NameSuggestion: Codable, Sendable {
    /// A few words describing the file, without extension or date ("Router login page").
    public var title: String
    public var confidence: Double

    public init(title: String, confidence: Double) {
        self.title = title
        self.confidence = confidence
    }
}

public enum ClassifierError: Error, Equatable, CustomStringConvertible {
    /// The model can't run right now (turned off, still downloading, no model in use).
    case unavailable(String)
    /// The model declined to answer (safety guardrails, refusal).
    case declined(String)
    /// The model's answers stayed invalid after the retries.
    case invalidAnswer(String)

    public var description: String {
        switch self {
        case .unavailable(let why): "model unavailable: \(why)"
        case .declined(let why): "model declined: \(why)"
        case .invalidAnswer(let why): "model gave no valid answer (\(why))"
        }
    }
}

/// Anything that can suggest where a file belongs and what to call it. `MLXClassifier`
/// (Qwen3 on this Mac) implements it; tests use fakes. One protocol so models can be swapped and compared.
public protocol FileClassifier: Sendable {
    var name: String { get }
    /// Where a leftover file goes: into an existing folder, into a new folder together with
    /// earlier files, or nowhere yet (it waits in Downloads).
    func decide(_ request: DecisionRequest) async throws -> FolderDecision
    func suggestName(for facts: FileFacts) async throws -> NameSuggestion
    /// Keep a downloaded folder together, or unpack it so each item inside is placed on its own?
    func suggestUnpack(for facts: FileFacts) async throws -> UnpackSuggestion
    /// What one of your folders is for, in a few words, from what's in it.
    func describeFolder(_ profile: FolderProfile) async throws -> String
    /// What a file is, in full (kind, issuer, subject, summary...): what the catalog keeps.
    func card(for facts: FileFacts) async throws -> FileCard
}

extension FileClassifier {
    /// Without a model there are no cards, and nothing is catalogued.
    public func card(for facts: FileFacts) async throws -> FileCard {
        throw ClassifierError.unavailable("no model in use")
    }

    /// Without a model a folder is never unpacked: it stays together.
    public func suggestUnpack(for facts: FileFacts) async throws -> UnpackSuggestion {
        throw ClassifierError.unavailable("no model in use")
    }

    /// Without a model a folder's purpose stays unknown.
    public func describeFolder(_ profile: FolderProfile) async throws -> String {
        throw ClassifierError.unavailable("no model in use")
    }
}

/// No model: leftovers go to review. Used by tests and `--no-model`.
public struct StubClassifier: FileClassifier {
    public let name = "none"
    public init() {}

    public func decide(_ request: DecisionRequest) async throws -> FolderDecision {
        throw ClassifierError.unavailable("no model in use")
    }

    public func suggestName(for facts: FileFacts) async throws -> NameSuggestion {
        throw ClassifierError.unavailable("no model in use")
    }
}

/// A move of the model's you undid: a sign of where a kind of file does *not* go.
public struct Correction: Codable, Sendable, Equatable {
    public var fileName: String
    /// Relative to the home root.
    public var wrongFolder: String

    public init(fileName: String, wrongFolder: String) {
        self.fileName = fileName
        self.wrongFolder = wrongFolder
    }

    public var sentence: String { "\"\(fileName)\" does not belong in \(wrongFolder)" }

    /// Model moves you undid, newest first.
    public static func from(_ records: [MoveRecord], homeRoot: URL) -> [Correction] {
        let home = homeRoot.standardizedFileURL.path + "/"
        return records
            .filter { $0.state == .undone && ($0.decidedBy?.hasPrefix("model") ?? false) }
            .sorted { $0.time > $1.time }
            .compactMap { record in
                let folder = URL(filePath: record.movedPath).deletingLastPathComponent().standardizedFileURL.path
                guard folder.hasPrefix(home) else { return nil }
                return Correction(fileName: URL(filePath: record.originalPath).lastPathComponent,
                                  wrongFolder: String(folder.dropFirst(home.count)))
            }
    }
}

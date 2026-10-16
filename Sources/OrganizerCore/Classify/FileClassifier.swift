import Foundation

/// Everything a classifier is given for one file: the facts, and the only answers allowed.
public struct ClassificationRequest: Sendable {
    public var facts: FileFacts
    /// Existing folders it may choose from.
    public var folders: [FolderOption]
    /// Where it may propose a new folder (depends on the file type: images under Pictures...).
    public var newFolderParents: [String]
    /// Where uncertain files go.
    public var reviewFolder: String
    /// Your past corrections that look relevant: "x.pdf doesn't belong in Documents/FSAE".
    public var corrections: [String] = []
}

/// What a model may say about a file: a suggestion, never an action.
/// The planner checks it (allowed folder, sane name, confidence) before it reaches the plan.
public struct ClassifierSuggestion: Codable, Sendable {
    /// Folder relative to the home root: one of the offered folders, or parent + "/" + new name
    /// when `isNewFolder` is true.
    public var destination: String
    public var isNewFolder: Bool
    public var newBaseName: String?
    /// 0...1.
    public var confidence: Double
    public var reason: String

    public init(destination: String, isNewFolder: Bool = false, newBaseName: String? = nil,
                confidence: Double, reason: String) {
        self.destination = destination
        self.isNewFolder = isNewFolder
        self.newBaseName = newBaseName
        self.confidence = confidence
        self.reason = reason
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

/// What a file is, in the model's words: the label similar files are grouped by.
public struct FileDescription: Codable, Sendable, Equatable {
    /// Specific: "air fryer user manual", "electricity bill".
    public var kind: String
    /// General, like a folder name: "Manuals", "Bills".
    public var category: String

    public init(kind: String, category: String) {
        self.kind = kind
        self.category = category
    }
}

/// Several downloads the model described as the same kind of thing, to be placed together.
public struct GroupRequest: Sendable {
    public var members: [FileFacts]
    /// The category they share ("Bills").
    public var category: String
    public var folders: [FolderOption]
    public var newFolderParents: [String]
    public var reviewFolder: String
    public var corrections: [String] = []
}

/// Where a group goes, or that its files aren't really alike (then each is placed on its own).
public struct GroupSuggestion: Sendable {
    public var belongTogether: Bool
    public var suggestion: ClassifierSuggestion

    public init(belongTogether: Bool, suggestion: ClassifierSuggestion) {
        self.belongTogether = belongTogether
        self.suggestion = suggestion
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

    public var description: String {
        switch self {
        case .unavailable(let why): "model unavailable: \(why)"
        case .declined(let why): "model declined: \(why)"
        }
    }
}

/// Anything that can suggest where a file belongs and what to call it. Apple's on-device
/// model implements it; tests use fakes. One protocol so models can be swapped and compared.
public protocol FileClassifier: Sendable {
    var name: String { get }
    func suggest(_ request: ClassificationRequest) async throws -> ClassifierSuggestion
    func suggestName(for facts: FileFacts) async throws -> NameSuggestion
    /// Keep a downloaded folder together, or unpack it so each item inside is placed on its own?
    func suggestUnpack(for facts: FileFacts) async throws -> UnpackSuggestion
    /// What one of your folders is for, in a few words, from what's in it.
    func describeFolder(_ profile: FolderProfile) async throws -> String
    /// What a downloaded file is, specific and general (for grouping similar files).
    func describe(_ facts: FileFacts) async throws -> FileDescription
    /// One folder for a group of similar files.
    func placeGroup(_ request: GroupRequest) async throws -> GroupSuggestion
}

extension FileClassifier {
    /// Without a model a folder is never unpacked: it stays together.
    public func suggestUnpack(for facts: FileFacts) async throws -> UnpackSuggestion {
        throw ClassifierError.unavailable("no model in use")
    }

    /// Without a model a folder's purpose stays unknown.
    public func describeFolder(_ profile: FolderProfile) async throws -> String {
        throw ClassifierError.unavailable("no model in use")
    }

    /// Without a model nothing is grouped: every file is placed on its own.
    public func describe(_ facts: FileFacts) async throws -> FileDescription {
        throw ClassifierError.unavailable("no model in use")
    }

    public func placeGroup(_ request: GroupRequest) async throws -> GroupSuggestion {
        throw ClassifierError.unavailable("no model in use")
    }
}

/// No model: leftovers go to review. Used by tests and `--no-model`.
public struct StubClassifier: FileClassifier {
    public let name = "none"
    public init() {}

    public func suggest(_ request: ClassificationRequest) async throws -> ClassifierSuggestion {
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

import Foundation

/// One on-device model the app downloads and runs with MLX (see docs/mlx-plan.md).
/// The revision is a pinned Hugging Face commit, so a model never changes under the app:
/// a new revision is a deliberate update, and embeddings from different revisions are never mixed.
public struct ModelSpec: Sendable, Hashable, Codable, Identifiable {
    public enum Role: String, Sendable, Codable {
        /// Writes cards and makes decisions.
        case language
        /// Turns cards into vectors for finding similar files.
        case embedder

        /// Big models share one slot: only one is ever loaded (16 GB Macs can't hold two).
        public var isLarge: Bool { self == .language }
    }

    /// Hugging Face repository, "org/name".
    public var repo: String
    /// Commit SHA of the repository.
    public var revision: String
    public var role: Role
    public var displayName: String
    /// What the download weighs (the files MLX fetches: weights, configs, tokenizer).
    public var downloadBytes: Int64

    public var id: String { "\(repo)@\(revision)" }

    public init(repo: String, revision: String, role: Role, displayName: String, downloadBytes: Int64) {
        self.repo = repo
        self.revision = revision
        self.role = role
        self.displayName = displayName
        self.downloadBytes = downloadBytes
    }

    /// Qwen3 8B, 4-bit DWQ: the benchmark's best for decisions (11/12 with thinking on).
    public static let language = ModelSpec(
        repo: "mlx-community/Qwen3-8B-4bit-DWQ",
        revision: "abdc7a619e12b13119e292c889ebf8e90f4ef592",
        role: .language, displayName: "Qwen3 8B", downloadBytes: 4_622_110_681)

    /// Qwen3 Embedding 0.6B, 4-bit DWQ: 1,024-number vectors, ~36 ms per file in the benchmark.
    public static let embedder = ModelSpec(
        repo: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
        revision: "6c3ae70858513f1a78e9cdca3cae330d9075cd2a",
        role: .embedder, displayName: "Qwen3 Embedding 0.6B", downloadBytes: 349_558_958)

    /// Everything "Download models" fetches. The vision model joins in Milestone C.
    public static let all: [ModelSpec] = [language, embedder]
}

/// Where downloaded models live, and which of them are complete.
///
/// The files themselves are laid out by the Hugging Face client (`models--org--name/...`).
/// A model only counts as ready once its download finished: a marker is written after the
/// last file arrives, so a cancelled or half-finished download never looks usable.
public struct ModelStore: Sendable {
    public let directory: URL

    public init(directory: URL = ModelStore.defaultDirectory) {
        self.directory = directory
    }

    /// ~/Library/Application Support/DirectoryOrganizer/Models, in sandbox mode too:
    /// the sandbox protects your files, and models aren't your files.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/DirectoryOrganizer/Models")
    }

    /// The Hugging Face client's snapshot folder for this exact revision.
    public func snapshotDirectory(for spec: ModelSpec) -> URL {
        directory
            .appending(path: "models--" + spec.repo.replacingOccurrences(of: "/", with: "--"))
            .appending(path: "snapshots/\(spec.revision)")
    }

    private func marker(for spec: ModelSpec) -> URL {
        directory.appending(path: ".ready").appending(path: spec.repo.replacingOccurrences(of: "/", with: "--") + "@" + spec.revision)
    }

    /// Downloaded completely, and the files are still there.
    public func isReady(_ spec: ModelSpec) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: marker(for: spec).path) && fm.fileExists(atPath: snapshotDirectory(for: spec).path)
    }

    public func markReady(_ spec: ModelSpec) throws {
        let url = marker(for: spec)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    public func missing(_ specs: [ModelSpec] = ModelSpec.all) -> [ModelSpec] {
        specs.filter { !isReady($0) }
    }

    /// Free space on the volume the models go to (what macOS would free up for an important download).
    public func availableBytes() -> Int64? {
        var url = directory
        // The folder may not exist yet: ask about the nearest one that does.
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}

/// Is there room for a download? Keeps a margin so the disk isn't filled to the last byte.
public enum SpaceCheck: Sendable, Equatable {
    case enough
    case short(by: Int64)
    /// macOS didn't say; the download is attempted anyway.
    case unknown

    public static let margin: Int64 = 1_000_000_000

    public static func check(needed: Int64, available: Int64?, margin: Int64 = margin) -> SpaceCheck {
        guard let available else { return .unknown }
        let required = needed + margin
        return available >= required ? .enough : .short(by: required - available)
    }
}

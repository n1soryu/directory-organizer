import Foundation
import MLXLMCommon
import OrganizerCore

public enum ModelDownloadError: LocalizedError {
    case notEnoughSpace(needed: Int64, short: Int64)

    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed, let short):
            let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            return "Not enough free space: the models need \(format(needed)) plus 1 GB to spare; free up \(format(short)) more."
        }
    }
}

/// Downloads models into the model folder, once. Files that finished downloading are kept,
/// so after an interruption only the rest is fetched. Only this ever uses the network.
public struct ModelDownloader: Sendable {
    public let store: ModelStore

    public init(store: ModelStore = ModelStore()) {
        self.store = store
    }

    /// Checks free space for everything missing, then downloads each missing model.
    /// `progress` gets the model and its fraction done (0...1), on the main actor.
    public func downloadMissing(_ specs: [ModelSpec] = ModelSpec.all,
                                progress: @escaping @MainActor @Sendable (ModelSpec, Double) -> Void) async throws {
        let missing = store.missing(specs)
        let needed = missing.reduce(0) { $0 + $1.downloadBytes }
        if case .short(let short) = SpaceCheck.check(needed: needed, available: store.availableBytes()) {
            throw ModelDownloadError.notEnoughSpace(needed: needed, short: short)
        }
        for spec in missing {
            try Task.checkCancellation()
            try await download(spec) { fraction in progress(spec, fraction) }
        }
    }

    public func download(_ spec: ModelSpec, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        // `resolve` fetches exactly the files MLX loads (weights, configs, tokenizer).
        _ = try await resolve(
            configuration: ModelConfiguration(id: spec.repo, revision: spec.revision),
            from: HubDownloader(store: store, localOnly: false), useLatest: false,
            progressHandler: { p in
                let fraction = p.fractionCompleted
                Task { @MainActor in progress(fraction) }
            })
        try Task.checkCancellation()
        try store.markReady(spec)
    }
}

import Foundation
import OrganizerCore
import OrganizerMLX

/// The on-device MLX models: which are downloaded, and the one "Download Models" action.
/// Nothing uses them yet (Milestone B switches the organizer over); this gets them onto the Mac.
@MainActor @Observable
final class LocalModels {
    enum Status: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    let store = ModelStore()
    private(set) var status: [ModelSpec.ID: Status] = [:]
    private(set) var freeBytes: Int64?
    private var task: Task<Void, Never>?

    var isDownloading: Bool { task != nil }
    var missing: [ModelSpec] { ModelSpec.all.filter { status[$0.id] != .ready } }
    var missingBytes: Int64 { missing.reduce(0) { $0 + $1.downloadBytes } }
    var allReady: Bool { missing.isEmpty }

    func refresh() {
        guard !isDownloading else { return }
        for spec in ModelSpec.all {
            if store.isReady(spec) {
                status[spec.id] = .ready
            } else if case .failed = status[spec.id] {
                // Keep the error visible until the next try.
            } else {
                status[spec.id] = .notDownloaded
            }
        }
        freeBytes = store.availableBytes()
    }

    /// Downloads every missing model, one after the other. `finished` gets nil on success,
    /// or what went wrong (a cancel counts as neither: it just stops).
    func downloadMissing(finished: @escaping @MainActor (String?) -> Void) {
        guard !isDownloading else { return }
        refresh()
        if case .short(let short) = SpaceCheck.check(needed: missingBytes, available: freeBytes) {
            finished(ModelDownloadError.notEnoughSpace(needed: missingBytes, short: short).localizedDescription)
            return
        }
        let downloader = ModelDownloader(store: store)
        let specs = missing
        task = Task {
            var failure: String?
            for spec in specs {
                status[spec.id] = .downloading(0)
                do {
                    try await downloader.download(spec) { [weak self] fraction in
                        // Late progress callbacks must not overwrite "ready".
                        if case .downloading = self?.status[spec.id] { self?.status[spec.id] = .downloading(fraction) }
                    }
                    status[spec.id] = .ready
                } catch is CancellationError {
                    status[spec.id] = .notDownloaded
                    break
                } catch {
                    if Task.isCancelled { status[spec.id] = .notDownloaded; break }
                    status[spec.id] = .failed(error.localizedDescription)
                    failure = "Couldn't download \(spec.displayName): \(error.localizedDescription)"
                    break
                }
            }
            let cancelled = Task.isCancelled
            task = nil
            refresh()
            if !cancelled { finished(failure) }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

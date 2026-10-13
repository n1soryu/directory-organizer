import Foundation

/// What happened to one approved action.
public struct ApplyResult: Sendable {
    public enum Outcome: Sendable, Equatable {
        case moved
        case skipped(String)
        case failed(String)
    }

    public var action: ProposedAction
    public var outcome: Outcome
    public var destination: URL?
    /// Problems after the move itself succeeded (e.g. tags couldn't be written).
    public var warnings: [String] = []
}

/// Carries out approved actions: re-checks each one, creates folders, moves without
/// overwriting, tags, and logs every step. The only code in the app that moves files.
public struct Applier: Sendable {
    public var config: OrganizerConfig
    public var homeRoot: URL
    public var journal: MoveJournal
    /// Files larger than this aren't hashed for the log (a 20 GB film would take minutes).
    public var maxHashedSize: Int64 = 1 << 30

    public init(config: OrganizerConfig = OrganizerConfig(), homeRoot: URL, journal: MoveJournal) {
        self.config = config
        self.homeRoot = homeRoot.standardizedFileURL
        self.journal = journal
    }

    /// Applies the actions as one batch (undone together by `undo --last`).
    public func apply(_ actions: [ProposedAction], batchID: UUID = UUID()) -> [ApplyResult] {
        _ = try? journal.recover()
        return actions.map { apply($0, batchID: batchID) }
    }

    private func apply(_ action: ProposedAction, batchID: UUID) -> ApplyResult {
        let fm = FileManager.default
        let source = action.source

        // 1. The file must be exactly as it was when planned. (Asks the disk directly:
        //    URL.resourceValues can return values cached while planning.)
        var fresh = source
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return ApplyResult(action: action, outcome: .skipped(MoveError.sourceMissing(source.path).description))
        }
        if Int64(values.fileSize ?? 0) != action.sourceSize || values.contentModificationDate != action.sourceModified {
            return ApplyResult(action: action, outcome: .skipped(MoveError.sourceChanged(action.originalName).description))
        }

        // 2. Check the destination again: the plan could be old, or edited.
        if let problem = DestinationValidator.problem(with: action.destinationFolder, config: config) {
            return ApplyResult(action: action, outcome: .failed(MoveError.invalidDestination(problem).description))
        }
        guard FileNames.sanitize(action.finalName) == action.finalName, !action.finalName.isEmpty else {
            return ApplyResult(action: action, outcome: .failed(MoveError.invalidDestination("bad file name \(action.finalName)").description))
        }

        // 3. Create missing folders one level at a time, so we know exactly which ones we made,
        //    and make sure no symlink leads outside the home folder.
        let realHome = homeRoot.resolvingSymlinksInPath().path
        var folder = homeRoot
        var created: [URL] = []
        func undoFolders() { for url in created.reversed() { SafeMove.removeIfEmpty(url) } }
        for part in action.destinationFolder.split(separator: "/") {
            folder.append(path: String(part), directoryHint: .isDirectory)
            if !fm.fileExists(atPath: folder.path) {
                do {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                    created.append(folder)
                } catch {
                    undoFolders()
                    return ApplyResult(action: action, outcome: .failed("couldn't create \(folder.path): \(error.localizedDescription)"))
                }
            }
            guard folder.resolvingSymlinksInPath().path.hasPrefix(realHome + "/") else {
                undoFolders()
                return ApplyResult(action: action, outcome: .failed(MoveError.outsideHome(folder.path).description))
            }
        }
        let destination = folder.appending(path: action.finalName)

        // 4. Log the intent before touching the file (write-ahead).
        let moveID = UUID()
        let tagsBefore = FinderTags.readRaw(source)
        let hash = action.sourceSize <= maxHashedSize ? try? FileHash.sha256(source) : nil
        var entry = JournalEntry(
            event: .movePending, time: Date(), moveID: moveID, batchID: batchID,
            from: source.path, to: destination.path, sha256: hash, tagsBefore: tagsBefore,
            createdFolders: created.map(\.path), decidedBy: action.decidedBy.description, reason: action.reason)
        do {
            try journal.append(entry)
        } catch {
            undoFolders()
            return ApplyResult(action: action, outcome: .failed("couldn't write the move log, so nothing was moved: \(error)"))
        }

        // 5. Move: atomic, never overwrites.
        do {
            try SafeMove.move(source, to: destination)
        } catch {
            undoFolders()
            entry.event = .moveFailed
            entry.time = Date()
            entry.message = "\(error)"
            try? journal.append(entry)
            return ApplyResult(action: action, outcome: .failed("\(error)"))
        }

        // 6. Tags and the origin note. The move already succeeded, so problems here are warnings.
        var warnings: [String] = []
        let tagsAfter = FinderTags.merge(existing: tagsBefore, adding: action.tags)
        do { try FinderTags.writeRaw(tagsAfter, to: destination) } catch { warnings.append("tags not written: \(error)") }
        do {
            try MoveOrigin.write(.init(originalPath: source.path, movedAt: Date(), moveID: moveID), to: destination)
        } catch {
            warnings.append("origin note not written: \(error)")
        }

        entry.event = .moveDone
        entry.time = Date()
        entry.tagsAfter = tagsAfter
        entry.message = warnings.isEmpty ? nil : warnings.joined(separator: "; ")
        do { try journal.append(entry) } catch { warnings.append("move done but not logged: \(error)") }
        return ApplyResult(action: action, outcome: .moved, destination: destination, warnings: warnings)
    }
}

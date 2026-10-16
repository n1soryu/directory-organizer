import Foundation

public struct UndoResult: Sendable {
    public var record: MoveRecord
    /// Where the file was put back, if it was.
    public var restoredTo: URL?
    public var error: String?
    /// Things worth knowing ("restored under a dated name", "file was edited since").
    public var notes: [String] = []
}

/// Puts moved files back exactly as they were: original folder and name, original tags,
/// no origin note, and folders the move created removed again if they're empty.
public struct Undoer: Sendable {
    public var journal: MoveJournal

    public init(journal: MoveJournal) {
        self.journal = journal
    }

    /// Moves that can be undone (currently moved), newest first.
    public func undoable() throws -> [MoveRecord] {
        try journal.recover()
        return try journal.records().filter { $0.state == .moved }.reversed()
    }

    /// Undoes the given moves, newest first (so nested folders empty out in the right order).
    public func undo(_ records: [MoveRecord]) -> [UndoResult] {
        records.sorted { $0.time > $1.time }.map(undo)
    }

    private func undo(_ record: MoveRecord) -> UndoResult {
        let fm = FileManager.default
        let current = URL(filePath: record.movedPath)
        var result = UndoResult(record: record)

        guard fm.fileExists(atPath: current.path) else {
            result.error = "\(current.lastPathComponent) is no longer at \(current.deletingLastPathComponent().path); was it moved or deleted?"
            return result
        }
        // The same file: same content, or our origin note with this move's ID on it (then it
        // was edited since). A different file that took its place is never "put back".
        let contentMatches = record.sha256.map { (try? FileHash.sha256(current)) == $0 } ?? false
        let ourNote = MoveOrigin.read(current)?.moveID == record.moveID
        guard contentMatches || ourNote else {
            result.error = "\(current.lastPathComponent) at \(current.deletingLastPathComponent().path) isn't the file that was moved there (different content, no trace of the move); nothing was changed"
            return result
        }
        if !contentMatches, record.sha256 != nil {
            result.notes.append("the file was edited after it was moved; it goes back with your edits")
        }

        // Back to the original name, unless something new took it in the meantime.
        let original = URL(filePath: record.originalPath)
        let folder = original.deletingLastPathComponent()
        // A folder replaced by a symlink since would send the file somewhere else entirely.
        if (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            result.error = "\(folder.path) is now a link to somewhere else; nothing was changed"
            return result
        }
        var target = original
        if fm.fileExists(atPath: target.path) {
            let ext = original.pathExtension
            let base = original.deletingPathExtension().lastPathComponent
            // The dated names first; if all are taken, a unique one (as when filing).
            let names = FileNames.clashAlternatives(base, ext, date: Date())
                + [FileNames.join("\(base) \(UUID().uuidString.prefix(8))", ext)]
            guard let free = names.map({ folder.appending(path: $0) }).first(where: { !fm.fileExists(atPath: $0.path) }) else {
                result.error = "no free name for \(original.lastPathComponent) in \(folder.path)"
                return result
            }
            target = free
            result.notes.append("\(original.lastPathComponent) is taken by another file, so it was restored as \(target.lastPathComponent)")
        }

        var entry = JournalEntry(event: .undoPending, time: Date(), moveID: record.moveID, batchID: record.batchID,
                                 from: current.path, to: target.path, message: result.notes.joined(separator: "; ").nilIfEmpty)
        do {
            try journal.append(entry)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try SafeMove.move(current, to: target)
        } catch {
            entry.event = .undoFailed
            entry.time = Date()
            entry.message = "\(error)"
            try? journal.append(entry)
            result.error = "\(error)"
            return result
        }

        result.notes += Self.finish(record, at: target)

        entry.event = .undoDone
        entry.time = Date()
        try? journal.append(entry)
        result.restoredTo = target
        return result
    }
}

extension Undoer {
    /// After the file is back: tags exactly as before, no trace of the app on it, and the
    /// folders the move created removed if they're empty. Also used by recovery, when an undo
    /// was interrupted after the file moved back. Returns what couldn't be done.
    static func finish(_ record: MoveRecord, at target: URL) -> [String] {
        var problems: [String] = []
        do { try FinderTags.writeRaw(record.tagsBefore, to: target) } catch { problems.append("tags not restored: \(error)") }
        do { try MoveOrigin.remove(from: target) } catch { problems.append("origin note not removed: \(error)") }
        // Innermost first. rmdir refuses non-empty folders, so anything you (or another move)
        // put there keeps the folder alive.
        for path in record.createdFolders.reversed() {
            SafeMove.removeIfEmpty(URL(filePath: path))
        }
        return problems
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

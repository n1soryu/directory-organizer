import Foundation

/// One line of the move log. The log is append-only JSON Lines: one entry per line,
/// never edited. A move writes `movePending` before touching the file and `moveDone`
/// after, so a crash in between can be worked out later (write-ahead logging).
public struct JournalEntry: Codable, Sendable {
    public enum Event: String, Codable, Sendable {
        case movePending, moveDone, moveFailed
        case undoPending, undoDone, undoFailed
    }

    public var event: Event
    public var time: Date
    /// Identifies the move this entry is about; undo entries reuse it.
    public var moveID: UUID
    /// All moves approved together share a batch, so they can be undone together.
    public var batchID: UUID

    /// Absolute paths. For undo entries, `from` is where the file was and `to` where it goes back.
    public var from: String
    public var to: String
    public var sha256: String?
    /// Tags exactly as they were before the move (raw "Name\nColor" strings).
    public var tagsBefore: [String]?
    public var tagsAfter: [String]?
    /// Folders the move created, outermost first. Undo removes them again if empty.
    public var createdFolders: [String]?
    public var decidedBy: String?
    public var reason: String?
    /// Errors and notes ("restored as ... because the name was taken").
    public var message: String?
}

/// The current state of one move, rebuilt from its journal entries.
public struct MoveRecord: Sendable {
    public enum State: String, Sendable {
        /// Logged as starting, never finished: needs recovery.
        case pending
        case moved
        case failed
        case undoPending
        case undone
    }

    public var moveID: UUID
    public var batchID: UUID
    public var time: Date
    /// The original location, the one undo restores.
    public var originalPath: String
    /// Where the move put the file.
    public var movedPath: String
    /// Where undo put it back (may differ from `originalPath` if that name was taken).
    public var restoredPath: String?
    public var sha256: String?
    public var tagsBefore: [String]
    public var tagsAfter: [String]
    public var createdFolders: [String]
    public var reason: String?
    /// "rule: course", "model: apple", "safety: duplicate".
    public var decidedBy: String?
    public var state: State
}

public struct MoveJournal: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Where the move log for `home` lives. For the sandbox it sits next to the stand-in
    /// home (`TestData/moves.jsonl`); for your real home it's in Application Support, since
    /// the folder above your home (`/Users`) isn't yours to write in.
    public static func url(forHome home: URL) -> URL {
        if FolderAccess.isRealUserFolder(home) {
            return FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/DirectoryOrganizer/moves.jsonl")
        }
        return home.standardizedFileURL.deletingLastPathComponent().appending(path: "moves.jsonl")
    }

    /// Appends one entry and flushes it to disk before returning.
    public func append(_ entry: JournalEntry) throws {
        var line = try Self.encoder.encode(entry)
        line.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw MoveError.system("opening the move log", errno) }
        defer { close(fd) }
        // A line cut short by a crash has no newline; start on a fresh line so this entry
        // isn't glued onto the broken one (and lost with it).
        var info = stat()
        var last: UInt8 = 0x0A
        if fstat(fd, &info) == 0, info.st_size > 0, pread(fd, &last, 1, info.st_size - 1) == 1, last != 0x0A {
            line.insert(0x0A, at: 0)
        }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
        guard written == line.count else { throw MoveError.system("writing the move log", errno) }
        // fsync: the entry is on disk before we touch the file it describes.
        fsync(fd)
    }

    /// Every readable entry, oldest first. A line that can't be read (cut short by a power
    /// loss mid-write, say) is skipped, so one bad line never hides the rest of the history.
    public func entries() throws -> [JournalEntry] {
        try read().entries
    }

    /// How many lines of the log couldn't be read and were skipped.
    public func damagedLineCount() throws -> Int {
        try read().damaged
    }

    private func read() throws -> (entries: [JournalEntry], damaged: Int) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], 0) }
        let lines = try Data(contentsOf: url).split(separator: 0x0A)
        let entries = lines.compactMap { try? Self.decoder.decode(JournalEntry.self, from: Data($0)) }
        return (entries, lines.count - entries.count)
    }

    /// Every move with its current state, oldest first.
    public func records() throws -> [MoveRecord] {
        var byID: [UUID: MoveRecord] = [:]
        var order: [UUID] = []
        for entry in try entries() {
            switch entry.event {
            case .movePending:
                order.append(entry.moveID)
                byID[entry.moveID] = MoveRecord(
                    moveID: entry.moveID, batchID: entry.batchID, time: entry.time,
                    originalPath: entry.from, movedPath: entry.to, sha256: entry.sha256,
                    tagsBefore: entry.tagsBefore ?? [], tagsAfter: entry.tagsAfter ?? [],
                    createdFolders: entry.createdFolders ?? [], reason: entry.reason,
                    decidedBy: entry.decidedBy, state: .pending)
            case .moveDone:
                byID[entry.moveID]?.state = .moved
                if let tags = entry.tagsAfter { byID[entry.moveID]?.tagsAfter = tags }
            case .moveFailed:
                byID[entry.moveID]?.state = .failed
            case .undoPending:
                byID[entry.moveID]?.state = .undoPending
                byID[entry.moveID]?.restoredPath = entry.to
            case .undoDone:
                byID[entry.moveID]?.state = .undone
                byID[entry.moveID]?.restoredPath = entry.to
            case .undoFailed:
                byID[entry.moveID]?.state = .moved
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// Settles moves that were interrupted (crash, power loss) by checking where the file
    /// actually is, and logs the outcome. Returns how many were settled.
    @discardableResult
    public func recover() throws -> Int {
        let fm = FileManager.default
        var settled = 0
        for record in try records() {
            let event: JournalEntry.Event
            switch record.state {
            case .pending:
                // The move happened if the file is at the destination and not at the source.
                event = fm.fileExists(atPath: record.movedPath) && !fm.fileExists(atPath: record.originalPath)
                    ? .moveDone : .moveFailed
            case .undoPending:
                let back = record.restoredPath ?? record.originalPath
                event = fm.fileExists(atPath: back) && !fm.fileExists(atPath: record.movedPath) ? .undoDone : .undoFailed
            default:
                continue
            }
            try append(JournalEntry(event: event, time: Date(), moveID: record.moveID, batchID: record.batchID,
                                    from: record.state == .pending ? record.originalPath : record.movedPath,
                                    to: record.state == .pending ? record.movedPath : (record.restoredPath ?? record.originalPath),
                                    message: "recovered after an interrupted run"))
            settled += 1
        }
        return settled
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

import Foundation

/// One carded file in the catalog: what it is (its card) and where it sits in meaning (its
/// embedding). Entries are only ever appended; the newest entry for a file wins.
public struct CatalogEntry: Codable, Sendable, Equatable {
    public enum CardSource: String, Codable, Sendable {
        /// Qwen3 8B read the file's text.
        case text
        /// The vision model looked at the image.
        case vision
        /// No card: the first part of the file's text was embedded instead.
        case rawText
    }

    public var time: Date
    /// Recognises the file under any name, anywhere. nil only for files too big to hash.
    public var sha256: String?
    /// The move that filed it, for files carded after the fact (back-fill).
    public var moveID: UUID?
    /// Where it was when it was carded.
    public var path: String
    public var card: FileCard?
    public var cardSource: CardSource
    /// The text that was embedded: the card as one line, or the start of the file's text.
    public var line: String
    /// 1,024 numbers as Float16, base64 (`Vectors`).
    public var embedding: String
    /// `ModelSpec.id` of the embedder: vectors of different models are never compared.
    public var embedder: String
    public var decidedBy: String?
    /// The model said "wait": it stays in Downloads and isn't decided again until a similar
    /// file arrives. (nil in entries from before decisions used the catalog.)
    public var waited: Bool?

    public init(time: Date = Date(), sha256: String?, moveID: UUID? = nil, path: String, card: FileCard?,
                cardSource: CardSource, line: String, embedding: String, embedder: String, decidedBy: String? = nil,
                waited: Bool? = nil) {
        self.time = time
        self.sha256 = sha256
        self.moveID = moveID
        self.path = path
        self.card = card
        self.cardSource = cardSource
        self.line = line
        self.embedding = embedding
        self.embedder = embedder
        self.decidedBy = decidedBy
        self.waited = waited
    }

    /// Which file this is about: its content hash, or the move for an unhashed file.
    public var key: String? { sha256 ?? moveID.map { "move:\($0.uuidString)" } }

    /// What gets embedded for a card (the benchmark's best: kind, issuer, subject, summary).
    public static func line(for card: FileCard) -> String { card.line }

    /// Without a card: the start of the file's text, if it has any.
    public static func line(forText text: String?) -> String? {
        let text = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(1_000))
    }
}

/// Embeddings stored compactly: Float16 halves the size (~2 KB per file) and loses nothing
/// that matters for ranking.
public enum Vectors {
    public static func encode(_ vector: [Float]) -> String {
        let halves = vector.map { Float16($0) }
        return halves.withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    public static func decode(_ string: String) -> [Float]? {
        guard let data = Data(base64Encoded: string), data.count % MemoryLayout<Float16>.size == 0 else { return nil }
        let halves = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        return halves.map { Float($0) }
    }

    /// Cosine similarity. The embedder's vectors are unit length, but stored ones were rounded to
    /// Float16, so this divides by the lengths anyway.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }
}

/// One catalogued file as it is now. The state isn't stored: it's worked out from the move log
/// (the record of what the app did) and the disk, each time the catalog is read.
public struct CatalogItem: Sendable {
    public enum State: String, Sendable {
        /// The app filed it, and it's still where the app put it.
        case filed
        /// Carded but never filed: still in Downloads (sent to review, or left waiting).
        case waiting
        /// You undid the move: not offered as similar.
        case undone
        /// Not where the log or the catalog says: moved or deleted by someone else.
        case gone
    }

    public var entry: CatalogEntry
    public var state: State
    /// Where the file is now (filed, waiting) or was last seen.
    public var path: String
    public var vector: [Float]

    public var isLive: Bool { state == .filed || state == .waiting }
}

/// The catalog as read: the newest entry per file, with its current state.
public struct Catalog: Sendable {
    public let embedder: String
    /// Every file's newest entry, whichever embedder made it.
    public let latest: [String: CatalogEntry]
    /// Files embedded by `embedder`, with their state.
    public let items: [CatalogItem]
    /// Entries made by another embedder: their stored line is embedded again, never compared as is.
    public let stale: [CatalogEntry]

    public init(entries: [CatalogEntry], records: [MoveRecord], embedder: String,
                exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.embedder = embedder
        var latest: [String: CatalogEntry] = [:]
        for entry in entries {
            guard let key = entry.key else { continue }
            if let known = latest[key], known.time > entry.time { continue }
            latest[key] = entry
        }
        self.latest = latest

        // The newest move of each file, by hash and by move.
        var byHash: [String: MoveRecord] = [:]
        var byMove: [UUID: MoveRecord] = [:]
        for record in records where record.state != .failed {
            byMove[record.moveID] = record
            if let hash = record.sha256 {
                if let known = byHash[hash], known.time > record.time { continue }
                byHash[hash] = record
            }
        }

        var items: [CatalogItem] = []
        var stale: [CatalogEntry] = []
        for entry in latest.values.sorted(by: { $0.time < $1.time }) {
            guard entry.embedder == embedder else { stale.append(entry); continue }
            guard let vector = Vectors.decode(entry.embedding) else { continue }
            var record = entry.moveID.flatMap { byMove[$0] } ?? entry.sha256.flatMap { byHash[$0] }
            // Carded after that move or undo, at a place where it still is (back in Downloads, say):
            // the newer sighting wins. Back-filled entries follow their own move.
            if entry.moveID == nil, let older = record, older.time < entry.time, exists(entry.path) { record = nil }
            let (state, path): (CatalogItem.State, String) = switch record?.state {
            case .moved?: exists(record!.movedPath) ? (.filed, record!.movedPath) : (.gone, record!.movedPath)
            case .undone?: (.undone, record!.restoredPath ?? record!.originalPath)
            case .pending?, .undoPending?: (.gone, record!.movedPath)  // unfinished: left alone until recovered
            case .failed?, nil: exists(entry.path) ? (.waiting, entry.path) : (.gone, entry.path)
            }
            items.append(CatalogItem(entry: entry, state: state, path: path, vector: vector))
        }
        self.items = items
        self.stale = stale
    }

    /// The newest entry for a file's content, made by any embedder (its card is still good).
    public func entry(forHash hash: String) -> CatalogEntry? {
        latest[hash]
    }

    public func contains(key: String) -> Bool {
        items.contains { $0.entry.key == key }
    }

    /// The `k` live files most similar to `vector`, best first.
    public func nearest(to vector: [Float], k: Int = 5, excluding key: String? = nil) -> [(item: CatalogItem, score: Float)] {
        items.filter { $0.isLive && ($0.entry.key == nil || $0.entry.key != key) }
            .map { ($0, Vectors.cosine(vector, $0.vector)) }
            .sorted { $0.1 > $1.1 }
            .prefix(k)
            .map { (item: $0.0, score: $0.1) }
    }
}

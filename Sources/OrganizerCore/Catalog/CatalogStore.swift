import Foundation

/// The catalog file: append-only JSON Lines, like the move log. Lines are only ever added, so
/// a crash can at worst cut the last one short; a line that can't be read is skipped and counted.
public struct CatalogStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Next to the move log: `TestData/catalog.jsonl` in the sandbox, Application Support for
    /// your real home.
    public init(forHome home: URL) {
        url = MoveJournal.url(forHome: home).deletingLastPathComponent().appending(path: "catalog.jsonl")
    }

    /// Appends entries, all at once, and flushes them to disk.
    public func append(_ entries: [CatalogEntry]) throws {
        guard !entries.isEmpty else { return }
        var lines = Data()
        for entry in entries {
            lines.append(try Self.encoder.encode(entry))
            lines.append(0x0A)
        }
        try locked {
            // Never follows a symlink: a planted link can't redirect the catalog.
            let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o644)
            guard fd >= 0 else { throw MoveError.system("opening the catalog", errno) }
            defer { close(fd) }
            // A line cut short by a crash has no newline: start on a fresh one.
            var info = stat()
            var last: UInt8 = 0x0A
            if fstat(fd, &info) == 0, info.st_size > 0, pread(fd, &last, 1, info.st_size - 1) == 1, last != 0x0A {
                lines.insert(0x0A, at: 0)
            }
            let written = lines.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, lines.count) }
            guard written == lines.count else { throw MoveError.system("writing the catalog", errno) }
            _ = Durability.flush(fd: fd)
        }
    }

    /// Every readable entry, oldest first.
    public func entries() throws -> [CatalogEntry] {
        try read().entries
    }

    /// How many lines couldn't be read and were skipped.
    public func damagedLineCount() throws -> Int {
        try read().damaged
    }

    private func read() throws -> (entries: [CatalogEntry], damaged: Int) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], 0) }
        let lines = try Data(contentsOf: url).split(separator: 0x0A)
        let entries = lines.compactMap { try? Self.decoder.decode(CatalogEntry.self, from: Data($0)) }
        return (entries, lines.count - entries.count)
    }

    /// One writer at a time (the app and the `organize` command share the file).
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw MoveError.system("opening the catalog's lock", errno) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw MoveError.system("locking the catalog", errno) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

import Compression
import Foundation

/// A minimal read-only ZIP reader: enough to pull a few JSON files out of an
/// Office document or a downloaded archive without extracting the whole archive.
///
/// Supports stored and deflated entries, and ZIP64 archives. Encrypted entries
/// are rejected.
struct ZipArchive {
    struct Entry {
        let path: String
        let method: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let isEncrypted: Bool
    }

    /// Refuse to inflate anything larger than this; we only ever read small XML parts.
    static let maxEntrySize: UInt64 = 512 * 1024 * 1024

    private let data: Data
    let entries: [Entry]

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        self.data = data
        self.entries = try Self.readCentralDirectory(data)
    }

    func contents(of entry: Entry) throws -> Data {
        guard !entry.isEncrypted else { throw ZipError.invalid("it's password-protected") }
        guard entry.uncompressedSize <= Self.maxEntrySize else { throw ZipError.invalid("a file is too large") }
        guard entry.compressedSize <= UInt64(data.count) else { throw ZipError.invalid("it's corrupted") }

        let header = try offset(entry.localHeaderOffset)
        guard try data.uint32(at: header) == 0x0403_4b50 else { throw ZipError.invalid("bad local header") }
        let nameLength = Int(try data.uint16(at: header + 26))
        let extraLength = Int(try data.uint16(at: header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + (try offset(entry.compressedSize))
        guard end <= data.count else { throw ZipError.invalid("it's truncated") }
        let compressed = data[data.startIndex + start ..< data.startIndex + end]

        let output: Data
        switch entry.method {
        case 0:
            output = Data(compressed)
        case 8:
            output = try Self.inflate(compressed, expectedSize: Int(entry.uncompressedSize))
        default:
            throw ZipError.invalid("unsupported compression method \(entry.method)")
        }

        guard CRC32.checksum(output) == entry.crc32 else { throw ZipError.invalid("checksum mismatch") }
        return output
    }

    // MARK: - Central directory

    /// Converts a 64-bit size/offset from the archive, rejecting values that can't be valid.
    private static func offset(_ value: UInt64) throws -> Int {
        guard let int = Int(exactly: value) else { throw ZipError.invalid("it's corrupted") }
        return int
    }

    private func offset(_ value: UInt64) throws -> Int { try Self.offset(value) }

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        let eocd = try findEndOfCentralDirectory(data)
        var count = UInt64(try data.uint16(at: eocd + 10))
        var offset = UInt64(try data.uint32(at: eocd + 16))

        if count == 0xFFFF || offset == 0xFFFF_FFFF {
            // ZIP64: the locator sits immediately before the classic record.
            let locator = eocd - 20
            guard locator >= 0, try data.uint32(at: locator) == 0x0706_4b50 else {
                throw ZipError.invalid("bad ZIP64 locator")
            }
            let record = try Self.offset(try data.uint64(at: locator + 8))
            guard try data.uint32(at: record) == 0x0606_4b50 else { throw ZipError.invalid("bad ZIP64 record") }
            count = try data.uint64(at: record + 32)
            offset = try data.uint64(at: record + 48)
        }

        var entries: [Entry] = []
        var position = try Self.offset(offset)
        for _ in 0..<count {
            guard try data.uint32(at: position) == 0x0201_4b50 else { throw ZipError.invalid("bad directory entry") }
            let flags = try data.uint16(at: position + 8)
            let method = try data.uint16(at: position + 10)
            let crc = try data.uint32(at: position + 16)
            var compressedSize = UInt64(try data.uint32(at: position + 20))
            var uncompressedSize = UInt64(try data.uint32(at: position + 24))
            let nameLength = Int(try data.uint16(at: position + 28))
            let extraLength = Int(try data.uint16(at: position + 30))
            let commentLength = Int(try data.uint16(at: position + 32))
            var localOffset = UInt64(try data.uint32(at: position + 42))

            let nameStart = position + 46
            let path = String(decoding: try data.bytes(at: nameStart, count: nameLength), as: UTF8.self)

            // ZIP64 extra field: only the values that overflowed are present, in this order.
            var extra = nameStart + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = try data.uint16(at: extra)
                let size = Int(try data.uint16(at: extra + 2))
                if id == 0x0001 {
                    var field = extra + 4
                    if uncompressedSize == 0xFFFF_FFFF { uncompressedSize = try data.uint64(at: field); field += 8 }
                    if compressedSize == 0xFFFF_FFFF { compressedSize = try data.uint64(at: field); field += 8 }
                    if localOffset == 0xFFFF_FFFF { localOffset = try data.uint64(at: field) }
                }
                extra += 4 + size
            }

            entries.append(Entry(
                path: path,
                method: method,
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset,
                isEncrypted: flags & 1 != 0
            ))
            position = extraEnd + commentLength
        }
        return entries
    }

    private static func findEndOfCentralDirectory(_ data: Data) throws -> Int {
        // 22-byte record plus an optional comment of up to 65535 bytes.
        let lowest = max(0, data.count - 22 - 0xFFFF)
        var position = data.count - 22
        while position >= lowest {
            if try data.uint32(at: position) == 0x0605_4b50 { return position }
            position -= 1
        }
        throw ZipError.invalid("it isn't a zip archive")
    }

    // MARK: - Deflate

    private static func inflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { dst in
            compressed.withUnsafeBytes { src in
                // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what ZIP uses.
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw ZipError.invalid("couldn't decompress a file") }
        return output
    }
}

// MARK: - Helpers

private extension Data {
    func bytes(at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset + count <= self.count else {
            throw ZipError.invalid("it's truncated")
        }
        return self[startIndex + offset ..< startIndex + offset + count]
    }

    func uint16(at offset: Int) throws -> UInt16 {
        try bytes(at: offset, count: 2).reversed().reduce(0) { $0 << 8 | UInt16($1) }
    }

    func uint32(at offset: Int) throws -> UInt32 {
        try bytes(at: offset, count: 4).reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    func uint64(at offset: Int) throws -> UInt64 {
        try bytes(at: offset, count: 8).reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func checksum(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crc, byte in
            table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
    }
}

struct ZipError: Error, CustomStringConvertible {
    let reason: String
    static func invalid(_ reason: String) -> ZipError { ZipError(reason: reason) }
    var description: String { "Not a readable zip archive: \(reason)" }
}

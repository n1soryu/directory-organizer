import CryptoKit
import Foundation

/// SHA-256 of a file's contents, read in 1 MB chunks so large files don't fill memory.
/// Duplicates are decided by this hash only, never by name.
public enum FileHash {
    public static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

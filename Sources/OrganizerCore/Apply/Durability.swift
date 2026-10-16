import Foundation

/// Getting bytes onto the disk itself. On macOS `fsync` only hands data to the drive, which may
/// keep it in its own cache; `F_FULLFSYNC` asks the drive to write that cache out too.
enum Durability {
    /// Flushes an open file or folder all the way to the disk. False if neither way worked.
    static func flush(fd: Int32) -> Bool {
        fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0
    }

    /// Opens `url` (a file or folder, not following a symlink) and flushes it.
    static func flush(_ url: URL) throws {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else { throw MoveError.system("opening \(url.lastPathComponent) to save it to disk", errno) }
        defer { close(fd) }
        guard flush(fd: fd) else { throw MoveError.system("saving \(url.lastPathComponent) to disk", errno) }
    }

    /// Flushes everything under `url`, then `url` itself. Symlinks aren't followed (or opened).
    static func flushTree(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true { return }
        if values?.isDirectory == true,
           let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let item as URL in walker
            where (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true {
                try flush(item)
            }
        }
        try flush(url)
    }
}

import Foundation

public enum MoveError: Error, Equatable, CustomStringConvertible {
    /// Something is already at the destination. Nothing was moved or overwritten.
    case destinationExists(String)
    case sourceMissing(String)
    /// The file changed after the plan was made (still downloading? edited?).
    case sourceChanged(String)
    /// The destination would end up outside the home folder (e.g. through a symlink).
    case outsideHome(String)
    case invalidDestination(String)
    /// A copy between disks didn't match the original, so the original was kept.
    case copyMismatch(String)
    case system(String, Int32)

    public var description: String {
        switch self {
        case .destinationExists(let p): "something already exists at \(p); nothing was overwritten"
        case .sourceMissing(let p): "\(p) is no longer there"
        case .sourceChanged(let p): "\(p) changed after the plan was made; skipped"
        case .outsideHome(let p): "\(p) resolves outside the home folder"
        case .invalidDestination(let why): "invalid destination: \(why)"
        case .copyMismatch(let p): "copy of \(p) didn't match the original; original kept"
        case .system(let what, let code): "\(what) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Moving without ever overwriting.
enum SafeMove {
    /// Moves `source` to `destination`, failing if anything exists there.
    ///
    /// `renamex_np` with `RENAME_EXCL` checks and renames in one step inside the kernel,
    /// so there's no gap between "is it free?" and "move" where another file could appear.
    static func move(_ source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                renamex_np(from!, to!, UInt32(RENAME_EXCL))
            }
        }
        if result == 0 { return }
        switch errno {
        case EEXIST: throw MoveError.destinationExists(destination.path)
        case ENOENT where !FileManager.default.fileExists(atPath: source.path):
            throw MoveError.sourceMissing(source.path)
        case EXDEV: try copyAcrossDisks(source, to: destination)
        case let code: throw MoveError.system("moving \(source.lastPathComponent)", code)
        }
    }

    /// A rename can't cross disks: copy (exclusive), verify the copy, then remove the original.
    private static func copyAcrossDisks(_ source: URL, to destination: URL) throws {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW | (isDirectory.boolValue ? COPYFILE_RECURSIVE : 0))
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in copyfile(from!, to!, nil, flags) }
        }
        guard result == 0 else {
            if errno == EEXIST { throw MoveError.destinationExists(destination.path) }
            throw MoveError.system("copying \(source.lastPathComponent)", errno)
        }
        if !isDirectory.boolValue {
            guard try FileHash.sha256(source) == FileHash.sha256(destination) else {
                try? FileManager.default.removeItem(at: destination)  // our own bad copy
                throw MoveError.copyMismatch(source.path)
            }
        }
        try FileManager.default.removeItem(at: source)
    }

    /// Removes a folder only if it's empty (`rmdir` refuses otherwise). Returns true if removed.
    @discardableResult
    static func removeIfEmpty(_ folder: URL) -> Bool {
        folder.withUnsafeFileSystemRepresentation { rmdir($0!) } == 0
    }
}

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
            destination.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else { errno = EINVAL; return -1 }
                return renamex_np(from, to, UInt32(RENAME_EXCL))
            }
        }
        if result == 0 { return }
        switch errno {
        case EEXIST: throw MoveError.destinationExists(destination.path)
        case ENOENT where !FileManager.default.fileExists(atPath: source.path):
            throw MoveError.sourceMissing(source.path)
        // Another disk; or a volume (some network shares) that can't rename without overwriting:
        // the careful copy also never overwrites.
        case EXDEV, ENOTSUP: try copyAcrossDisks(source, to: destination)
        case let code: throw MoveError.system("moving \(source.lastPathComponent)", code)
        }
    }

    /// A rename can't cross disks: copy (exclusive), check the copy matches the original (every
    /// file of a folder), make sure the copy is on the disk itself, and only then remove the
    /// original. If anything fails, our copy is removed and the original stays untouched.
    /// `hash` is swappable for tests.
    static func copyAcrossDisks(_ source: URL, to destination: URL,
                                hash: (URL) throws -> String = FileHash.sha256) throws {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW | (isDirectory.boolValue ? COPYFILE_RECURSIVE : 0))
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else { return -1 }
                return copyfile(from, to, nil, flags)
            }
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST { throw MoveError.destinationExists(destination.path) }
            // A partial copy of our own may be left behind (never when the destination existed).
            try? FileManager.default.removeItem(at: destination)
            throw MoveError.system("copying \(source.lastPathComponent)", code)
        }
        do {
            guard try manifest(source, hash) == manifest(destination, hash) else {
                throw MoveError.copyMismatch(source.path)
            }
            // On the disk, not just in memory: deleting the original before that, a power cut
            // could lose both.
            try Durability.flushTree(destination)
            try Durability.flush(destination.deletingLastPathComponent())
        } catch {
            try? FileManager.default.removeItem(at: destination)   // our own copy
            throw error
        }
        try FileManager.default.removeItem(at: source)
    }

    /// What's in a file or folder, to compare a copy with its original: every item's relative
    /// path, with a symlink's target or a file's size and content hash (hidden items included).
    static func manifest(_ url: URL, _ hash: (URL) throws -> String) throws -> [String: String] {
        func describe(_ item: URL) throws -> String {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                return "link " + (try FileManager.default.destinationOfSymbolicLink(atPath: item.path))
            }
            if values.isDirectory == true { return "folder" }
            return "file \(values.fileSize ?? -1) \(try hash(item))"
        }
        var result = ["": try describe(url)]
        guard result[""] == "folder" else { return result }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
            throw MoveError.system("reading \(url.lastPathComponent)", EIO)
        }
        // Plain paths: resolving symlinks would turn a symlink item into its target.
        let base = url.standardizedFileURL.path + "/"
        for case let item as URL in walker {
            let path = item.standardizedFileURL.path
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : item.lastPathComponent
            result[relative] = try describe(item)
        }
        return result
    }

    /// Removes a folder only if it's empty (`rmdir` refuses otherwise). Returns true if removed.
    @discardableResult
    static func removeIfEmpty(_ folder: URL) -> Bool {
        folder.withUnsafeFileSystemRepresentation { path in path.map { rmdir($0) } ?? -1 } == 0
    }
}

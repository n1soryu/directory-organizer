import Foundation

/// What's inside a downloaded folder, read all the way down (within limits).
public struct FolderContents: Codable, Sendable, Equatable {
    /// Visible files and folders inside, at any depth (hidden ones like .DS_Store don't count).
    public var fileCount = 0
    public var folderCount = 0
    /// Total size of the visible files, in bytes.
    public var totalSize: Int64 = 0
    /// The most recent change anywhere inside, the folder itself included. A folder still
    /// being unzipped or copied keeps moving this forward.
    public var newestChange: Date?
    /// The limits were hit: not everything inside was looked at.
    public var truncated = false
    /// How many files of each kind ("pdf document" → 12).
    public var kinds: [String: Int] = [:]
    /// Bytes of each kind: a film folder is one big video and a few small text files.
    public var kindBytes: [String: Int64] = [:]
    /// Paths relative to the folder, shallowest first, for the model and the app.
    public var sample: [String] = []
    /// Sensitive files found inside: "keys/id_ed25519: Private Key (OPENSSH PRIVATE KEY)".
    public var sensitive: [String] = []
    /// Some files inside need text recognition before they can be called safe (quick scans).
    public var needsDeepRead = false

    public var isEmpty: Bool { fileCount == 0 && folderCount == 0 }
}

public enum FolderScan {
    /// How deep and how much is read. Bigger folders are kept together and never unpacked.
    public static let maxDepth = 6
    public static let maxItems = 2_000
    static let sampleSize = 40

    /// Counts, sizes and the newest change inside `folder`, plus the files found (for the
    /// safety checks). Hidden items and the insides of bundles (.app, .photoslibrary) are skipped.
    public static func scan(_ folder: URL) -> (contents: FolderContents, files: [URL]) {
        var contents = FolderContents()
        var files: [URL] = []
        var paths: [String] = []
        contents.newestChange = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return (contents, files) }

        let base = folder.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            if contents.fileCount + contents.folderCount >= maxItems {
                contents.truncated = true
                break
            }
            if walker.level > maxDepth {
                contents.truncated = true
                walker.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if let changed = values?.contentModificationDate, changed > (contents.newestChange ?? .distantPast) {
                contents.newestChange = changed
            }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
            paths.append(relative)
            if values?.isDirectory == true && values?.isPackage != true {
                contents.folderCount += 1
            } else {
                contents.fileCount += 1
                contents.totalSize += Int64(values?.fileSize ?? 0)
                let kind = FileKind(fileExtension: url.pathExtension, isDirectory: values?.isDirectory ?? false)
                contents.kinds[kind.rawValue, default: 0] += 1
                contents.kindBytes[kind.rawValue, default: 0] += Int64(values?.fileSize ?? 0)
                files.append(url)
            }
        }
        // Shallowest first, so the sample shows the folder's top level before its depths.
        contents.sample = Array(paths.sorted {
            let (a, b) = ($0.split(separator: "/").count, $1.split(separator: "/").count)
            return a != b ? a < b : $0.localizedStandardCompare($1) == .orderedAscending
        }.prefix(sampleSize))
        return (contents, files)
    }

    /// Total size and newest change: what a move compares against the plan, so a folder
    /// that changed anywhere inside since planning is skipped.
    public static func fingerprint(_ folder: URL) -> (size: Int64, newestChange: Date?) {
        let contents = scan(folder).contents
        return (contents.totalSize, contents.newestChange)
    }
}

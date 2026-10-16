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

    /// Counts, sizes and the newest change inside `folder`, plus the files found for the safety
    /// checks. Hidden items (`.env`, `.ssh/id_rsa`) are among those files, since that's where
    /// secrets hide, but don't count as contents. A `.git` history isn't read through (only its
    /// `config`, which can hold a password); bundle insides (.app, .photoslibrary) are skipped.
    public static func scan(_ folder: URL) -> (contents: FolderContents, files: [URL]) {
        var contents = FolderContents()
        var files: [URL] = []
        var paths: [String] = []
        contents.newestChange = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants])
        else { return (contents, files) }

        let base = folder.standardizedFileURL.path + "/"
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > maxItems {
                contents.truncated = true
                break
            }
            if walker.level > maxDepth {
                contents.truncated = true
                walker.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            // Finder rewrites .DS_Store just from looking at a folder: not a change.
            if url.lastPathComponent != ".DS_Store", let changed = values?.contentModificationDate,
               changed > (contents.newestChange ?? .distantPast) {
                contents.newestChange = changed
            }
            if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                // Hidden: checked for secrets, not counted as contents.
                if isFolder, url.lastPathComponent == ".git" {
                    walker.skipDescendants()
                    let config = url.appending(path: "config")
                    if FileManager.default.fileExists(atPath: config.path) { files.append(config) }
                } else if !isFolder, url.lastPathComponent != ".DS_Store" {
                    files.append(url)
                }
                continue
            }
            paths.append(relative)
            if isFolder {
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

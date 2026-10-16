import Foundation

/// What one of your folders holds, learned from its contents rather than written into the code.
/// Code gathers the facts; the model reads them once and writes `purpose`.
public struct FolderProfile: Codable, Sendable, Equatable {
    /// Relative to the home root.
    public var path: String
    /// What the folder is for ("electricity and water bills"), written by the model from
    /// the contents. nil until learned (Organize Now does that).
    public var purpose: String?
    /// Visible files directly inside.
    public var fileCount: Int
    /// Files of each kind ("pdf document" → 12).
    public var kinds: [String: Int]
    /// Names of the most recently added files, newest first.
    public var examples: [String]
    /// The sites its files were most often downloaded from.
    public var sources: [String]
    /// Finder tags most files inside carry: new files placed here get them too.
    public var tags: [Tag]
    /// When the folder last changed. Its facts are gathered again when this moves.
    public var changed: Date?
    /// How many files it held when `purpose` was written; a purpose is rewritten when the
    /// folder has grown or shrunk a lot since.
    public var purposeFileCount: Int?

    public init(path: String, purpose: String? = nil, fileCount: Int = 0, kinds: [String: Int] = [:],
                examples: [String] = [], sources: [String] = [], tags: [Tag] = [], changed: Date? = nil) {
        self.path = path
        self.purpose = purpose
        self.fileCount = fileCount
        self.kinds = kinds
        self.examples = examples
        self.sources = sources
        self.tags = tags
        self.changed = changed
    }

    /// The purpose is missing or was written from very different contents.
    public var needsPurpose: Bool {
        guard purpose != nil, let then = purposeFileCount else { return true }
        let grown = abs(fileCount - then)
        return grown >= 3 && Double(grown) >= Double(max(then, 1)) * 0.5
    }
}

/// Reads your folders into profiles. Only facts here; purposes come from the model.
public enum FolderProfiler {
    /// Where your folders are looked for, two levels deep.
    public static let roots = ["Documents", "Pictures", "Movies", "Music"]
    static let exampleCount = 8
    /// Files looked at for tags and download sources.
    static let sampledFiles = 40

    /// A profile for every folder files may go to, reusing what `cached` already knows
    /// (purposes, and facts of folders that haven't changed). A root folder itself counts
    /// only if files sit directly in it (a loose "Music" yes, "Documents" no).
    public static func profiles(homeRoot: URL, config: OrganizerConfig, cached: [FolderProfile] = []) -> [FolderProfile] {
        let known = Dictionary(cached.map { ($0.path, $0) }, uniquingKeysWith: { $1 })
        var result: [FolderProfile] = []
        for root in roots {
            let paths = [root] + FolderCatalog.subfolders(of: root, in: homeRoot, depth: 2)
            for path in paths where DestinationValidator.problem(with: path, config: config) == nil {
                let url = homeRoot.appending(path: path, directoryHint: .isDirectory)
                let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                var profile: FolderProfile
                // To the second: saved dates lose their fractions.
                if let old = known[path], let then = old.changed, let now = changed, abs(then.timeIntervalSince(now)) < 1 {
                    profile = old
                } else {
                    profile = read(path, at: url)
                    profile.changed = changed
                    profile.purpose = known[path]?.purpose
                    profile.purposeFileCount = known[path]?.purposeFileCount
                }
                if path == root && profile.fileCount == 0 { continue }
                result.append(profile)
            }
        }
        return result
    }

    /// The facts of one folder: its files (not its subfolders' files).
    static func read(_ path: String, at url: URL) -> FolderProfile {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey, .addedToDirectoryDateKey, .creationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let files = items
            .compactMap { item -> (URL, Date)? in
                let values = try? item.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true || values?.isPackage == true else { return nil }
                return (item, values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)

        var profile = FolderProfile(path: path, fileCount: files.count)
        for file in files {
            profile.kinds[FileKind(fileExtension: file.pathExtension, isDirectory: false).rawValue, default: 0] += 1
        }
        profile.examples = files.prefix(exampleCount).map(\.lastPathComponent)

        let sample = files.prefix(sampledFiles)
        var hosts: [String: Int] = [:]
        var tagCounts: [Tag: Int] = [:]
        for file in sample {
            for host in Set(WhereFroms.read(file).compactMap { URL(string: $0)?.host()?.lowercased() }) {
                hosts[host, default: 0] += 1
            }
            for tag in Set(FinderTags.read(file)) { tagCounts[tag, default: 0] += 1 }
        }
        profile.sources = hosts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3).map(\.key)
        // A tag counts as the folder's when most of its files (and at least two) carry it.
        profile.tags = tagCounts
            .filter { $0.value >= 2 && Double($0.value) >= Double(sample.count) * 0.6 }
            .map(\.key).sorted { $0.name < $1.name }
        return profile
    }
}

/// Profiles are kept between runs, so purposes are written once, not on every scan.
public struct ProfileStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Next to the move log: `TestData/folder-profiles.json` in the sandbox, Application
    /// Support for your real home.
    public init(forHome home: URL) {
        url = MoveJournal.url(forHome: home).deletingLastPathComponent().appending(path: "folder-profiles.json")
    }

    public func load() -> [FolderProfile] {
        guard let data = try? Data(contentsOf: url),
              let profiles = try? Self.decoder.decode([FolderProfile].self, from: data) else { return [] }
        return profiles
    }

    public func save(_ profiles: [FolderProfile]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(profiles).write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

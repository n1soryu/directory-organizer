import Foundation

/// A folder the model may choose, with what it's for.
public struct FolderOption: Codable, Hashable, Sendable {
    /// Relative to the home root.
    public var path: String
    public var purpose: String?
    public var tags: [Tag]
    /// Recent file names in it, newest first.
    public var examples: [String] = []
    /// Files of each kind in it.
    public var kinds: [String: Int] = [:]
    /// Sites its files usually come from.
    public var sources: [String] = []

    public init(path: String, purpose: String?, tags: [Tag], examples: [String] = [],
                kinds: [String: Int] = [:], sources: [String] = []) {
        self.path = path
        self.purpose = purpose
        self.tags = tags
        self.examples = examples
        self.kinds = kinds
        self.sources = sources
    }

    public init(_ profile: FolderProfile) {
        self.init(path: profile.path, purpose: profile.purpose, tags: profile.tags,
                  examples: profile.examples, kinds: profile.kinds, sources: profile.sources)
    }
}

/// The folders files may go to: the two the app itself relies on (review, and Secure for
/// keys and recovery phrases), plus your own folders as their profiles describe them.
public enum FolderCatalog {
    /// Folders offered for one file: what fits in the model's small context window.
    public static let maxOffered = 25

    /// The folders every user has, because the safety rules send files there.
    public static func universal(_ config: OrganizerConfig) -> [FolderOption] {
        [
            FolderOption(path: config.secure, purpose: "passwords, private keys, recovery phrases and identity documents (passport, national ID); not bills, receipts or statements", tags: [.secure]),
            FolderOption(path: config.reviewFolder, purpose: "anything uncertain, temporary or probably deletable", tags: []),
        ]
    }

    /// Universal folders plus your folders, without duplicates.
    public static func options(profiles: [FolderProfile], config: OrganizerConfig) -> [FolderOption] {
        var result = universal(config)
        var seen = Set(result.map { $0.path.lowercased() })
        for profile in profiles where seen.insert(profile.path.lowercased()).inserted {
            result.append(FolderOption(profile))
        }
        return result
    }

    /// Your folders as they are on disk now, with no learned purposes.
    public static func options(homeRoot: URL, config: OrganizerConfig) -> [FolderOption] {
        options(profiles: FolderProfiler.profiles(homeRoot: homeRoot, config: config), config: config)
    }

    /// The folders most likely to fit `facts`, at most `limit`: the universal ones always, then
    /// your folders ranked by shared words (name, purpose, examples), download site and file
    /// kind. Only ranking: the planner still checks new folders against all of them.
    public static func relevant(_ folders: [FolderOption], to facts: FileFacts, config: OrganizerConfig,
                                limit: Int = maxOffered) -> [FolderOption] {
        relevant(folders, words: words(facts.name + " " + facts.head(1_500) + " " + (facts.documentTitle ?? "")),
                 hosts: Set(facts.sourceHosts), kinds: [facts.kind], config: config, limit: limit)
    }

    /// The same for a group of similar files: what they share and what any of them says.
    public static func relevant(_ folders: [FolderOption], toGroup members: [FileFacts], category: String,
                                config: OrganizerConfig, limit: Int = maxOffered) -> [FolderOption] {
        let text = ([category] + members.map { $0.name + " " + $0.head(300) }).joined(separator: " ")
        return relevant(folders, words: words(text), hosts: Set(members.flatMap(\.sourceHosts)),
                        kinds: Set(members.map(\.kind)), config: config, limit: limit)
    }

    static func relevant(_ folders: [FolderOption], words: Set<String>, hosts: Set<String>, kinds: Set<FileKind>,
                         config: OrganizerConfig, limit: Int) -> [FolderOption] {
        let universalPaths = Set(universal(config).map(\.path))
        let fixed = folders.filter { universalPaths.contains($0.path) }
        let rest = folders.filter { !universalPaths.contains($0.path) }
        guard fixed.count + rest.count > limit else { return folders }

        func score(_ folder: FolderOption) -> Double {
            let folderWords = Self.words(([folder.path, folder.purpose ?? ""] + folder.examples).joined(separator: " "))
            var score = Double(words.intersection(folderWords).count)
            if folder.sources.contains(where: { source in hosts.contains { $0 == source || $0.hasSuffix("." + source) } }) { score += 3 }
            if kinds.contains(where: { (folder.kinds[$0.rawValue] ?? 0) > 0 }) { score += 2 }
            return score
        }
        // Stable: equal scores keep the catalog's order.
        let scores: [Double] = rest.map(score)
        let order: [Int] = rest.indices.sorted { a, b in
            scores[a] != scores[b] ? scores[a] > scores[b] : a < b
        }
        return fixed + order.prefix(max(0, limit - fixed.count)).map { rest[$0] }
    }

    /// Lowercased words of 3+ letters, singular-ish, without the most common filler.
    static func words(_ text: String) -> Set<String> {
        let filler: Set<String> = ["the", "and", "for", "with", "from", "this", "that", "your", "are", "you", "pdf", "files", "file"]
        return Set(text.lowercased().split { !$0.isLetter }.map(String.init)
            .filter { $0.count >= 3 && !filler.contains($0) }
            .map { $0.count > 4 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 })
    }

    /// Where a new folder may go for this item. A downloaded folder goes by what most of its
    /// bytes are: a film with subtitles is a video folder, under Movies.
    public static func newFolderParents(for facts: FileFacts) -> [String] {
        newFolderParents(for: facts.kind, inside: facts.folder)
    }

    public static func newFolderParents(for kind: FileKind, inside: FolderContents? = nil) -> [String] {
        if kind == .folder, let mostly = inside?.kindBytes.max(by: { $0.value < $1.value })?.key,
           let inner = FileKind(rawValue: mostly), inner != .folder {
            return newFolderParents(for: inner)
        }
        return switch kind {
        case .image: ["Pictures"]
        case .video: ["Movies"]
        case .audio: ["Music"]
        default: ["Documents"]
        }
    }

    /// Visible, non-bundle subfolders, as paths relative to the home root.
    static func subfolders(of folder: String, in homeRoot: URL, depth: Int) -> [String] {
        guard depth > 0 else { return [] }
        let url = homeRoot.appending(path: folder, directoryHint: .isDirectory)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
        return children
            .filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return values?.isDirectory == true && values?.isPackage != true
            }
            .map { folder + "/" + $0.lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .flatMap { [$0] + subfolders(of: $0, in: homeRoot, depth: depth - 1) }
    }

    /// Compares folder names loosely, so "Manual", "manuals" and "Manuals!" count as one.
    public static func looseKey(_ name: String) -> String {
        var key = name.lowercased().filter { $0.isLetter || $0.isNumber }
        if key.hasSuffix("s") && key.count > 3 { key.removeLast() }
        return key
    }
}

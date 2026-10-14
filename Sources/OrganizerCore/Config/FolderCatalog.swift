import Foundation

/// A folder the model may choose, with what it's for.
public struct FolderOption: Codable, Hashable, Sendable {
    /// Relative to the home root.
    public var path: String
    public var purpose: String?
    public var tags: [Tag]
}

/// The folders offered to the model: your core folders (with descriptions) plus the folders
/// that already exist under Documents, Pictures, Movies and Music (two levels deep).
public enum FolderCatalog {
    /// Folders that fit in the model's small context window comfortably.
    public static let maxOptions = 80

    public static func core(_ config: OrganizerConfig) -> [FolderOption] {
        [
            FolderOption(path: config.essays, purpose: "personal essays and own writing", tags: [.personal]),
            FolderOption(path: config.fsae, purpose: "NSU Formula SAE racing team files", tags: [.fsae]),
            FolderOption(path: config.secure, purpose: "identity documents, passwords, keys, sensitive personal records", tags: [.secure]),
            FolderOption(path: config.university, purpose: "North South University (NSU) documents not tied to one course", tags: [.nsu]),
            FolderOption(path: config.records, purpose: "official NSU records: grades, payments, registration", tags: [.nsu]),
            FolderOption(path: config.downloadedImages, purpose: "downloaded pictures", tags: []),
            FolderOption(path: config.films, purpose: "feature films", tags: []),
            FolderOption(path: "Music", purpose: "music and audio", tags: []),
            FolderOption(path: config.reviewFolder, purpose: "anything uncertain, temporary or probably deletable", tags: []),
        ]
    }

    /// Core folders plus existing ones, without duplicates, at most `maxOptions`.
    public static func options(homeRoot: URL, config: OrganizerConfig) -> [FolderOption] {
        var result = core(config)
        var seen = Set(result.map { $0.path.lowercased() })
        let coreTags = result.filter { !$0.tags.isEmpty }

        for root in ["Documents", "Pictures", "Movies", "Music"] {
            for path in subfolders(of: root, in: homeRoot, depth: 2) where !seen.contains(path.lowercased()) {
                guard DestinationValidator.problem(with: path, config: config) == nil else { continue }
                // A folder inside University gets NSU, inside FSAE gets FSAE, and so on.
                let tags = coreTags.first { path.hasPrefix($0.path + "/") }?.tags ?? []
                result.append(FolderOption(path: path, purpose: nil, tags: tags))
                seen.insert(path.lowercased())
            }
        }
        return Array(result.prefix(maxOptions))
    }

    /// Where a new folder may go for this kind of file.
    public static func newFolderParents(for kind: FileKind) -> [String] {
        switch kind {
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

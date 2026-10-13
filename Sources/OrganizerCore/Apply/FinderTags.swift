import Foundation

/// Finder tags live in the `com.apple.metadata:_kMDItemUserTags` attribute: a binary
/// property list holding an array of strings like "NSU\n4" (name, newline, color number).
///
/// Tags are handled as these raw strings so that undo can put back exactly what was there,
/// including tags from other apps and colors iCloud rewrote to 1.
public enum FinderTags {
    public static let attribute = "com.apple.metadata:_kMDItemUserTags"

    public static func readRaw(_ url: URL) -> [String] {
        ExtendedAttributes.propertyList(attribute, at: url) as? [String] ?? []
    }

    /// Writes exactly these tags. An empty list removes the attribute.
    public static func writeRaw(_ tags: [String], to url: URL) throws {
        if tags.isEmpty {
            try ExtendedAttributes.remove(attribute, at: url)
        } else {
            try ExtendedAttributes.setPropertyList(tags, name: attribute, at: url)
        }
    }

    public static func read(_ url: URL) -> [Tag] {
        readRaw(url).map(decode)
    }

    /// "NSU\n4" for a colored tag, plain "NSU" for a tag without a color.
    public static func encode(_ tag: Tag) -> String {
        tag.color == .none ? tag.name : "\(tag.name)\n\(tag.color.rawValue)"
    }

    public static func decode(_ raw: String) -> Tag {
        let parts = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let color = parts.count > 1 ? Int(parts[1]).flatMap(TagColor.init(rawValue:)) ?? .none : .none
        return Tag(String(parts[0]), color)
    }

    /// The file's existing tags plus ours. A tag already present by name (whatever its
    /// color) is kept as it is, so "NSU\n1" from iCloud doesn't become a second NSU tag.
    public static func merge(existing: [String], adding tags: [Tag]) -> [String] {
        var result = existing
        let names = Set(existing.map { decode($0).name.lowercased() })
        for tag in tags where !names.contains(tag.name.lowercased()) {
            result.append(encode(tag))
        }
        return result
    }
}

/// A hidden note on every file the app moves, recording where it came from,
/// so a file can always be traced back to its download even without the log.
public enum MoveOrigin {
    public static let attribute = "io.github.n1soryu.directory-organizer.origin"

    public struct Info: Codable, Equatable, Sendable {
        public var originalPath: String
        public var movedAt: Date
        public var moveID: UUID
    }

    public static func read(_ url: URL) -> Info? {
        guard let data = ExtendedAttributes.data(attribute, at: url) else { return nil }
        return try? decoder.decode(Info.self, from: data)
    }

    public static func write(_ info: Info, to url: URL) throws {
        try ExtendedAttributes.set(try encoder.encode(info), name: attribute, at: url)
    }

    public static func remove(from url: URL) throws {
        try ExtendedAttributes.remove(attribute, at: url)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

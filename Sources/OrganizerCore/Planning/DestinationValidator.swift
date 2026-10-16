import Foundation

/// Checks a proposed destination folder. Applied to every decision, from rules and model
/// alike: a rule bug or a model hallucination ends up in review, never somewhere odd.
public enum DestinationValidator {
    /// Bundles that look like folders but must never be written into.
    private static let bundleSuffixes = [".app", ".photoslibrary", ".photolibrary", ".musiclibrary",
                                         ".tvlibrary", ".bundle", ".framework", ".pkg"]

    /// A description of what's wrong, or nil if the destination is acceptable.
    public static func problem(with destination: String, config: OrganizerConfig) -> String? {
        if destination.isEmpty { return "empty destination" }
        if destination.hasPrefix("/") || destination.hasPrefix("~") {
            return "absolute path \"\(destination)\" (destinations are relative to the home folder)"
        }
        let parts = destination.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            if part.isEmpty { return "empty folder name in \"\(destination)\"" }
            if part == "." || part == ".." { return "\"..\" in \"\(destination)\"" }
            if part.hasPrefix(".") { return "hidden folder \"\(part)\"" }
            // APFS ignores case, so "library" is Library.
            if config.forbiddenComponents.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
                return "protected folder \"\(part)\""
            }
            if let suffix = bundleSuffixes.first(where: { part.lowercased().hasSuffix($0) }) {
                return "inside a \(suffix) bundle"
            }
            if part != FileNames.sanitize(part) { return "invalid folder name \"\(part)\"" }
        }
        let allowed = config.allowedRoots.contains { root in
            let rootParts = root.split(separator: "/").map(String.init)
            return parts.count >= rootParts.count && Array(parts.prefix(rootParts.count)) == rootParts
        }
        if !allowed { return "\"\(destination)\" is outside the allowed folders" }
        return nil
    }
}

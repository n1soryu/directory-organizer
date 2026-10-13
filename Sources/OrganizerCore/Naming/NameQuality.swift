import Foundation

/// Decides whether a file name says anything useful about the file.
/// Unclear names get read more deeply and may be renamed; clear names are kept.
public enum NameQuality {
    /// Names that only say "this is a file".
    private static let generic: Set<String> = [
        "document", "doc", "download", "downloads", "file", "untitled", "unnamed", "new",
        "scan", "scanned", "image", "img", "photo", "pic", "picture", "attachment", "export",
        "output", "temp", "tmp", "test", "copy", "final", "draft", "pdf", "data", "noname",
    ]

    /// Camera, scanner and phone prefixes followed by a counter: IMG_4821, DSC01234, PXL_2026..., scan0001.
    private static let counterPrefixes = ["img", "dsc", "dscn", "dscf", "pxl", "mvimg", "vid", "scan", "image",
                                          "photo", "file", "document", "doc", "download", "screenshot", "whatsapp image"]

    public static func isUnclear(_ baseName: String) -> Bool {
        let core = stripCopySuffix(baseName)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)

        if core.isEmpty || generic.contains(core) { return true }

        let letters = core.filter(\.isLetter)
        // Mostly digits or symbols: "123", "1697203345", "20261013_142233".
        if letters.count < 3 { return true }

        // Counter names: "img 4821", "scan0001", "dsc01234".
        for prefix in counterPrefixes where core.hasPrefix(prefix) {
            let rest = core.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty || rest.allSatisfy({ $0.isNumber || $0 == " " }) { return true }
        }

        // Random IDs: UUIDs and long hex strings ("a8f3c9e1b2d4...").
        let compact = core.replacingOccurrences(of: " ", with: "")
        if compact.count >= 16, compact.allSatisfy(\.isHexDigit) { return true }
        if compact.count >= 12, Double(compact.filter(\.isNumber).count) / Double(compact.count) > 0.6 { return true }

        return false
    }

    /// "report (3)" -> "report", "notes copy 2" -> "notes", "final_final2" stays as is.
    public static func stripCopySuffix(_ baseName: String) -> String {
        var name = baseName
        let patterns = [#"\s*\(\d+\)$"#, #"\s+copy(\s+\d+)?$"#, #"\s*-\s*Copy$"#]
        var changed = true
        while changed {
            changed = false
            for pattern in patterns {
                if let range = name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                    name.removeSubrange(range)
                    changed = true
                }
            }
        }
        return name.trimmingCharacters(in: .whitespaces)
    }
}

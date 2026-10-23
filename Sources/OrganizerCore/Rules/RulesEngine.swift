import Foundation

/// One deterministic rule. Returns a decision, or nil if it has nothing to say.
public protocol Rule: Sendable {
    var name: String { get }
    func evaluate(_ facts: FileFacts, config: OrganizerConfig) -> Decision?
}

/// Runs rules in order; the first one that decides wins. Order matters: safety first,
/// so a photographed recovery phrase can never be filed as just another image.
public struct RulesEngine: Sendable {
    public var rules: [any Rule]

    public init(rules: [any Rule]) {
        self.rules = rules
    }

    public func decide(_ facts: FileFacts, config: OrganizerConfig) -> Decision? {
        for rule in rules {
            if let decision = rule.evaluate(facts, config: config) { return decision }
        }
        return nil
    }

    public static let standard = RulesEngine(rules: [
        // 1. Safety: always first, can't be overridden by anything below.
        SensitiveFileRule(),
        InstallerRule(),
        CodeProjectRule(),
        EmptyFolderRule(),
        // 2. File type: films and episodes by their names; images until the vision model has seen them.
        VideoRule(),
        ImageRule(),
        // Everything else is the model's (no personal rules: it learns your folders instead).
    ])
}

// MARK: - Helpers shared by rules

extension FileFacts {
    /// The name as plain lowercase words: "GradeHistory_v2" -> "grade history v2".
    var searchableName: String {
        FileNames.humanize(NameQuality.stripCopySuffix(baseName))
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
    }

    /// The first `count` characters of the text, lowercased.
    func head(_ count: Int) -> String {
        String((text ?? "").prefix(count)).lowercased()
    }

    /// Document-like files, whose text is about what the file is. (An image's OCR text is
    /// about what's in the picture, which is different: a photo of a banner isn't team paperwork.)
    var isDocumentLike: Bool {
        switch kind {
        case .pdf, .wordDocument, .spreadsheet, .presentation, .text, .csv: true
        default: false
        }
    }

    /// A document title worth using as a file name, if the document has one.
    var usableDocumentTitle: String? {
        guard var title = documentTitle?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        title = title.replacingOccurrences(of: #"^Microsoft (Word|PowerPoint|Excel) - "#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\.(docx?|pptx?|xlsx?|pdf)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let junk: Set<String> = ["user", "untitled", "title", "slide 1", "presentation", "document", "powerpoint presentation"]
        guard title.count >= 4, !junk.contains(title.lowercased()), !NameQuality.isUnclear(title) else { return nil }
        return title
    }
}

/// True if `phrase` appears in `text` as whole words.
func containsWords(_ text: String, _ phrase: String) -> Bool {
    let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: phrase) + #"(?![\p{L}\p{N}])"#
    return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}

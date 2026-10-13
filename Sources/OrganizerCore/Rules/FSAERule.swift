import Foundation

/// NSU Formula SAE team files.
struct FSAERule: Rule {
    let name = "FSAE"
    private static let phrases = ["fsae", "formula sae", "formula student", "nsu formula"]

    func evaluate(_ facts: FileFacts, config: OrganizerConfig) -> Decision? {
        let evidence: String
        let confidence: Double
        if let phrase = Self.phrases.first(where: { containsWords(facts.searchableName, $0) }) {
            evidence = "\"\(phrase)\" in the file name"
            confidence = 0.95
        } else if facts.isDocumentLike, let phrase = Self.phrases.first(where: { containsWords(facts.head(3_000), $0) }) {
            evidence = "\"\(phrase)\" in the text"
            confidence = 0.85
        } else {
            return nil
        }

        var rename: String?
        if facts.nameIsUnclear {
            if facts.head(1_500).contains("minutes") {
                rename = "\(FileNames.month(facts.downloadDate)) FSAE Meeting Minutes"
            } else {
                rename = facts.usableDocumentTitle
            }
        }
        return Decision(
            destination: config.fsae,
            newBaseName: rename,
            tags: [.fsae],
            confidence: confidence,
            reason: "FSAE team file: \(evidence)",
            source: .rule(name)
        )
    }
}

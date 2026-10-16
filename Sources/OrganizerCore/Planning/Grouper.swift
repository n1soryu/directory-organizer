import Foundation
import NaturalLanguage

/// Finds files of the same kind among the model's descriptions: categories with the same main
/// word ("Bills", "Utility Bills"), descriptions with the same main word ("router manual",
/// "airfryer manual"), or descriptions close in meaning. Code does the grouping; the model
/// only wrote the labels.
public enum Grouper {
    /// Labels closer than this (cosine distance, 0...2) are the same kind of thing. Measured
    /// on-device: two user manuals 0.50, two bills 0.75, unrelated kinds 0.89 and up.
    public static let closeInMeaning = 0.6

    /// Main words too vague to group by.
    static let vague: Set<String> = ["file", "document", "item", "misc", "miscellaneou", "miscellaneous", "other", "stuff",
                                     "download", "thing", "general", "unsorted"]

    /// Groups of indices into `descriptions`, biggest first; files alike with nothing else are
    /// groups of one. `distance` compares two labels (nil: unknown, only main words count).
    public static func groups(_ descriptions: [FileDescription],
                              distance: (String, String) -> Double? = embeddingDistance) -> [[Int]] {
        var parent = Array(descriptions.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        let heads = descriptions.map { mainWord($0.category) }
        let kindHeads = descriptions.map { mainWord($0.kind) }
        for i in descriptions.indices {
            for j in descriptions.indices where j > i {
                let sameWord = (heads[i] != nil && heads[i] == heads[j]) || (kindHeads[i] != nil && kindHeads[i] == kindHeads[j])
                let close = !sameWord && (distance(descriptions[i].kind.lowercased(), descriptions[j].kind.lowercased())
                    .map { $0 < closeInMeaning } ?? false)
                if sameWord || close { parent[root(j)] = root(i) }
            }
        }
        return Dictionary(grouping: descriptions.indices, by: root).values
            .map { $0.sorted() }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0] }
    }

    /// The last word of a category, lowercased and singular ("Utility Bills" → "bill"), or nil
    /// if it's too vague to group by.
    static func mainWord(_ category: String) -> String? {
        guard var word = category.lowercased().split(whereSeparator: { !$0.isLetter }).last.map(String.init),
              word.count >= 3 else { return nil }
        if word.hasSuffix("ies") { word = String(word.dropLast(3)) + "y" }
        else if word.hasSuffix("s") && !word.hasSuffix("ss") { word.removeLast() }
        return vague.contains(word) ? nil : word
    }

    /// Apple's on-device sentence embedding (no network). nil if it isn't installed.
    nonisolated(unsafe) static let embedding = NLEmbedding.sentenceEmbedding(for: .english)
    private static let lock = NSLock()

    public static func embeddingDistance(_ a: String, _ b: String) -> Double? {
        lock.withLock {
            guard let embedding else { return nil }
            // 2 is what it answers when it can't compare: unknown, not "opposite".
            let d = embedding.distance(between: a, and: b, distanceType: .cosine)
            return d.isFinite && d < 2 ? d : nil
        }
    }
}

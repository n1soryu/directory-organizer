import Foundation

/// Finds files of the same kind among the model's descriptions: categories with the same main
/// word ("Bills", "Utility Bills") or kinds with the same main word ("router manual",
/// "airfryer manual"). Code does the grouping; the model only wrote the labels.
/// (Similar in meaning, not just in words, comes with the catalog's embeddings: Milestone D.)
public enum Grouper {
    /// Main words too vague to group by.
    static let vague: Set<String> = ["file", "document", "item", "misc", "miscellaneou", "miscellaneous", "other", "stuff",
                                     "download", "thing", "general", "unsorted"]

    /// Groups of indices into `descriptions`, biggest first; files alike with nothing else are
    /// groups of one.
    public static func groups(_ descriptions: [FileDescription]) -> [[Int]] {
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
                if sameWord { parent[root(j)] = root(i) }
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
}

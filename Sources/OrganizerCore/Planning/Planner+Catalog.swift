import Foundation

/// What a run needs for the catalog (docs/mlx-plan.md, Milestone D): the catalog as read, the
/// move log it was read with, and the embedder.
public struct CatalogContext: Sendable {
    public var catalog: Catalog
    public var records: [MoveRecord]
    public var embedder: any TextEmbedder
    /// `ModelSpec.id` of the embedder.
    public var embedderID: String
    /// At most this many earlier files are carded per run (~5 s each), so a long history never
    /// turns one Organize Now into hours; the rest are done next time.
    public var catchUpLimit: Int

    public init(catalog: Catalog, records: [MoveRecord], embedder: any TextEmbedder, embedderID: String,
                catchUpLimit: Int = 40) {
        self.catalog = catalog
        self.records = records
        self.embedder = embedder
        self.embedderID = embedderID
        self.catchUpLimit = catchUpLimit
    }
}

/// A file's card and embedding, worked out in this run.
struct Embedded: Sendable {
    var card: FileCard?
    var source: CatalogEntry.CardSource
    var line: String
    var vector: [Float]
}

/// An earlier file the app filed that isn't catalogued yet, read where it is now.
struct EarlierFile: Sendable {
    var facts: FileFacts
    var record: MoveRecord
}

extension Planner {
    /// Would a model look at this file (a leftover, or an image)? Only those are worth hashing
    /// to find their card from an earlier run.
    func usesModel(_ item: FileFacts) -> Bool {
        guard !item.isDirectory else { return false }
        guard let ruled = rules.decide(item, config: config) else { return true }
        if case .rule(ImageRule.ruleName) = ruled.source { return true }
        return false
    }

    /// Files carded in an earlier run (waiting in Downloads, or downloaded again) keep their card:
    /// found by content hash, so a rename doesn't matter.
    func reusingCards(_ facts: [FileFacts], copies: [URL: URL], hashes: inout HashCache, catalog: Catalog) -> [FileFacts] {
        var facts = facts
        for index in facts.indices where copies[facts[index].url] == nil && !facts[index].needsDeepRead && usesModel(facts[index]) {
            guard let hash = hashes.hash(facts[index].url),
                  let entry = catalog.entry(forHash: hash), let card = entry.card else { continue }
            if entry.cardSource == .vision { facts[index].visionCard = card } else { facts[index].knownCard = card }
        }
        return facts
    }

    /// Earlier files the app filed that have no catalog entry yet (filed before the catalog, or by
    /// a rule in a quick scan), newest first, at most `catchUpLimit`. Safety cases (secure files,
    /// duplicates, password exports) and files sent to review (installers and the like) aren't
    /// catalogued. Only read, where they are now.
    func earlierFiles(_ context: CatalogContext) async -> [EarlierFile] {
        let fm = FileManager.default
        let review = homeRoot.appending(path: config.reviewFolder).standardizedFileURL.path + "/"
        var seen = Set(context.catalog.latest.keys)
        var picked: [MoveRecord] = []
        for record in context.records.reversed() where record.state == .moved {
            guard picked.count < context.catchUpLimit else { break }
            if record.decidedBy?.hasPrefix("safety") == true || record.movedPath.hasPrefix(review) { continue }
            let key = record.sha256 ?? "move:\(record.moveID.uuidString)"
            guard !seen.contains(key) else { continue }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: record.movedPath, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            seen.insert(key)
            picked.append(record)
        }
        var files: [EarlierFile] = []
        for record in picked {
            files.append(EarlierFile(facts: await extractor.facts(for: URL(filePath: record.movedPath)), record: record))
        }
        return files
    }

    /// Cards and embeds the earlier files (their images already have vision cards), and embeds
    /// again the entries another embedder made. Returns the new catalog entries.
    func cataloguingEarlier(_ earlier: [EarlierFile], context: CatalogContext,
                            progress: (@Sendable (Progress) -> Void)?) async throws -> [CatalogEntry] {
        var entries: [CatalogEntry] = []
        for (step, file) in earlier.enumerated() {
            try Task.checkCancellation()
            progress?(Progress(done: step, total: earlier.count, file: file.facts.name, step: .cataloguing))
            var card = file.facts.visionCard
            if card == nil, file.facts.kind != .image { card = try? await classifier.card(for: file.facts) }
            guard let embedded = await embed(file.facts, card: card, context: context) else { continue }
            entries.append(entry(embedded, sha256: file.record.sha256, moveID: file.record.moveID,
                                 path: file.record.movedPath, decidedBy: file.record.decidedBy, context: context))
        }
        for old in context.catalog.stale {
            try Task.checkCancellation()
            guard let vector = try? await context.embedder.embed(old.line) else { continue }
            var renewed = old
            renewed.time = Date()
            renewed.embedding = Vectors.encode(vector)
            renewed.embedder = context.embedderID
            entries.append(renewed)
        }
        return entries
    }

    /// Every leftover's card and embedding (for grouping by meaning, and for the catalog).
    func embeddingLeftovers(_ facts: [FileFacts], copies: [URL: URL], context: CatalogContext,
                            progress: (@Sendable (Progress) -> Void)?) async throws -> [URL: Embedded] {
        let leftovers = facts.filter {
            copies[$0.url] == nil && !$0.needsDeepRead && !$0.isDirectory && rules.decide($0, config: config) == nil
        }
        var result: [URL: Embedded] = [:]
        for (step, item) in leftovers.enumerated() {
            try Task.checkCancellation()
            progress?(Progress(done: step, total: leftovers.count, file: item.name, step: .grouping))
            let card = try? await classifier.card(for: item)
            result[item.url] = await embed(item, card: card, context: context)
        }
        return result
    }

    /// Catalog entries for this run's files: leftovers, and pictures the vision model saw. Not
    /// safety cases (duplicates found anywhere included: they're judged in the final actions),
    /// not folders, and not files the catalog already has.
    func runEntries(_ facts: [FileFacts], actions: [ProposedAction],
                    embedded: [URL: Embedded], hashes: inout HashCache, context: CatalogContext) async -> [CatalogEntry] {
        let finalSource = Dictionary(actions.map { ($0.source, $0.decidedBy) }, uniquingKeysWith: { $1 })
        var entries: [CatalogEntry] = []
        for item in facts where !item.isDirectory {
            guard let source = finalSource[item.url] else { continue }
            if case .safety = source { continue }
            guard let hash = hashes.hash(item.url), !context.catalog.contains(key: hash) else { continue }
            var found = embedded[item.url]
            if found == nil, let card = item.visionCard {
                found = await embed(item, card: card, context: context)
            }
            guard let found else { continue }
            entries.append(entry(found, sha256: hash, moveID: nil, path: item.url.path,
                                 decidedBy: source.description, context: context))
        }
        return entries
    }

    /// The card's line (or the start of the text, without a card), embedded.
    func embed(_ item: FileFacts, card: FileCard?, context: CatalogContext) async -> Embedded? {
        let source: CatalogEntry.CardSource = card == nil ? .rawText : item.visionCard != nil ? .vision : .text
        guard let line = card.map(CatalogEntry.line(for:)) ?? CatalogEntry.line(forText: item.text),
              let vector = try? await context.embedder.embed(line) else { return nil }
        return Embedded(card: card, source: source, line: line, vector: vector)
    }

    func entry(_ embedded: Embedded, sha256: String?, moveID: UUID?, path: String, decidedBy: String?,
               context: CatalogContext) -> CatalogEntry {
        CatalogEntry(sha256: sha256, moveID: moveID, path: path, card: embedded.card, cardSource: embedded.source,
                     line: embedded.line, embedding: Vectors.encode(embedded.vector), embedder: context.embedderID,
                     decidedBy: decidedBy)
    }
}

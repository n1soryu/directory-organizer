import Foundation
import Testing
@testable import OrganizerCore

/// Vectors by topic: a line mentioning a topic's word points along that topic's axis, so
/// "router user guide" and "airfryer manual" are close (both appliances) and a recipe isn't.
final class TopicEmbedder: TextEmbedder, @unchecked Sendable {
    static let topics: [[String]] = [["router", "fryer", "appliance", "manual", "guide"], ["pancake", "recipe"], ["bill", "energy"]]
    private let lock = NSLock()
    private var _texts: [String] = []
    var texts: [String] { lock.withLock { _texts } }

    func embed(_ text: String) async throws -> [Float] {
        lock.withLock { _texts.append(text) }
        let lower = text.lowercased()
        var vector = Self.topics.map { words in Float(words.filter { lower.contains($0) }.count) }
        vector.append(0.3)  // a little in common, as real embeddings have
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return vector.map { $0 / length }
    }
}

func record(_ path: String, moved: String, sha: String?, state: MoveRecord.State = .moved,
            decidedBy: String = "rule: course", time: Date = Date()) -> MoveRecord {
    MoveRecord(moveID: UUID(), batchID: UUID(), time: time, originalPath: path, movedPath: moved,
               restoredPath: state == .undone ? path : nil, sha256: sha, tagsBefore: [], tagsAfter: [],
               createdFolders: [], reason: nil, decidedBy: decidedBy, state: state)
}

func catalogEntry(_ path: String, sha: String?, line: String, vector: [Float], embedder: String = "e@1",
                  time: Date = Date(), moveID: UUID? = nil) -> CatalogEntry {
    CatalogEntry(time: time, sha256: sha, moveID: moveID, path: path, card: nil, cardSource: .text, line: line,
                 embedding: Vectors.encode(vector), embedder: embedder)
}

struct VectorTests {
    @Test func float16RoundTripKeepsTheDirection() throws {
        let vector: [Float] = (0..<1_024).map { sin(Float($0)) / 22 }
        let stored = Vectors.encode(vector)
        #expect(Data(base64Encoded: stored)?.count == 2_048)  // ~2 KB per file
        let back = try #require(Vectors.decode(stored))
        #expect(Vectors.cosine(vector, back) > 0.9999)
    }

    @Test func cosine() {
        #expect(Vectors.cosine([1, 0], [1, 0]) == 1)
        #expect(Vectors.cosine([1, 0], [0, 1]) == 0)
        #expect(Vectors.cosine([1, 0], [1, 0, 0]) == 0)  // different models' sizes never compare
        #expect(Vectors.decode("not base64!") == nil)
    }
}

@Suite(.serialized) struct CatalogStoreTests {
    let url = FileManager.default.temporaryDirectory.appending(path: "catalog-\(UUID().uuidString)/catalog.jsonl")

    @Test func appendsAndReadsBackSkippingDamagedLines() throws {
        let store = CatalogStore(url: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try store.entries().isEmpty)
        try store.append([catalogEntry("/d/a.pdf", sha: "a", line: "kind: bill", vector: [1, 0])])
        // A line cut short by a crash, then more entries: they start on a fresh line.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"time": "2026-"#.utf8))
        try handle.close()
        try store.append([catalogEntry("/d/b.pdf", sha: "b", line: "kind: recipe", vector: [0, 1]),
                          catalogEntry("/d/c.pdf", sha: "c", line: "kind: guide", vector: [1, 1])])
        #expect(try store.entries().map(\.sha256) == ["a", "b", "c"])
        #expect(try store.damagedLineCount() == 1)
        #expect(try store.entries()[0].line == "kind: bill")
    }

    @Test func sandboxCatalogSitsNextToTheMoveLog() {
        let home = URL(filePath: "/tmp/TestData/Home")
        #expect(CatalogStore(forHome: home).url.path == "/tmp/TestData/catalog.jsonl")
    }
}

struct CatalogStateTests {
    let downloads = "/s/Downloads"

    @Test func stateComesFromTheMoveLogAndTheDisk() {
        let entries = [
            catalogEntry("\(downloads)/filed.pdf", sha: "f", line: "filed", vector: [1, 0]),
            catalogEntry("\(downloads)/waiting.pdf", sha: "w", line: "waiting", vector: [1, 0]),
            catalogEntry("\(downloads)/undone.pdf", sha: "u", line: "undone", vector: [1, 0]),
            catalogEntry("\(downloads)/gone.pdf", sha: "g", line: "gone", vector: [1, 0]),
            catalogEntry("\(downloads)/moved-away.pdf", sha: "m", line: "moved away", vector: [1, 0]),
        ]
        let records = [
            // Renamed when filed: found by its hash all the same.
            record("\(downloads)/filed.pdf", moved: "/s/Home/Documents/Bills/2026 bill.pdf", sha: "f"),
            record("\(downloads)/undone.pdf", moved: "/s/Home/Documents/x.pdf", sha: "u", state: .undone),
            record("\(downloads)/moved-away.pdf", moved: "/s/Home/Documents/y.pdf", sha: "m"),
        ]
        let onDisk: Set<String> = ["/s/Home/Documents/Bills/2026 bill.pdf", "\(downloads)/waiting.pdf", "\(downloads)/undone.pdf"]
        let catalog = Catalog(entries: entries, records: records, embedder: "e@1", exists: onDisk.contains)
        let states = Dictionary(uniqueKeysWithValues: catalog.items.map { ($0.entry.line, $0.state) })
        #expect(states == ["filed": .filed, "waiting": .waiting, "undone": .undone, "gone": .gone, "moved away": .gone])
        #expect(catalog.items.first { $0.state == .filed }?.path == "/s/Home/Documents/Bills/2026 bill.pdf")
    }

    @Test func cardedAgainAfterAnUndoItIsWaiting() {
        let undo = record("/d/a.pdf", moved: "/h/a.pdf", sha: "a", state: .undone, time: Date(timeIntervalSince1970: 1_000))
        let moved = record("/d/b.pdf", moved: "/h/b.pdf", sha: "b", time: Date(timeIntervalSince1970: 1_000))
        let entries = [catalogEntry("/d/a.pdf", sha: "a", line: "a", vector: [1, 0]),
                       // Back-filled: follows its move, even though it was carded later.
                       catalogEntry("/h/b.pdf", sha: "b", line: "b", vector: [1, 0], moveID: moved.moveID)]
        let catalog = Catalog(entries: entries, records: [undo, moved], embedder: "e@1", exists: { _ in true })
        #expect(catalog.items.map(\.state) == [.waiting, .filed])
    }

    @Test func newestEntryWinsAndOtherEmbeddersAreStale() {
        let old = Date(timeIntervalSince1970: 1_000)
        let entries = [
            catalogEntry("/d/a.pdf", sha: "a", line: "old card", vector: [1, 0], time: old),
            catalogEntry("/d/a.pdf", sha: "a", line: "new card", vector: [1, 0]),
            catalogEntry("/d/b.pdf", sha: "b", line: "other model", vector: [1, 0], embedder: "other@2"),
        ]
        let catalog = Catalog(entries: entries, records: [], embedder: "e@1", exists: { _ in true })
        #expect(catalog.items.map(\.entry.line) == ["new card"])
        #expect(catalog.stale.map(\.line) == ["other model"])
        // A stale entry's card can still be reused; only its vector can't.
        #expect(catalog.entry(forHash: "b")?.line == "other model")
    }

    @Test func nearestOffersOnlyLiveFilesBestFirst() {
        let entries = [
            catalogEntry("/d/close.pdf", sha: "close", line: "close", vector: [1, 0.1]),
            catalogEntry("/d/far.pdf", sha: "far", line: "far", vector: [0, 1]),
            catalogEntry("/d/undone.pdf", sha: "undone", line: "undone", vector: [1, 0]),
            catalogEntry("/d/self.pdf", sha: "self", line: "self", vector: [1, 0]),
        ]
        let records = [record("/d/undone.pdf", moved: "/h/u.pdf", sha: "undone", state: .undone)]
        let catalog = Catalog(entries: entries, records: records, embedder: "e@1", exists: { _ in true })
        let nearest = catalog.nearest(to: [1, 0], k: 5, excluding: "self")
        #expect(nearest.map(\.item.entry.line) == ["close", "far"])
        #expect(nearest[0].score > nearest[1].score)
    }
}

struct SimilarityGrouperTests {
    @Test func nearestNeighboursAboveTheFloorGroup() {
        let vectors: [[Float]] = [[1, 0, 0], [0, 1, 0], [0.95, 0.1, 0], [0.9, 0, 0.2], [0, 0, 1]]
        #expect(SimilarityGrouper.groups(vectors) == [[0, 2, 3], [1], [4]])
    }

    @Test func nothingCloseEnoughStaysAlone() {
        #expect(SimilarityGrouper.groups([[1, 0], [0.6, 0.8]]) == [[0], [1]])  // 0.6 < 0.75
        #expect(SimilarityGrouper.groups([[1, 0], []]) == [[0], [1]])          // no vector: never grouped
    }
}

/// The catalog in a whole run: grouping by meaning, entries returned, cards reused, back-fill.
@Suite(.serialized) struct CatalogPlanTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "file-organizer-catalog-\(UUID().uuidString)")
    var downloads: URL { root.appending(path: "Downloads") }
    var home: URL { root.appending(path: "Home") }

    /// Cards by file name; counts card questions; says the appliance group belongs together.
    final class FakeModel: FileClassifier, @unchecked Sendable {
        let name = "fake"
        private let lock = NSLock()
        private var _carded: [String] = []
        private var _groups: [[String]] = []
        var carded: [String] { lock.withLock { _carded } }
        var groups: [[String]] { lock.withLock { _groups } }

        static let cards: [String: FileCard] = [
            "router": FileCard(kind: "router user guide", subject: "router setup", suggestedName: "Router guide", summary: "How to set up a router."),
            "fryer": FileCard(kind: "appliance manual", subject: "airfryer", suggestedName: "Fryer manual", summary: "Using an airfryer."),
            "pancakes": FileCard(kind: "recipe", subject: "pancake", suggestedName: "Pancakes", summary: "A pancake recipe."),
            "course": FileCard(kind: "lecture notes", subject: "economics", suggestedName: "Notes", summary: "Notes."),
        ]

        func card(for facts: FileFacts) async throws -> FileCard {
            if let card = facts.knownCard { return card }
            lock.withLock { _carded.append(facts.baseName) }
            guard let card = Self.cards[facts.baseName] else { throw ClassifierError.unavailable("no card") }
            return card
        }
        func describe(_ facts: FileFacts) async throws -> FileDescription {
            let kind = try await card(for: facts).kind
            return FileDescription(kind: kind, category: kind)
        }
        func placeGroup(_ request: GroupRequest) async throws -> GroupSuggestion {
            lock.withLock { _groups.append(request.members.map(\.baseName).sorted()) }
            return GroupSuggestion(belongTogether: true, suggestion: ClassifierSuggestion(
                destination: "Documents/Manuals", isNewFolder: true, confidence: 0.9, reason: "appliance manuals"))
        }
        func suggest(_ request: ClassificationRequest) async throws -> ClassifierSuggestion {
            ClassifierSuggestion(destination: OrganizerConfig().reviewFolder, confidence: 0.5, reason: "unsure")
        }
        func suggestName(for facts: FileFacts) async throws -> NameSuggestion { throw ClassifierError.unavailable("") }
    }

    func setUp() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: "Documents"), withIntermediateDirectories: true)
        for name in ["router", "fryer", "pancakes"] {
            try Data("\(name) text".utf8).write(to: downloads.appending(path: "\(name).txt"))
        }
        // An identical copy: a duplicate, never catalogued.
        try Data("router text".utf8).write(to: downloads.appending(path: "router (1).txt"))
        // A password export: a safety case, never catalogued.
        try Data("name,url,username,password,note\nx,y,z,w,v".utf8).write(to: downloads.appending(path: "export.csv"))
    }

    func context(entries: [CatalogEntry] = [], records: [MoveRecord] = [], embedder: TopicEmbedder, limit: Int = 40) -> CatalogContext {
        CatalogContext(catalog: Catalog(entries: entries, records: records, embedder: "topic@1"), records: records,
                       embedder: embedder, embedderID: "topic@1", catchUpLimit: limit)
    }

    @Test func manualsGroupByMeaningAndLeftoversAreCatalogued() async throws {
        try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FakeModel()
        var planner = Planner(homeRoot: home)
        planner.classifier = model
        planner.catalog = context(embedder: TopicEmbedder())
        let plan = try await planner.plan(folder: downloads)

        // "router user guide" and "appliance manual" share no main word, but are close in meaning.
        #expect(model.groups == [["fryer", "router"]])
        let entries = plan.catalogEntries
        #expect(Set(entries.map { URL(filePath: $0.path).lastPathComponent }) == ["router.txt", "fryer.txt", "pancakes.txt"])
        #expect(entries.allSatisfy { $0.embedder == "topic@1" && $0.sha256 != nil && $0.cardSource == .text })
        #expect(entries.first { $0.path.hasSuffix("router.txt") }?.line == FakeModel.cards["router"]!.line)
    }

    @Test func aSecondRunReusesTheCards() async throws {
        try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = FakeModel()
        var planner = Planner(homeRoot: home)
        planner.classifier = first
        planner.catalog = context(embedder: TopicEmbedder())
        let entries = try await planner.plan(folder: downloads).catalogEntries
        #expect(Set(first.carded) == ["router", "fryer", "pancakes"])

        let second = FakeModel()
        planner.classifier = second
        planner.catalog = context(entries: entries, embedder: TopicEmbedder())
        let plan = try await planner.plan(folder: downloads)
        #expect(second.carded.isEmpty)
        #expect(plan.catalogEntries.isEmpty)  // already catalogued
    }

    @Test func earlierFilesAreBackFilledUpToTheLimit() async throws {
        try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let filed = home.appending(path: "Documents/University")
        try fm.createDirectory(at: filed, withIntermediateDirectories: true)
        let review = home.appending(path: OrganizerConfig().reviewFolder)
        try fm.createDirectory(at: review, withIntermediateDirectories: true)
        var records: [MoveRecord] = []
        for (index, name) in ["course", "router"].enumerated() {
            let url = filed.appending(path: "\(name).txt")
            try Data("earlier \(name)".utf8).write(to: url)
            records.append(record("/x/\(name).txt", moved: url.path, sha: "sha-\(name)",
                                  time: Date(timeIntervalSince1970: Double(1_000 + index))))
        }
        let secure = filed.appending(path: "secret.txt")
        try Data("key".utf8).write(to: secure)
        records.append(record("/x/secret.txt", moved: secure.path, sha: "s", decidedBy: "safety: sensitive file"))
        let installer = review.appending(path: "tool.txt")
        try Data("installer".utf8).write(to: installer)
        records.append(record("/x/tool.txt", moved: installer.path, sha: "t", decidedBy: "rule: installer"))
        records.append(record("/x/gone.txt", moved: filed.appending(path: "gone.txt").path, sha: "g"))

        var planner = Planner(homeRoot: home)
        planner.classifier = FakeModel()
        planner.catalog = context(records: records, embedder: TopicEmbedder(), limit: 1)
        let entries = try await planner.plan(folder: downloads).catalogEntries.filter { $0.moveID != nil }
        // Newest first, one per run; never the secure file, the review folder or a missing file.
        #expect(entries.map(\.sha256) == ["sha-router"])
        #expect(entries[0].decidedBy == "rule: course")
        #expect(entries[0].path.hasSuffix("Documents/University/router.txt"))

        planner.catalog = context(entries: entries, records: records, embedder: TopicEmbedder(), limit: 40)
        let next = try await planner.plan(folder: downloads).catalogEntries.filter { $0.moveID != nil }
        #expect(next.map(\.sha256) == ["sha-course"])
    }

    @Test func staleEntriesAreEmbeddedAgainFromTheirLine() async throws {
        try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = catalogEntry("/elsewhere/a.pdf", sha: "a", line: "kind: energy bill", vector: [1], embedder: "old@0")
        let embedder = TopicEmbedder()
        var planner = Planner(homeRoot: home)
        planner.classifier = FakeModel()
        planner.catalog = context(entries: [old], embedder: embedder)
        let renewed = try await planner.plan(folder: downloads).catalogEntries.filter { $0.sha256 == "a" }
        #expect(renewed.count == 1)
        #expect(renewed[0].embedder == "topic@1")
        #expect(embedder.texts.contains("kind: energy bill"))
    }

    @Test func withoutTheCatalogNothingIsEmbedded() async throws {
        try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FakeModel()
        var planner = Planner(homeRoot: home)
        planner.classifier = model
        let plan = try await planner.plan(folder: downloads)
        #expect(plan.catalogEntries.isEmpty)
        // Grouped by shared words only: guide and manual don't match.
        #expect(model.groups.isEmpty)
    }
}

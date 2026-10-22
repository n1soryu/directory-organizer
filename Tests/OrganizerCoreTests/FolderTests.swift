import Foundation
import Testing
@testable import OrganizerCore
import TestDataKit

/// Folders in Downloads: read all the way down, checked for sensitive files, left alone while
/// they change, and kept together or unpacked as the model says.
@Suite(.serialized) struct FolderTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "file-organizer-folders-\(UUID().uuidString)")
    var downloads: URL { root.appending(path: "Downloads") }
    var home: URL { root.appending(path: "Home") }
    var journal: MoveJournal { MoveJournal(url: root.appending(path: "moves.jsonl")) }

    /// Unpacks the folders named in `unpack`, sends every file to review, and remembers
    /// which folders it was asked about.
    final class FakeModel: FileClassifier, @unchecked Sendable {
        let name = "fake"
        let unpack: Set<String>
        private let lock = NSLock()
        private var _asked: [String] = []
        var asked: [String] { lock.withLock { _asked } }

        init(unpack: Set<String>) { self.unpack = unpack }

        func decide(_ request: DecisionRequest) async throws -> FolderDecision {
            throw ClassifierError.unavailable("fake")
        }
        func suggestName(for facts: FileFacts) async throws -> NameSuggestion {
            throw ClassifierError.unavailable("fake")
        }
        func suggestUnpack(for facts: FileFacts) async throws -> UnpackSuggestion {
            lock.withLock { _asked.append(facts.name) }
            return UnpackSuggestion(unpack: unpack.contains(facts.name), confidence: 0.9, reason: "fake")
        }
    }

    func plan(_ model: any FileClassifier = StubClassifier()) async throws -> Plan {
        var planner = Planner(homeRoot: home)
        planner.classifier = model
        return try await planner.plan(folder: downloads)
    }

    @Test func readsAFolderAllTheWayDown() async throws {
        _ = try TestDataBuilder.build(at: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let facts = await FactExtractor().facts(for: downloads.appending(path: "Old phone backup"))
        let contents = try #require(facts.folder)
        #expect(contents.fileCount == 2 && contents.folderCount == 1)
        #expect(contents.sample.contains("notes/seed.txt"))
        #expect(contents.sensitive.count == 1 && contents.sensitive[0].hasPrefix("notes/seed.txt: 12 BIP-39 words"))
        // The folder's size and date are the whole tree's.
        let files = ["notes/seed.txt", "notes/list.txt"].map { downloads.appending(path: "Old phone backup/\($0)") }
        let sizes = try files.map { Int64(try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        #expect(facts.size == sizes.reduce(0, +) && facts.size > 0)
        #expect(facts.fileExtension.isEmpty)
    }

    @Test func theModelUnpacksOnlyWhatItMay() async throws {
        _ = try TestDataBuilder.build(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FakeModel(unpack: ["Misc downloads", "todo-app-main", "Old phone backup"])
        let plan = try await plan(model)

        // Code projects, sensitive and empty folders are decided by rules; the model isn't asked.
        #expect(Set(model.asked) == ["Misc downloads", "Dune.Part.Two.2024.1080p.WEB-DL"])
        #expect(plan.unpacked.map(\.lastPathComponent) == ["Misc downloads"])
        let names = Set(plan.actions.map(\.originalName))
        #expect(names.isSuperset(of: ["wasa_bill.pdf", "HD9252_manual.pdf", "reminder.txt", "Dune.Part.Two.2024.1080p.WEB-DL", "todo-app-main"]))
        #expect(!names.contains("Misc downloads"))
        let bill = try #require(plan.actions.first { $0.originalName == "wasa_bill.pdf" })
        #expect(bill.reason.hasPrefix("From Misc downloads/"))
    }

    @Test func anUnpackedFolderEndsUpEmptyInReview() async throws {
        _ = try TestDataBuilder.build(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = try await plan(FakeModel(unpack: ["Misc downloads"])).actions
            .filter { $0.source.path.contains("/Misc downloads/") }
        #expect(inside.count == 3)
        let results = Applier(homeRoot: home, journal: journal).apply(inside)
        #expect(results.allSatisfy { $0.outcome == .moved })

        // Emptying it just changed it, so it settles first (the app rescans after `retryAfter`).
        #expect(try await plan().skipped.contains { $0.name == "Misc downloads" && $0.retryAfter != nil })
        var later = Planner(homeRoot: home)
        later.settleTime = 0
        let next = try await later.plan(folder: downloads)
        let shell = try #require(next.actions.first { $0.originalName == "Misc downloads" })
        #expect(shell.destinationFolder == OrganizerConfig().reviewFolder)
        #expect(shell.decidedBy == .rule("empty folder"))
    }

    @Test func aFolderStillBeingWrittenIsLeftAlone() async throws {
        try FileManager.default.createDirectory(at: downloads.appending(path: "Unzipping/deep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("part".utf8).write(to: downloads.appending(path: "Unzipping/deep/a.txt"))

        let plan = try await plan()
        #expect(plan.actions.isEmpty)
        let skipped = try #require(plan.skipped.first)
        #expect(skipped.name == "Unzipping")
        #expect((skipped.retryAfter ?? 0) > 0)
    }

    @Test func aFolderThatChangedInsideIsNotMoved() async throws {
        _ = try TestDataBuilder.build(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let film = try #require(try await plan().actions.first { $0.originalName == "Dune.Part.Two.2024.1080p.WEB-DL" })
        // Something deep inside changes after planning (the folder's own date doesn't).
        try Data("more of the download".utf8).write(to: film.source.appending(path: "Dune.Part.Two.2024.1080p.WEB-DL.nfo"))

        let result = try #require(Applier(homeRoot: home, journal: journal).apply([film]).first)
        guard case .skipped = result.outcome else { Issue.record("expected skip, got \(result.outcome)"); return }
        #expect(FileManager.default.fileExists(atPath: film.source.path))
    }
}

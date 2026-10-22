import Foundation
import Testing
@testable import OrganizerCore
import TestDataKit

/// A classifier that answers whatever the test tells it to, so the planner's checks can be
/// tested without the real model.
struct FakeClassifier: FileClassifier {
    let name = "fake"
    var answer: FolderDecision? = nil
    var title: NameSuggestion? = nil
    var unavailable = false
    var invalid = false

    func decide(_ request: DecisionRequest) async throws -> FolderDecision {
        if unavailable { throw ClassifierError.unavailable("switched off for the test") }
        if invalid { throw ClassifierError.invalidAnswer("nonsense three times") }
        return try #require(answer)
    }

    func suggestName(for facts: FileFacts) async throws -> NameSuggestion {
        if unavailable { throw ClassifierError.unavailable("switched off for the test") }
        return try #require(title)
    }
}

/// The planner must check every model answer; these try to sneak bad ones past it.
@Suite(.serialized) struct ModelSafetyTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "file-organizer-model-\(UUID().uuidString)")

    func planner(_ classifier: FakeClassifier) throws -> Planner {
        let fm = FileManager.default
        for folder in ["Documents/Essays", "Documents/Manuals", "Documents/University", "Pictures/Downloaded Images",
                       "Desktop/To Delete (Review)"] {
            try fm.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
        }
        var planner = Planner(homeRoot: home)
        planner.classifier = classifier
        return planner
    }

    func answer(_ action: FolderDecision.Action, _ folder: String?, earlier: [String] = [], name: String? = nil) -> FakeClassifier {
        FakeClassifier(answer: FolderDecision(reason: "trust me", action: action, folder: folder, moveEarlier: earlier,
                                              newFileName: name))
    }

    /// Decides with one similar earlier file (E1), waiting in Downloads unless `filedIn` says where it is.
    func decideWithEarlier(_ planner: Planner, _ file: FileFacts, filedIn folder: String? = nil) async -> (verdict: Verdict, pulled: [PulledFile]) {
        let path = folder.map { home.appending(path: "\($0)/old.pdf").path } ?? "/tmp/Downloads/old.pdf"
        var records: [MoveRecord] = []
        if folder != nil { records.append(record("/tmp/Downloads/old.pdf", moved: path, sha: "old")) }
        let catalog = Catalog(entries: [catalogEntry("/tmp/Downloads/old.pdf", sha: "old", line: "kind: thing", vector: [1, 0],
                                                     time: Date(timeIntervalSince1970: 0))],
                              records: records, embedder: "e@1", exists: { _ in true })
        var newFolders: [String: String] = [:]
        return await planner.decide(file, folders: FolderCatalog.options(homeRoot: home, config: planner.config),
                                    neighbourhood: Neighbourhood(catalog: catalog, homeRoot: home), vector: [1, 0], key: "new",
                                    newFolders: &newFolders)
    }

    @Test func joinsAnOfferedFolderAndTakesTagsFromIt() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let planner = try planner(answer(.join, "Documents/Essays"))
        // The folder's tag is the one its files carry.
        for name in ["a.docx", "b.docx"] {
            let file = home.appending(path: "Documents/Essays/\(name)")
            try Data("x".utf8).write(to: file)
            try FinderTags.writeRaw([FinderTags.encode(.personal)], to: file)
        }
        let decision = try #require(await planner.decide(facts(name: "essay.docx", text: "My essay")).decision)
        #expect(decision.destination == "Documents/Essays")
        #expect(decision.tags == [.personal])
        #expect(decision.source == .classifier("fake"))
    }

    @Test(arguments: ["Library/LaunchAgents", "Documents/Made Up", "/etc", "Documents/../Library", "Downloads"])
    func foldersThatWerentOfferedMeanWait(_ folder: String) async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let planner = try planner(answer(.join, folder))
        let verdict = await planner.decide(facts(name: "notes.txt", text: "eggs, milk"))
        #expect(verdict.waitReason?.contains("rejected") == true, "\(folder)")
    }

    @Test func waitStaysInDownloads() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let planner = try planner(answer(.wait, nil))
        #expect(await planner.decide(facts(name: "x.docx", text: "hmm")).waitReason == "Nothing like it yet: trust me")
    }

    @Test func universityNeedsNSUEvidence() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let planner = try planner(answer(.join, "Documents/University"))
        let manual = await planner.decide(facts(name: "router guide.pdf", text: "Archer AX55 user guide"))
        #expect(manual.waitReason?.contains("no sign it's an NSU file") == true)

        var nsu = facts(name: "notice.pdf", text: "Exam schedule")
        nsu.whereFroms = ["https://www.northsouth.edu/notice.pdf"]
        #expect(await planner.decide(nsu).decision?.destination == "Documents/University")
    }

    @Test func aNewFolderTakesAnEarlierFileAlong() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let planner = try planner(answer(.newFolder, "Documents/Bills", earlier: ["E1"]))
        let (verdict, pulled) = await decideWithEarlier(planner, facts(name: "bill.pdf", text: "Electricity bill"))
        #expect(verdict.decision?.destination == "Documents/Bills")
        #expect(verdict.decision?.confidence == 0.8)
        #expect(pulled.map(\.path) == ["/tmp/Downloads/old.pdf"])
        #expect(pulled.first?.waiting == true)
    }

    @Test func aNewFolderNeedsAnEarlierFile() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        // No earlier file listed: invalid, so it waits.
        let none = try planner(answer(.newFolder, "Documents/Bills"))
        #expect(await decideWithEarlier(none, facts(name: "bill.pdf", text: "Electricity bill")).verdict.waitReason != nil)
        // And with no earlier files at all, a new folder can't happen.
        let alone = try planner(answer(.newFolder, "Documents/Bills", earlier: ["E1"]))
        #expect(await alone.decide(facts(name: "bill.pdf", text: "Electricity bill")).waitReason != nil)
    }

    @Test func newFoldersOnlyUnderTheRightParent() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        // Audio can only get a new folder under Music, and nothing may go 3 levels deep.
        let audio = try planner(answer(.newFolder, "Documents/Podcasts", earlier: ["E1"]))
        #expect(await decideWithEarlier(audio, facts(name: "episode.mp3", text: nil)).verdict.waitReason != nil)
        let music = try planner(answer(.newFolder, "Music/Podcasts", earlier: ["E1"]))
        #expect(await decideWithEarlier(music, facts(name: "episode.mp3", text: nil)).verdict.decision?.destination == "Music/Podcasts")
        let deep = try planner(answer(.newFolder, "Documents/A/B/C", earlier: ["E1"]))
        #expect(await decideWithEarlier(deep, facts(name: "a.pdf", text: "x")).verdict.waitReason != nil)
    }

    @Test(arguments: ["Documents/.hidden", "Documents/Library", "Documents/a:b", "Documents/123"])
    func badNewFolderNamesMeanWait(_ folder: String) async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let planner = try planner(answer(.newFolder, folder, earlier: ["E1"]))
        #expect(await decideWithEarlier(planner, facts(name: "a.pdf", text: "x")).verdict.waitReason != nil)
    }

    @Test func reusesAFolderWithNearlyTheSameName() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        // "Manual" is close enough to the existing "Manuals".
        let planner = try planner(answer(.newFolder, "Documents/manual", earlier: ["E1"]))
        let (verdict, pulled) = await decideWithEarlier(planner, facts(name: "guide.pdf", text: "user guide"))
        #expect(verdict.decision?.destination == "Documents/Manuals")
        #expect(pulled.count == 1)
    }

    @Test func earlierFilesAlreadyThereAreLeftOut() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let planner = try planner(answer(.join, "Documents/Essays", earlier: ["E1"]))
        let (verdict, pulled) = await decideWithEarlier(planner, facts(name: "essay.docx", text: "An essay"), filedIn: "Documents/Essays")
        #expect(verdict.decision?.destination == "Documents/Essays")
        #expect(pulled.isEmpty)
    }

    @Test func unavailableModelMeansReview() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let planner = try planner(FakeClassifier(unavailable: true))
        let decision = try #require(await planner.decide(facts(name: "notes.txt", text: "eggs")).decision)
        #expect(decision.destination == planner.config.reviewFolder)
        #expect(decision.reason.contains("switched off for the test"))
    }

    @Test func noUsableAnswerMeansWait() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let planner = try planner(FakeClassifier(invalid: true))
        #expect(await planner.decide(facts(name: "notes.txt", text: "eggs")).waitReason?.contains("nonsense three times") == true)
    }

    @Test func theModelsNameIsUsedOnlyForUnclearNames() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let planner = try planner(answer(.join, "Documents/Essays", name: "Climate essay draft"))
        #expect(await planner.decide(facts(name: "document (3).docx", text: "An essay")).decision?.newBaseName == "Climate essay draft")
        #expect(await planner.decide(facts(name: "My essay.docx", text: "An essay")).decision?.newBaseName == nil)
    }

    @Test func namesUnclearImagesWithTheDate() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        var classifier = FakeClassifier()
        classifier.title = NameSuggestion(title: "Router wireless settings page.png", confidence: 0.9)
        var image = facts(name: "IMG_4821.png", text: nil)
        image.image = ImageInfo(dateTaken: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12)))
        let decision = try await planner(classifier).decide(image).decision
        #expect(decision?.newBaseName == "2026-10-12 Router wireless settings page")
    }

    @Test func ignoresUselessOrUnsureNames() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        for title in [NameSuggestion(title: "IMG_1234", confidence: 0.9), NameSuggestion(title: "Good name", confidence: 0.4),
                      NameSuggestion(title: "   ", confidence: 0.9)] {
            var classifier = FakeClassifier()
            classifier.title = title
            let decision = try await planner(classifier).decide(facts(name: "IMG_4821.png", text: nil)).decision
            #expect(decision?.newBaseName == nil, "\(title)")
        }
    }

    @Test func safetyDecisionsAreNeverRenamedByTheModel() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        var classifier = FakeClassifier()
        classifier.title = NameSuggestion(title: "Holiday photo", confidence: 0.9)
        let phrase = BIP39.orderedWords.prefix(12).joined(separator: " ")
        let decision = try await planner(classifier).decide(facts(name: "IMG_9.jpg", text: phrase)).decision
        #expect(decision?.newBaseName?.hasSuffix("Recovery Phrase") == true)
    }
}

@Suite struct FolderCatalogTests {
    @Test func discoversFoldersAndLearnsTagsFromTheirFiles() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for folder in ["Documents/University/ECO372", "Documents/.secret", "Pictures/Wallpapers", "Pictures/Lib.photoslibrary"] {
            try FileManager.default.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
        }
        // 2 of 3 files carry NSU: that's the folder's tag. 1 of 3 carries Work: not enough.
        for (name, tags) in [("a.pdf", [Tag.nsu]), ("b.pdf", [.nsu, Tag("Work", .none)]), ("c.pdf", [])] {
            let file = home.appending(path: "Documents/University/ECO372/\(name)")
            try Data(name.utf8).write(to: file)
            try FinderTags.writeRaw(tags.map(FinderTags.encode), to: file)
        }
        let options = FolderCatalog.options(homeRoot: home, config: OrganizerConfig())
        let paths = options.map(\.path)
        #expect(paths.contains("Documents/University/ECO372"))
        #expect(paths.contains("Pictures/Wallpapers"))
        #expect(!paths.contains { $0.contains(".secret") || $0.contains("photoslibrary") })
        #expect(options.first { $0.path == "Documents/University/ECO372" }?.tags == [.nsu])
        // Empty roots aren't destinations; the two universal folders always are.
        #expect(!paths.contains("Documents") && !paths.contains("Music"))
        #expect(paths.contains("Desktop/To Delete (Review)") && paths.contains("Documents/Secure"))
    }

    @Test func looseNamesMatch() {
        #expect(FolderCatalog.looseKey("Manuals") == FolderCatalog.looseKey("manual"))
        #expect(FolderCatalog.looseKey("Bills!") == FolderCatalog.looseKey("bill"))
        #expect(FolderCatalog.looseKey("Bus") == "bus")
    }

    @Test func summaryIncludesSourceAndCutsText() {
        var item = facts(name: "bill.pdf", text: String(repeating: "x", count: 5_000))
        item.whereFroms = ["https://www.desco.org.bd/bill.pdf"]
        let summary = FactSummary.describe(item, textLimit: 100)
        #expect(summary.contains("desco.org.bd"))
        #expect(summary.count < 600)
    }
}

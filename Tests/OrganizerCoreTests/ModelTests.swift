import Foundation
import Testing
@testable import OrganizerCore
import TestDataKit

/// A classifier that answers whatever the test tells it to, so the planner's checks can be
/// tested without the real model.
struct FakeClassifier: FileClassifier {
    let name = "fake"
    var suggestion: ClassifierSuggestion? = nil
    var title: NameSuggestion? = nil
    var unavailable = false

    func suggest(_ request: ClassificationRequest) async throws -> ClassifierSuggestion {
        if unavailable { throw ClassifierError.unavailable("switched off for the test") }
        return try #require(suggestion)
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

    func suggest(_ destination: String, newFolder: Bool = false, confidence: Double = 0.9, newName: String? = nil) -> FakeClassifier {
        FakeClassifier(suggestion: ClassifierSuggestion(destination: destination, isNewFolder: newFolder, newBaseName: newName,
                                                        confidence: confidence, reason: "trust me"))
    }

    @Test func acceptsAnOfferedFolderAndTakesTagsFromIt() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let planner = try planner(suggest("Documents/Essays"))
        // The folder's tag is the one its files carry.
        for name in ["a.docx", "b.docx"] {
            let file = home.appending(path: "Documents/Essays/\(name)")
            try Data("x".utf8).write(to: file)
            try FinderTags.writeRaw([FinderTags.encode(.personal)], to: file)
        }
        let decision = await planner.decide(facts(name: "essay.docx", text: "My essay"))
        #expect(decision.destination == "Documents/Essays")
        #expect(decision.tags == [.personal])
    }

    @Test(arguments: ["Library/LaunchAgents", "Documents/Made Up", "/etc", "Documents/../Library"])
    func rejectsFoldersThatWerentOffered(_ destination: String) async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let planner = try planner(suggest(destination))
        let decision = await planner.decide(facts(name: "notes.txt", text: "eggs, milk"))
        #expect(decision.destination == planner.config.reviewFolder)
        #expect(decision.alerts.contains { $0.kind == .rejected })
    }

    @Test func lowConfidenceGoesToReview() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let planner = try planner(suggest("Documents/Essays", confidence: 0.4))
        #expect(await planner.decide(facts(name: "x.docx", text: "hmm")).destination == planner.config.reviewFolder)
    }

    @Test func universityNeedsNSUEvidence() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let planner = try planner(suggest("Documents/University"))
        let manual = await planner.decide(facts(name: "router guide.pdf", text: "Archer AX55 user guide"))
        #expect(manual.destination == planner.config.reviewFolder)
        #expect(manual.reason.contains("no sign it's an NSU file"))

        var nsu = facts(name: "notice.pdf", text: "Exam schedule")
        nsu.whereFroms = ["https://www.northsouth.edu/notice.pdf"]
        #expect(await planner.decide(nsu).destination == "Documents/University")
    }

    @Test func newFolderUnderTheRightParent() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let planner = try planner(suggest("Documents/Bills", newFolder: true))
        #expect(await planner.decide(facts(name: "bill.pdf", text: "Electricity bill")).destination == "Documents/Bills")

        // Audio can only get a new folder under Music, and nothing may go 3 levels deep.
        let audio = try self.planner(suggest("Documents/Podcasts", newFolder: true))
        #expect(await audio.decide(facts(name: "episode.mp3", text: nil)).destination == planner.config.reviewFolder)
        let music = try self.planner(suggest("Music/Podcasts", newFolder: true))
        #expect(await music.decide(facts(name: "episode.mp3", text: nil)).destination == "Music/Podcasts")
        let deep = try self.planner(suggest("Documents/A/B/C", newFolder: true))
        #expect(await deep.decide(facts(name: "a.pdf", text: "x")).destination == planner.config.reviewFolder)
    }

    @Test(arguments: ["Documents/.hidden", "Documents/Library", "Documents/a:b", "Documents/123"])
    func rejectsBadNewFolderNames(_ destination: String) async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let planner = try planner(suggest(destination, newFolder: true))
        #expect(await planner.decide(facts(name: "a.pdf", text: "x")).destination == planner.config.reviewFolder)
    }

    @Test func reusesAFolderWithNearlyTheSameName() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        // "Manual" is close enough to the existing "Manuals".
        let planner = try planner(suggest("Documents/manual", newFolder: true))
        #expect(await planner.decide(facts(name: "guide.pdf", text: "user guide")).destination == "Documents/Manuals")
    }

    @Test func unavailableModelMeansReview() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let planner = try planner(FakeClassifier(unavailable: true))
        let decision = await planner.decide(facts(name: "notes.txt", text: "eggs"))
        #expect(decision.destination == planner.config.reviewFolder)
        #expect(decision.reason.contains("switched off for the test"))
    }

    @Test func namesUnclearImagesWithTheDate() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        var classifier = FakeClassifier()
        classifier.title = NameSuggestion(title: "Router wireless settings page.png", confidence: 0.9)
        var image = facts(name: "IMG_4821.png", text: nil)
        image.image = ImageInfo(dateTaken: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12)))
        let decision = await try planner(classifier).decide(image)
        #expect(decision.newBaseName == "2026-10-12 Router wireless settings page")
    }

    @Test func ignoresUselessOrUnsureNames() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        for title in [NameSuggestion(title: "IMG_1234", confidence: 0.9), NameSuggestion(title: "Good name", confidence: 0.4),
                      NameSuggestion(title: "   ", confidence: 0.9)] {
            var classifier = FakeClassifier()
            classifier.title = title
            let decision = await try planner(classifier).decide(facts(name: "IMG_4821.png", text: nil))
            #expect(decision.newBaseName == nil, "\(title)")
        }
    }

    @Test func safetyDecisionsAreNeverRenamedByTheModel() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        var classifier = FakeClassifier()
        classifier.title = NameSuggestion(title: "Holiday photo", confidence: 0.9)
        let phrase = BIP39.orderedWords.prefix(12).joined(separator: " ")
        let decision = await try planner(classifier).decide(facts(name: "IMG_9.jpg", text: phrase))
        #expect(decision.newBaseName?.hasSuffix("Recovery Phrase") == true)
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

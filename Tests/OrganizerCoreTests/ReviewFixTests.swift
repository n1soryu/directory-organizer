import Foundation
import Testing
@testable import OrganizerCore

/// Medium findings from the code review (BUG-REPORT.md) that needed a test of their own.
@Suite(.serialized) struct ReviewFixTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "file-organizer-review-\(UUID().uuidString)")

    /// MED-3: a zip with a private key inside is flagged by the key's name.
    @Test func aZipWithAKeyInsideIsFlagged() {
        var zip = facts(name: "backup.zip", text: nil)
        zip.archiveEntries = ["backup/notes.txt", "backup/.ssh/id_ed25519"]
        #expect(SensitiveDetector.check(zip)?.kind == .credentialFile)
        zip.archiveEntries = ["site/index.html", "site/.env.example"]
        #expect(SensitiveDetector.check(zip) == nil)
    }

    /// MED-2: a bundle with an extension we don't know is one thing, not a folder to open.
    @Test func bundlesAreNotFolders() {
        #expect(FileKind(fileExtension: "rtfd", isDirectory: true, isPackage: true) == .other)
        #expect(FileKind(fileExtension: "", isDirectory: true) == .folder)
    }

    /// MED-9: a code glued to other letters, in any alphabet, isn't a code.
    @Test func wordBoundariesAreUnicode() {
        #expect(CourseCatalog.codes(in: "ЭECO372 notes").isEmpty)
        #expect(CourseCatalog.codes(in: "ECO 372 notes") == ["ECO372"])
        #expect(!containsWords("Иnsu", "nsu"))
    }

    /// MED-10, MED-32: a file that can't be read is kept aside, not overwritten.
    @Test func unreadableSettingsAreKeptAside() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "settings.json")
        try Data("{ not json".utf8).write(to: file)
        #expect(AppSettings.load(from: file) == AppSettings())
        let aside = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(aside.contains { $0.hasPrefix("settings.json.unreadable-") })
        // A file missing settings added later still loads, with defaults for those.
        try Data(#"{"watchedFolder": "/tmp/in", "homeRoot": "/tmp/home"}"#.utf8).write(to: file)
        let partial = AppSettings.load(from: file)
        #expect(partial.homeRoot == "/tmp/home" && partial.watching && partial.reviewReminderHours == 8)
    }

    struct Answer: FileClassifier {
        let name = "answer"
        var destination: String
        var confidence: Double
        func suggest(_ request: ClassificationRequest) async throws -> ClassifierSuggestion {
            ClassifierSuggestion(destination: destination, confidence: confidence, reason: "because")
        }
        func suggestName(for facts: FileFacts) async throws -> NameSuggestion { throw ClassifierError.unavailable("") }
    }

    /// MED-13: a guess into a Secure subfolder needs the same high confidence as Secure.
    /// MED-14: a confidence that isn't a number doesn't crash; it counts as none.
    @Test(arguments: [("Documents/Secure/IDs", 0.8), ("Documents/Essays", Double.nan), ("Documents/Essays", .infinity)])
    func unsureOrNonsenseAnswersGoToReview(_ destination: String, _ confidence: Double) async throws {
        for folder in ["Documents/Secure/IDs", "Documents/Essays"] {
            try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        var planner = Planner(homeRoot: root)
        planner.classifier = Answer(destination: destination, confidence: confidence)
        let decision = await planner.decide(facts(name: "scan.txt", text: "something"))
        #expect(decision.destination == planner.config.reviewFolder, "\(destination) \(confidence)")
    }

    /// MED-16: tags that are there but unreadable stop the move (undo couldn't restore them).
    @Test func unreadableTagsStopTheMove() throws {
        try FileManager.default.createDirectory(at: root.appending(path: "Home/Documents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "a.txt")
        try Data("x".utf8).write(to: source)
        try ExtendedAttributes.set(Data("not a plist".utf8), name: FinderTags.attribute, at: source)
        #expect(throws: (any Error).self) { try FinderTags.readRawChecked(source) }
        let values = try source.resourceValues(forKeys: [.contentModificationDateKey])
        let action = ProposedAction(source: source, originalName: "a.txt", sourceSize: 1, sourceModified: values.contentModificationDate,
                                    destinationFolder: "Documents", finalName: "a.txt", tags: [], confidence: 1, reason: "",
                                    decidedBy: .rule("test"), alerts: [], createsFolders: [])
        let result = Applier(homeRoot: root.appending(path: "Home"), journal: MoveJournal(url: root.appending(path: "m.jsonl"))).apply([action])
        guard case .failed(let why) = result.first?.outcome else { Issue.record("expected failure"); return }
        #expect(why.contains("Finder tags"))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    /// LOW-22: APFS ignores case, so "library" is Library.
    @Test func protectedFoldersInAnyCase() {
        #expect(DestinationValidator.problem(with: "Documents/library/x", config: OrganizerConfig()) != nil)
    }

    /// LOW-25: empty files are all "identical"; that's not a duplicate.
    @Test func anEmptyFileIsNotADuplicateOfAnotherEmptyFile() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "Downloads"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "Home/Documents/Notes"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data().write(to: root.appending(path: "Home/Documents/Notes/old.txt"))
        try Data().write(to: root.appending(path: "Downloads/new.txt"))
        var planner = Planner(homeRoot: root.appending(path: "Home"))
        planner.classifier = Answer(destination: "Documents/Notes", confidence: 0.9)
        let action = try #require(try await planner.plan(folder: root.appending(path: "Downloads")).actions.first)
        #expect(!action.alerts.contains { $0.kind == .duplicate })
    }
}

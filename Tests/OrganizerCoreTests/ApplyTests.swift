import Foundation
import Testing
@testable import OrganizerCore
import TestDataKit

@Suite struct FinderTagTests {
    @Test func encodesNameNewlineColor() {
        #expect(FinderTags.encode(.nsu) == "NSU\n4")
        #expect(FinderTags.encode(.secure) == "Secure\n6")
        #expect(FinderTags.encode(Tag("Plain", .none)) == "Plain")
        #expect(FinderTags.decode("FSAE\n2") == .fsae)
        #expect(FinderTags.decode("Mine") == Tag("Mine", .none))
    }

    @Test func mergeKeepsExistingTags() {
        // iCloud rewrote NSU's color to 1: keep it as is, don't add a second NSU.
        #expect(FinderTags.merge(existing: ["Work\n5", "NSU\n1"], adding: [.nsu, .fsae]) == ["Work\n5", "NSU\n1", "FSAE\n2"])
    }

    @Test func writesABinaryPlist() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "tags-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        try FinderTags.writeRaw(["NSU\n4"], to: file)
        let raw = try #require(ExtendedAttributes.data(FinderTags.attribute, at: file))
        #expect(raw.starts(with: Data("bplist00".utf8)))
        #expect(FinderTags.read(file) == [.nsu])

        try FinderTags.writeRaw([], to: file)
        #expect(ExtendedAttributes.data(FinderTags.attribute, at: file) == nil)
    }
}

/// Apply and undo on a generated sandbox in a temporary folder.
@Suite(.serialized) struct ApplyUndoTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "file-organizer-apply-\(UUID().uuidString)")
    var downloads: URL { root.appending(path: "Downloads") }
    var home: URL { root.appending(path: "Home") }
    var journal: MoveJournal { MoveJournal(url: root.appending(path: "moves.jsonl")) }

    func setUp() async throws -> Plan {
        _ = try TestDataBuilder.build(at: root)
        return try await Planner(homeRoot: home).plan(folder: downloads)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    @Test func applyThenUndoRestoresEverythingExactly() async throws {
        let plan = try await setUp()
        defer { cleanUp() }
        let before = try snapshot()

        let results = Applier(homeRoot: home, journal: journal).apply(plan.actions)
        #expect(results.allSatisfy { $0.outcome == .moved }, "\(results.filter { $0.outcome != .moved }.map(\.outcome))")
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path) == ["bigfile.zip.crdownload"])

        let phrase = home.appending(path: "Documents/Secure/\(FileNames.day(Date())) Recovery Phrase.jpg")
        #expect(FinderTags.read(phrase) == [.secure])
        let origin = try #require(MoveOrigin.read(phrase)?.originalPath)
        #expect(URL(filePath: origin).lastPathComponent == "IMG_5012.jpg")
        #expect(URL(filePath: origin).deletingLastPathComponent().resolvingSymlinksInPath() == downloads.resolvingSymlinksInPath())
        #expect(FileManager.default.fileExists(atPath: home.appending(path: "Movies/Films/Avengers Infinity War.mpeg").path))

        let undoer = Undoer(journal: journal)
        let undone = undoer.undo(try undoer.undoable())
        #expect(undone.allSatisfy { $0.restoredTo != nil && $0.notes.isEmpty }, "\(undone.compactMap(\.error))")
        // Names, contents, every extended attribute and every folder: as before.
        #expect(try snapshot() == before)
        #expect(try journal.records().allSatisfy { $0.state == .undone })
    }

    @Test func neverOverwritesAFileThatAppearsAfterPlanning() async throws {
        let plan = try await setUp()
        defer { cleanUp() }
        let action = try #require(plan.actions.first { $0.originalName == "GradeHistory.pdf" })
        let target = home.appending(path: action.destinationPath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("someone else's file".utf8).write(to: target)

        let result = try #require(Applier(homeRoot: home, journal: journal).apply([action]).first)
        guard case .failed(let why) = result.outcome else { Issue.record("expected failure, got \(result.outcome)"); return }
        #expect(why.contains("already exists"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "someone else's file")
        #expect(FileManager.default.fileExists(atPath: action.source.path))
        #expect(try journal.records().first?.state == .failed)
    }

    @Test func skipsFilesThatChangedAfterPlanning() async throws {
        let plan = try await setUp()
        defer { cleanUp() }
        let action = try #require(plan.actions.first { $0.originalName == "notes.txt" })
        let handle = try FileHandle(forWritingTo: action.source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("bread\n".utf8))
        try handle.close()

        let result = try #require(Applier(homeRoot: home, journal: journal).apply([action]).first)
        guard case .skipped = result.outcome else { Issue.record("expected skip, got \(result.outcome)"); return }
        #expect(FileManager.default.fileExists(atPath: action.source.path))
        #expect(try journal.entries().isEmpty)
    }

    @Test func refusesSymlinksOutOfTheHomeFolder() async throws {
        let plan = try await setUp()
        defer { cleanUp() }
        // Movies/Films now points somewhere outside the home folder.
        let outside = root.appending(path: "Elsewhere")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let films = home.appending(path: "Movies/Films")
        try FileManager.default.moveItem(at: films, to: root.appending(path: "Films (moved aside)"))
        try FileManager.default.createSymbolicLink(at: films, withDestinationURL: outside)

        let action = try #require(plan.actions.first { $0.originalName == "Avengers_Infinity_War_4K_BluRay.mpeg" })
        let result = try #require(Applier(homeRoot: home, journal: journal).apply([action]).first)
        guard case .failed(let why) = result.outcome else { Issue.record("expected failure, got \(result.outcome)"); return }
        #expect(why.contains("outside the home folder"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: action.source.path))
    }

    @Test func undoNeverOverwritesANewFileWithTheOriginalName() async throws {
        let plan = try await setUp()
        defer { cleanUp() }
        let action = try #require(plan.actions.first { $0.originalName == "notes.txt" })
        _ = Applier(homeRoot: home, journal: journal).apply([action])
        // A new download with the same name arrives.
        try Data("new notes".utf8).write(to: action.source)

        let undoer = Undoer(journal: journal)
        let result = try #require(undoer.undo(try undoer.undoable()).first)
        let restored = try #require(result.restoredTo)
        #expect(restored.lastPathComponent == "notes (\(FileNames.day(Date()))).txt")
        #expect(result.notes.contains { $0.contains("taken") })
        #expect(try String(contentsOf: action.source, encoding: .utf8) == "new notes")
        #expect(try String(contentsOf: restored, encoding: .utf8) == "eggs\nmilk\nrice\nlentils\n")
    }

    @Test func undoKeepsFoldersThatAreNoLongerEmpty() async throws {
        let plan = try await setUp()
        defer { cleanUp() }
        let action = try #require(plan.actions.first { $0.originalName.hasPrefix("Avengers") })
        _ = Applier(homeRoot: home, journal: journal).apply([action])
        let films = home.appending(path: "Movies/Films")
        try Data("mine".utf8).write(to: films.appending(path: "my film.mp4"))

        let undoer = Undoer(journal: journal)
        _ = undoer.undo(try undoer.undoable())
        #expect(FileManager.default.fileExists(atPath: films.appending(path: "my film.mp4").path))
        #expect(FileManager.default.fileExists(atPath: action.source.path))
    }

    @Test func recoversAMoveInterruptedByACrash() async throws {
        let plan = try await setUp()
        defer { cleanUp() }
        let action = try #require(plan.actions.first { $0.originalName == "notes.txt" })
        let destination = home.appending(path: action.destinationPath)
        // Simulate a crash: the intent was logged (with the hash, as the applier logs it) and the
        // file moved, but "done" never got written.
        try journal.append(JournalEntry(event: .movePending, time: Date(), moveID: UUID(), batchID: UUID(),
                                        from: action.source.path, to: destination.path,
                                        sha256: try FileHash.sha256(action.source)))
        try FileManager.default.moveItem(at: action.source, to: destination)
        #expect(try journal.records().first?.state == .pending)

        #expect(try journal.recover() == 1)
        #expect(try journal.records().first?.state == .moved)
        let undoer = Undoer(journal: journal)
        #expect(undoer.undo(try undoer.undoable()).first?.restoredTo == action.source)
    }

    @Test func aDamagedLogLineDoesNotHideTheRest() async throws {
        let plan = try await setUp()
        defer { cleanUp() }
        let action = try #require(plan.actions.first { $0.originalName == "notes.txt" })
        _ = Applier(homeRoot: home, journal: journal).apply([action])
        // A power loss mid-write: half a line, no newline at the end.
        let handle = try FileHandle(forWritingTo: journal.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"event":"movePend"#.utf8))
        try handle.close()

        #expect(try journal.damagedLineCount() == 1)
        #expect(try journal.records().map(\.state) == [.moved])
        // The next entry starts on a fresh line instead of being glued onto the broken one.
        let undoer = Undoer(journal: journal)
        #expect(undoer.undo(try undoer.undoable()).first?.restoredTo == action.source)
        #expect(try journal.records().map(\.state) == [.undone])
        #expect(try journal.damagedLineCount() == 1)
    }

    /// Every file and folder under the sandbox with its content hash and all extended attributes.
    private func snapshot() throws -> [String: String] {
        var result: [String: String] = [:]
        for top in [downloads, home] {
            for case let url as URL in FileManager.default.enumerator(at: top, includingPropertiesForKeys: nil)! {
                let relative = String(url.path.dropFirst(root.path.count))
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                if isDirectory.boolValue {
                    result[relative] = "folder"
                    continue
                }
                let xattrs = ExtendedAttributes.names(at: url).sorted().map { name in
                    "\(name)=\(ExtendedAttributes.data(name, at: url)?.base64EncodedString() ?? "")"
                }
                result[relative] = try FileHash.sha256(url) + " " + xattrs.joined(separator: ",")
            }
        }
        return result
    }
}

/// MED-34, MED-35, MED-40: undo's refusals and notes, the new-folder cap, big files.
@Suite(.serialized) struct UndoEdgeTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "file-organizer-undo-\(UUID().uuidString)")
    var journal: MoveJournal { MoveJournal(url: root.appending(path: "moves.jsonl")) }
    var home: URL { root.appending(path: "Home") }

    /// Moves one new file into Documents/Notes and returns where it went.
    func moveOne(maxHashedSize: Int64 = 1 << 30) throws -> URL {
        let downloads = root.appending(path: "Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: "Documents"), withIntermediateDirectories: true)
        let source = downloads.appending(path: "a.txt")
        try Data("original".utf8).write(to: source)
        let values = try source.resourceValues(forKeys: [.contentModificationDateKey])
        let action = ProposedAction(source: source, originalName: "a.txt", sourceSize: 8, sourceModified: values.contentModificationDate,
                                    destinationFolder: "Documents/Notes", finalName: "a.txt", tags: [], confidence: 1,
                                    reason: "", decidedBy: .rule("test"), alerts: [], createsFolders: ["Documents/Notes"])
        var applier = Applier(homeRoot: home, journal: journal)
        applier.maxHashedSize = maxHashedSize
        #expect(applier.apply([action]).first?.outcome == .moved)
        return home.appending(path: "Documents/Notes/a.txt")
    }

    @Test func aFileThatsGoneCantBeUndone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: try moveOne())
        let undoer = Undoer(journal: journal)
        #expect(undoer.undo(try undoer.undoable()).first?.error?.contains("no longer at") == true)
    }

    @Test func anEditedFileGoesBackWithANote() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let moved = try moveOne()
        let handle = try FileHandle(forWritingTo: moved)   // edit in place: our origin note stays
        try handle.seekToEnd(); try handle.write(contentsOf: Data(" and edited".utf8)); try handle.close()
        let undoer = Undoer(journal: journal)
        let result = try #require(undoer.undo(try undoer.undoable()).first)
        #expect(result.restoredTo != nil)
        #expect(result.notes.contains { $0.contains("edited") })
    }

    @Test func aDifferentFileInItsPlaceIsNotPutBack() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let moved = try moveOne()
        try FileManager.default.removeItem(at: moved)
        try Data("someone else's file".utf8).write(to: moved)
        let undoer = Undoer(journal: journal)
        let result = try #require(undoer.undo(try undoer.undoable()).first)
        #expect(result.restoredTo == nil)
        #expect(result.error?.contains("isn't the file that was moved") == true)
        #expect(FileManager.default.fileExists(atPath: moved.path))
    }

    @Test func bigFilesAreLoggedWithoutAHashAndStillUndone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try moveOne(maxHashedSize: 1)
        let record = try #require(try journal.records().first)
        #expect(record.sha256 == nil)
        let undoer = Undoer(journal: journal)
        #expect(undoer.undo([record]).first?.restoredTo != nil)    // recognised by our origin note
    }

    @Test func tooManyNewFoldersGoesToReview() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appending(path: "Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("episode".utf8).write(to: downloads.appending(path: "Show.S01E01.mkv"))
        var planner = Planner(homeRoot: home)
        planner.config.maxNewFolders = 1                    // Movies, TV Shows, Show: 3 needed
        let action = try #require(try await planner.plan(folder: downloads).actions.first)
        #expect(action.destinationFolder == planner.config.reviewFolder)
        #expect(action.reason.hasPrefix("Too many new folders"))
    }
}

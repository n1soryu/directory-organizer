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

        let outline = home.appending(path: "Documents/University/ECO201/ECO201 Course Outline.pdf")
        #expect(FinderTags.read(outline) == [.nsu])
        let origin = try #require(MoveOrigin.read(outline)?.originalPath)
        #expect(URL(filePath: origin).lastPathComponent == "document (3).pdf")
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
        // Documents/FSAE now points somewhere outside the home folder.
        let outside = root.appending(path: "Elsewhere")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let fsae = home.appending(path: "Documents/FSAE")
        try FileManager.default.removeItem(at: fsae)
        try FileManager.default.createSymbolicLink(at: fsae, withDestinationURL: outside)

        let action = try #require(plan.actions.first { $0.originalName == "minutes_oct.docx" })
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
        // Simulate a crash: the intent was logged and the file moved, but "done" never got written.
        try journal.append(JournalEntry(event: .movePending, time: Date(), moveID: UUID(), batchID: UUID(),
                                        from: action.source.path, to: destination.path))
        try FileManager.default.moveItem(at: action.source, to: destination)
        #expect(try journal.records().first?.state == .pending)

        #expect(try journal.recover() == 1)
        #expect(try journal.records().first?.state == .moved)
        let undoer = Undoer(journal: journal)
        #expect(undoer.undo(try undoer.undoable()).first?.restoredTo == action.source)
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

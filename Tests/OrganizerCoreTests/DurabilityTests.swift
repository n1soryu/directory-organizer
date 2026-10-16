import Foundation
import Testing
@testable import OrganizerCore

/// Moves between disks, and recovering moves and undos a crash interrupted.
@Suite(.serialized) struct DurabilityTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "file-organizer-durable-\(UUID().uuidString)")
    var journal: MoveJournal { MoveJournal(url: root.appending(path: "moves.jsonl")) }

    func write(_ text: String, _ path: String) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: Copying between disks (the code path runs the same on one disk)

    @Test func copiesAFolderWholeThenRemovesTheOriginal() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("a", "src/a.txt")
        _ = try write("SECRET=1", "src/.env")
        _ = try write("b", "src/deep/b.txt")
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "src/link").path, withDestinationPath: "a.txt")
        let before = try SafeMove.manifest(root.appending(path: "src"), FileHash.sha256)

        try SafeMove.copyAcrossDisks(root.appending(path: "src"), to: root.appending(path: "dst"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "src").path))
        #expect(try SafeMove.manifest(root.appending(path: "dst"), FileHash.sha256) == before)
        #expect(before["link"] == "link a.txt" && before[".env"] != nil)
    }

    @Test func aCopyThatDoesntMatchIsRemovedAndTheOriginalKept() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try write("precious", "src/file.txt")
        let destination = root.appending(path: "dst.txt")
        // The copy "reads back" differently.
        let lying: (URL) throws -> String = { $0.path.hasSuffix("dst.txt") ? "different" : try FileHash.sha256($0) }

        #expect(throws: MoveError.copyMismatch(source.path)) {
            try SafeMove.copyAcrossDisks(source, to: destination, hash: lying)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func aHashErrorAlsoRemovesTheCopy() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try write("precious", "src/file.txt")
        struct Unreadable: Error {}
        #expect(throws: Unreadable.self) {
            try SafeMove.copyAcrossDisks(source, to: root.appending(path: "dst.txt"), hash: { _ in throw Unreadable() })
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "dst.txt").path))
    }

    @Test func neverCopiesOverAnExistingFile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try write("new", "src/file.txt")
        let existing = try write("mine", "dst.txt")
        #expect(throws: MoveError.destinationExists(existing.path)) { try SafeMove.copyAcrossDisks(source, to: existing) }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "mine")
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    // MARK: Recovery

    func pending(_ from: URL, _ to: URL, tags: [String] = [], created: [String] = []) -> JournalEntry {
        JournalEntry(event: .movePending, time: Date(), moveID: UUID(), batchID: UUID(), from: from.path, to: to.path,
                     tagsBefore: tags, createdFolders: created)
    }

    @Test func aCompleteCopyLeftByACrashFinishesTheMove() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try write("data", "Downloads/f.txt")
        let copy = try write("data", "Home/f.txt")      // copied, original not yet removed
        try journal.append(pending(source, copy))

        #expect(try journal.recover() == 1)
        #expect(try journal.records().first?.state == .moved)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func anIncompleteCopyIsReportedAndNothingIsDeleted() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try write("all of the data", "Downloads/f.txt")
        let copy = try write("all of", "Home/f.txt")    // cut short
        try journal.append(pending(source, copy))

        #expect(try journal.recover() == 1)
        #expect(try journal.records().first?.state == .failed)
        #expect(try journal.entries().last?.message?.contains("incomplete copy") == true)
        #expect(FileManager.default.fileExists(atPath: source.path) && FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func anInterruptedUndoIsFinishedNotJustLogged() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "Downloads/f.txt")
        let created = root.appending(path: "Home/New")
        let moved = created.appending(path: "f.txt")
        var entry = pending(original, moved, tags: ["Mine"], created: [created.path])
        try journal.append(entry)
        entry.event = .moveDone
        try journal.append(entry)
        // The undo moved the file back, then the app died: app tags and origin note still on it.
        _ = try write("x", "Downloads/f.txt")
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        try FinderTags.writeRaw(["Mine", "NSU\n4"], to: original)
        try MoveOrigin.write(.init(originalPath: original.path, movedAt: Date(), moveID: entry.moveID), to: original)
        try journal.append(JournalEntry(event: .undoPending, time: Date(), moveID: entry.moveID, batchID: entry.batchID,
                                        from: moved.path, to: original.path))

        #expect(try journal.recover() == 1)
        #expect(try journal.records().first?.state == .undone)
        #expect(FinderTags.readRaw(original) == ["Mine"])
        #expect(MoveOrigin.read(original) == nil)
        #expect(!FileManager.default.fileExists(atPath: created.path))
    }

    @Test func aMoveWhosePendingLineWasLostIsStillUndoable() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var entry = pending(root.appending(path: "Downloads/f.txt"), root.appending(path: "Home/f.txt"))
        entry.event = .moveDone          // only "done" survived
        try journal.append(entry)
        let records = try journal.records()
        #expect(records.count == 1 && records[0].state == .moved && records[0].movedPath.hasSuffix("Home/f.txt"))
    }
}

/// Secrets in hidden files inside downloaded folders, and folders too big to check.
@Suite(.serialized) struct HiddenSecretTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "file-organizer-hidden-\(UUID().uuidString)")

    func folder(_ files: [String: String]) async throws -> FileFacts {
        let top = root.appending(path: "project")
        for (path, text) in files {
            let url = top.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return await FactExtractor().facts(for: top)
    }

    @Test(arguments: [
        [".env": "DEBUG=1\nSTRIPE_SECRET_KEY=sk_live_abc123\n"],
        ["config/.aws/credentials": "[default]\naws_access_key_id = AKIA0000\naws_secret_access_key = abc/def\n"],
        [".git/config": "[core]\n", ".git-credentials": "https://me:ghp_token123@github.com\n"],
        ["deep/.netrc": "machine example.com login me password hunter2\n"],
    ])
    func aHiddenSecretSendsTheFolderToReview(_ files: [String: String]) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let facts = try await folder(files.merging(["index.js": "console.log(1)"]) { a, _ in a })
        #expect(facts.folder?.sensitive.isEmpty == false, "\(files.keys)")
        let decision = try #require(RulesEngine.standard.decide(facts, config: OrganizerConfig()))
        #expect(decision.destination == OrganizerConfig().reviewFolder)
        #expect(decision.alerts.contains { $0.kind == .sensitive })
    }

    @Test func harmlessHiddenFilesDontCountAsContentsOrSecrets() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let facts = try await folder([".DS_Store": "x", ".env.example": "API_KEY=your-key-here\n", "notes.txt": "hello"])
        #expect(facts.folder?.sensitive == [])
        #expect(facts.folder?.fileCount == 1)       // notes.txt; hidden ones aren't contents
    }

    @Test func aFolderTooBigToCheckFullyGoesToReview() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var files: [String: String] = [:]
        for index in 0..<(FactExtractor.maxFolderFilesChecked + 5) { files["f\(index).txt"] = "\(index)" }
        let facts = try await folder(files)
        #expect(facts.folder?.truncated == true)
        let decision = try #require(RulesEngine.standard.decide(facts, config: OrganizerConfig()))
        #expect(decision.destination == OrganizerConfig().reviewFolder)
        #expect(decision.reason.contains("too big to check"))
    }

    // HIGH-13, MED-36: detections that had no test.
    @Test func plainTextJSONPasswordExportIsCaught() {
        let export = facts(name: "bitwarden_export.json", text: #"{"encrypted": false, "items": [{"login": {"password": "x"}}]}"#)
        #expect(SensitiveDetector.check(export)?.kind == .unencryptedPasswordExport)
        let encrypted = facts(name: "bitwarden_export.json", text: #"{"encrypted": true, "data": "2.abc"}"#)
        #expect(SensitiveDetector.check(encrypted) == nil)
    }

    @Test func wireGuardConfigWithAPrivateKeyIsCaught() {
        let conf = facts(name: "wg0.conf", text: "[Interface]\nPrivateKey = abc=\nAddress = 10.0.0.2/32\n")
        #expect(SensitiveDetector.check(conf)?.kind == .credentialFile)
        #expect(SensitiveDetector.check(facts(name: "nginx.conf", text: "server { listen 80; }")) == nil)
    }
}

import Foundation
import Testing
@testable import OrganizerCore
import TestDataKit

/// A new file and the earlier files the model put with it move together, or not at all, and
/// are undone together.
@Suite(.serialized) struct GroupApplyTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "file-organizer-group-\(UUID().uuidString)")
    var home: URL { root.appending(path: "Home") }
    var journal: MoveJournal { MoveJournal(url: root.appending(path: "moves.jsonl")) }

    /// A new download and an earlier file already filed, both proposed for a new folder.
    func group() throws -> [ProposedAction] {
        let fm = FileManager.default
        let downloads = root.appending(path: "Downloads")
        let filed = home.appending(path: "Documents/Misc")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(at: filed, withIntermediateDirectories: true)
        let id = UUID()
        return try [(downloads.appending(path: "new manual.pdf"), false), (filed.appending(path: "old manual.pdf"), true)].map { url, earlier in
            try Data("manual \(url.lastPathComponent)".utf8).write(to: url)
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            var action = ProposedAction(source: url, originalName: url.lastPathComponent, sourceSize: Int64(values.fileSize ?? 0),
                                        sourceModified: values.contentModificationDate, destinationFolder: "Documents/Manuals",
                                        finalName: url.lastPathComponent, tags: [], confidence: 0.8, reason: "manuals",
                                        decidedBy: .classifier("fake"), alerts: [], createsFolders: ["Documents/Manuals"])
            action.groupID = id
            action.isEarlierFile = earlier
            return action
        }
    }

    @Test func aGroupMovesTogetherAndIsUndoneTogether() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let actions = try group()
        let results = Applier(homeRoot: home, journal: journal).apply(actions)
        #expect(results.map(\.outcome) == [.moved, .moved])
        let records = try journal.records().filter { $0.state == .moved }
        #expect(records.count == 2 && Set(records.map(\.batchID)).count == 1)

        let undone = Undoer(journal: journal).undo(records)
        #expect(undone.allSatisfy { $0.restoredTo != nil })
        #expect(FileManager.default.fileExists(atPath: actions[1].source.path))
    }

    @Test func aChangedEarlierFileStopsTheWholeGroup() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let actions = try group()
        try Data("edited since the plan".utf8).write(to: actions[1].source)
        let results = Applier(homeRoot: home, journal: journal).apply(actions)
        #expect(results.allSatisfy { if case .skipped = $0.outcome { true } else { false } })
        #expect(results[0].outcome == .skipped("moves together with old manual.pdf, which changed after the plan was made"))
        #expect(FileManager.default.fileExists(atPath: actions[0].source.path))
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "Documents/Manuals").path))
    }
}

@Suite(.serialized) struct Round2FixtureTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "file-organizer-round2-\(UUID().uuidString)")

    @Test func addsLaterDownloadsOnlyToASandboxAndNeverReplaces() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: CocoaError.self) { _ = try TestDataBuilder.addRound2(at: root) }
        _ = try TestDataBuilder.build(at: root)
        let added = try TestDataBuilder.addRound2(at: root)
        for name in added {
            #expect(FileManager.default.fileExists(atPath: root.appending(path: "Downloads/\(name)").path))
        }
        #expect(throws: CocoaError.self) { _ = try TestDataBuilder.addRound2(at: root) }
    }
}

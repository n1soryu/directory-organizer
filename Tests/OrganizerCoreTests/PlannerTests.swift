import Foundation
import Testing
@testable import OrganizerCore
import TestDataKit

/// End to end on the generated sandbox: real PDFs, a scan that needs OCR, Office files,
/// images, xattrs. Each file must land where expected.json says.
@Suite(.serialized) struct PlannerTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "file-organizer-tests-\(UUID().uuidString)")

    @Test func sandboxPlanMatchesExpectations() async throws {
        let expected = try TestDataBuilder.build(at: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let before = try snapshot(root)
        let plan = try await Planner(homeRoot: root.appending(path: "Home")).plan(folder: root.appending(path: "Downloads"))

        #expect(plan.skipped.map(\.name) == ["bigfile.zip.crdownload"])
        #expect(plan.actions.count == expected.count)
        for outcome in expected {
            guard let action = plan.actions.first(where: { $0.originalName == outcome.file }) else {
                Issue.record("\(outcome.file) missing from the plan")
                continue
            }
            #expect(action.destinationFolder == outcome.folder, "\(outcome.file): \(action.reason)")
            #expect(action.finalName == outcome.name, "\(outcome.file)")
            #expect(Set(action.alerts.map(\.kind.rawValue)) == Set(outcome.alerts), "\(outcome.file)")
        }

        // Planning is read-only: not a single file added, moved or changed.
        #expect(try snapshot(root) == before)
    }

    @Test func refusesToReplaceAFolderThatIsntTestData() throws {
        let folder = root.appending(path: "precious")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: folder.appending(path: "thesis.docx"))
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: (any Error).self) { try TestDataBuilder.build(at: folder) }
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "thesis.docx").path))
    }

    @Test func invalidModelSuggestionsGoToReview() async throws {
        struct Rogue: FileClassifier {
            let name = "rogue"
            let destination: String
            let confidence: Double
            func suggest(for facts: FileFacts, config: OrganizerConfig) async throws -> ClassifierSuggestion? {
                ClassifierSuggestion(destination: destination, tags: ["NSU", "Invented"], confidence: confidence, reason: "trust me")
            }
        }
        var planner = Planner(homeRoot: root)
        let item = facts(name: "notes.txt", text: "eggs, milk")

        planner.classifier = Rogue(destination: "Library/LaunchAgents", confidence: 0.99)
        var decision = await planner.decide(item)
        #expect(decision.destination == planner.config.reviewFolder)
        #expect(decision.alerts.contains { $0.kind == .rejected })

        planner.classifier = Rogue(destination: "Documents/Essays", confidence: 0.4)
        decision = await planner.decide(item)
        #expect(decision.destination == planner.config.reviewFolder)

        planner.classifier = Rogue(destination: "Documents/Essays", confidence: 0.9)
        decision = await planner.decide(item)
        #expect(decision.destination == "Documents/Essays")
        #expect(decision.tags == [.nsu])  // "Invented" isn't on the allowlist
    }

    /// Every file path with its size and modification date.
    private func snapshot(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)! {
            let values = try url.resourceValues(forKeys: Set(keys))
            result[url.path] = "\(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return result
    }
}

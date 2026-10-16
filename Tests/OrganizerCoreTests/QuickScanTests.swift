import Foundation
import Testing
@testable import OrganizerCore
import TestDataKit

/// Quick scans (automatic, rules only) and full runs (Organize Now) on the generated sandbox.
@Suite(.serialized) struct QuickScanTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "file-organizer-quick-\(UUID().uuidString)")
    var downloads: URL { root.appending(path: "Downloads") }
    var home: URL { root.appending(path: "Home") }

    /// Fails the test if the model is asked anything.
    struct NoModelAllowed: FileClassifier {
        let name = "must-not-be-called"
        func suggest(_ request: ClassificationRequest) async throws -> ClassifierSuggestion {
            Issue.record("quick scan asked the model about \(request.facts.name)")
            throw ClassifierError.unavailable("test")
        }
        func suggestName(for facts: FileFacts) async throws -> NameSuggestion {
            Issue.record("quick scan asked the model to name \(facts.name)")
            throw ClassifierError.unavailable("test")
        }
    }

    @Test func onlyFilesDownloadedAfterTheSwitchAreConsidered() async throws {
        _ = try TestDataBuilder.build(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        var planner = Planner(homeRoot: home, mode: .quick)
        planner.onlyAddedAfter = Date().addingTimeInterval(1)
        try await Task.sleep(for: .seconds(1.5))
        try Data("new download".utf8).write(to: downloads.appending(path: "Fresh ECO201 notes.txt"))

        let plan = try await planner.plan(folder: downloads)
        let seen = plan.actions.map(\.originalName) + plan.waiting.map(\.name) + plan.skipped.map(\.name)
        #expect(seen == ["Fresh ECO201 notes.txt"])
    }

    @Test func quickScanUsesRulesOnlyAndLeavesTheRestWaiting() async throws {
        _ = try TestDataBuilder.build(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        var planner = Planner(homeRoot: home, mode: .quick)
        planner.classifier = NoModelAllowed()
        let plan = try await planner.plan(folder: downloads)

        let waiting = Set(plan.waiting.map(\.name))
        // Images and the scan need text recognition; leftovers need the model.
        for name in ["IMG_5012.jpg", "IMG_4821.png", "Screenshot 2026-10-12 at 21.14.03.png", "scan0001.pdf",
                     "AX55_UserGuide.pdf", "bill_sep.pdf", "notes.txt", "Climate essay draft.docx", "photos.zip"] {
            #expect(waiting.contains(name), "\(name) should wait for Organize Now")
        }
        // No OCR happened, and nothing waiting is also in the plan.
        #expect(plan.actions.allSatisfy { $0.facts?.textSource != .imageOCR && $0.facts?.textSource != .pdfOCR })
        #expect(waiting.isDisjoint(with: plan.actions.map(\.originalName)))
        // Rules still decide what they can right away.
        let byName = Dictionary(uniqueKeysWithValues: plan.actions.map { ($0.originalName, $0) })
        #expect(byName["GradeHistory.pdf"]?.destinationFolder == "Documents/University/Records/Grades")
        #expect(byName["Avengers_Infinity_War_4K_BluRay.mpeg"]?.finalName == "Avengers Infinity War.mpeg")
        #expect(byName["Chrome Passwords.csv"]?.alerts.first?.kind == .sensitive)
        #expect(byName["download.pdf"]?.reason.contains("Organize Now can suggest a better name") == true)
    }

    @Test func aPhotographedRecoveryPhraseIsNeverFiledAsAPicture() async throws {
        _ = try TestDataBuilder.build(at: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let quick = try await Planner(homeRoot: home, mode: .quick).plan(folder: downloads)
        #expect(!quick.actions.contains { $0.originalName == "IMG_5012.jpg" })
        #expect(quick.waiting.contains { $0.name == "IMG_5012.jpg" })

        let full = try await Planner(homeRoot: home, mode: .full).plan(folder: downloads)
        #expect(full.actions.first { $0.originalName == "IMG_5012.jpg" }?.destinationFolder == "Documents/Secure")
    }

    @Test func progressCountsUpToTheTotal() async throws {
        _ = try TestDataBuilder.build(at: root)
        defer { try? FileManager.default.removeItem(at: root) }

        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [Planner.Progress] = []
            func add(_ p: Planner.Progress) { lock.withLock { items.append(p) } }
            var all: [Planner.Progress] { lock.withLock { items } }
        }
        let log = Log()
        _ = try await Planner(homeRoot: home, mode: .quick).plan(folder: downloads) { log.add($0) }
        let steps = log.all
        #expect(steps.first?.total ?? 0 > 0)
        // The whole run's fraction never goes backwards, and ends full.
        #expect(steps.map(\.fraction) == steps.map(\.fraction).sorted())
        #expect(steps.last?.fraction == 1)
        #expect(steps.contains { $0.step == .reading } && steps.contains { $0.step == .deciding })
    }

    @Test func cancellingStopsWithoutChangingAnything() async throws {
        _ = try TestDataBuilder.build(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()

        let planner = Planner(homeRoot: home, mode: .full)
        let folder = downloads
        let task = Task { try await planner.plan(folder: folder) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() == before)
    }
}

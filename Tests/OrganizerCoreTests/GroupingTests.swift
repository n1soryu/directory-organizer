import Foundation
import Testing
@testable import OrganizerCore

/// Similar files are grouped by code from the model's labels and placed together; a new folder
/// needs 2+ similar files.
@Suite(.serialized) struct GroupingTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "file-organizer-groups-\(UUID().uuidString)")
    var downloads: URL { root.appending(path: "Downloads") }
    var home: URL { root.appending(path: "Home") }

    func label(_ kind: String, _ category: String) -> FileDescription { FileDescription(kind: kind, category: category) }

    @Test func groupsBySharedMainWord() {
        let labels = [label("electricity bill", "Bills"), label("router manual", "Manuals"), label("water bill", "Utility Bills"),
                      label("fryer manual", "Guides"), label("pancake recipe", "Recipes"), label("fryer guide", "Guides")]
        // Kinds or categories sharing a main word; "fryer guide" joins the manuals through "Guides".
        #expect(Grouper.groups(labels) == [[1, 3, 5], [0, 2], [4]])
    }

    @Test func cardKindsGroupByTheirMainWord() {
        // MLXClassifier passes the card's kind as both labels.
        let labels = [label("gas bill", "gas bill"), label("lab report", "lab report"), label("electricity bill", "electricity bill")]
        #expect(Grouper.groups(labels) == [[0, 2], [1]])
    }

    @Test func vagueCategoriesDontGroup() {
        #expect(Grouper.mainWord("Utility Bills") == "bill")
        #expect(Grouper.mainWord("Batteries") == "battery")
        #expect(Grouper.mainWord("Documents") == nil)
        #expect(Grouper.mainWord("Misc") == nil)
        let labels = [label("note", "Files"), label("scan", "Other Files")]
        #expect(Grouper.groups(labels) == [[0], [1]])
    }

    /// Labels by file name; places the Bills group in a new folder, says the Gadgets group
    /// isn't alike, and wants a new folder for every file asked about alone.
    final class FakeModel: FileClassifier, @unchecked Sendable {
        let name = "fake"
        private let lock = NSLock()
        private var _groups: [String] = []
        var groupsAsked: [String] { lock.withLock { _groups } }

        func describe(_ facts: FileFacts) async throws -> FileDescription {
            switch facts.baseName {
            case "bill_a": FileDescription(kind: "electricity bill", category: "Bills")
            case "bill_b": FileDescription(kind: "water bill", category: "Utility Bills")
            case "charger", "speaker": FileDescription(kind: facts.baseName, category: "Gadgets")
            default: FileDescription(kind: "pancake recipe", category: "Recipes")
            }
        }
        func placeGroup(_ request: GroupRequest) async throws -> GroupSuggestion {
            lock.withLock { _groups.append(request.category) }
            let together = request.category.hasSuffix("Bills")
            return GroupSuggestion(belongTogether: together, suggestion: ClassifierSuggestion(
                destination: "Documents/Bills", isNewFolder: true, confidence: 0.9, reason: "utility bills"))
        }
        func suggest(_ request: ClassificationRequest) async throws -> ClassifierSuggestion {
            let folder = request.facts.baseName == "recipe" ? "Recipes" : "Gadgets"
            return ClassifierSuggestion(destination: "Documents/\(folder)", isNewFolder: true, confidence: 0.9, reason: "alone")
        }
        func suggestName(for facts: FileFacts) async throws -> NameSuggestion { throw ClassifierError.unavailable("") }
    }

    @Test func similarFilesArePlacedTogetherAndLoneOnesGetNoNewFolder() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: "Documents"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for name in ["bill_a", "bill_b", "recipe", "charger", "speaker"] {
            try Data("\(name) contents".utf8).write(to: downloads.appending(path: "\(name).txt"))
        }
        let model = FakeModel()
        var planner = Planner(homeRoot: home)
        planner.classifier = model
        let plan = try await planner.plan(folder: downloads)
        let byName = Dictionary(uniqueKeysWithValues: plan.actions.map { ($0.originalName, $0) })

        #expect(Set(model.groupsAsked) == ["Bills", "Gadgets"])
        // The bills: one decision for both, in a new folder they share.
        for bill in ["bill_a.txt", "bill_b.txt"] {
            #expect(byName[bill]?.destinationFolder == "Documents/Bills")
            #expect(byName[bill]?.reason.hasPrefix("One of 2 similar files") == true)
        }
        // Not alike after all: placed one by one. Both chose a new Gadgets folder, but by
        // chance, not as a group: no folder is made, they wait in review.
        for name in ["charger.txt", "speaker.txt"] {
            #expect(byName[name]?.destinationFolder == planner.config.reviewFolder)
            #expect(byName[name]?.reason.hasPrefix("No group of similar files") == true)
        }
        // Alone: the new folder it asked for would hold one file, so it waits in review.
        let recipe = try #require(byName["recipe.txt"])
        #expect(recipe.destinationFolder == planner.config.reviewFolder)
        #expect(recipe.reason.contains("needs 2+ similar files"))
        #expect(!recipe.createsFolders.contains { $0.hasSuffix("Recipes") })
    }

    @Test func anExistingFolderIsFineForOneFile() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: "Documents/Recipes"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("pancakes".utf8).write(to: downloads.appending(path: "recipe.txt"))
        var planner = Planner(homeRoot: home)
        planner.classifier = FakeModel()
        let plan = try await planner.plan(folder: downloads)
        #expect(plan.actions.first?.destinationFolder == "Documents/Recipes")
    }
}

/// A system service that never answers mustn't stall a run.
@Suite struct TimeoutTests {
    struct Boom: Error {}

    @Test func givesUpOnACallThatNeverAnswers() async throws {
        let start = Date()
        // Ignores cancellation, like a stuck system call (and ends by itself after 3 s).
        let result: Int? = try await withTimeout(seconds: 0.2) {
            for _ in 0..<300 { usleep(10_000) }
            return 1
        }
        #expect(result == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func passesAnswersAndErrorsThrough() async throws {
        #expect(try await withTimeout(seconds: 5) { 42 } == 42)
        await #expect(throws: Boom.self) { _ = try await withTimeout(seconds: 5) { () async throws -> Int in throw Boom() } }
    }
}

@Suite struct TimeoutCancelTests {
    @Test func cancellingStopsTheWaitAtOnce() async throws {
        let start = Date()
        let task = Task {
            try await withTimeout(seconds: 60) { () async throws -> Int in
                for _ in 0..<300 { usleep(10_000) }   // stuck, ignores cancellation (ends by itself in 3 s)
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(start) < 1)
    }
}

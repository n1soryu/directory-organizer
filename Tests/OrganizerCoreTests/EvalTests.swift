import Foundation
import Testing
@testable import OrganizerCore
import TestDataKit

/// `organize eval`'s test set and scoring (Milestone F), without the models.
struct EvalTests {
    /// Names that only exist in the benchmark's corpus, C's image set and the sandbox. Prompts
    /// must never contain them: a prompt tuned on the test set would make its scores meaningless.
    static let testSetNames = [
        "Northwind", "Contoso", "Kestrel", "Brightline", "Ember Home", "Harbor Grill", "Blue Fern", "Lakeside",
        "PeakFit", "SkyBridge", "Orbit Air", "Mira Holdings", "Tailspin", "Riverton", "Fabrikam", "Alex Rahman",
        "Nadia Karim", "Greenleaf", "Blue Door", "Skyway", "DESCO", "EK1700",
    ]

    static var prompts: [String] {
        let request = DecisionRequest(facts: facts(name: "file.txt", text: "text"),
                                      folders: [FolderOption(path: "Documents/Bills", purpose: nil, tags: [])],
                                      earlier: [], newFolderParents: ["Documents"])
        return [
            MLXClassifier.cardSystem, MLXClassifier.unpackSystem, MLXClassifier.folderSystem,
            MLXClassifier.decisionSystem(newFolderParents: ["Documents", "Pictures"]),
            MLXClassifier.decisionMessage(request, card: nil), VisionCardWriter.system,
        ]
    }

    @Test func promptsNeverMentionTheTestSets() {
        for prompt in Self.prompts {
            for name in Self.testSetNames {
                #expect(!prompt.localizedCaseInsensitiveContains(name), "a prompt mentions \(name)")
            }
        }
    }

    /// Prompts are built in OrganizerCore; no code there (comments aside) names the test sets.
    @Test func coreCodeNeverMentionsTheTestSets() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/OrganizerCore").standardizedFileURL
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(files.count > 20)
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for line in code {
                for name in Self.testSetNames {
                    #expect(!line.localizedCaseInsensitiveContains(name), "\(file.lastPathComponent): \(line)")
                }
            }
        }
    }

    @Test func theCorpusIsComplete() {
        #expect(BenchmarkCorpus.allFiles.count == 27)
        #expect(BenchmarkCorpus.texts.count == 27)
        #expect(Set(BenchmarkCorpus.allFiles.map(\.fileName)).count == 27, "file names are unique")
        for (id, name) in BenchmarkCorpus.allFiles {
            #expect(!BenchmarkCorpus.text(name).isEmpty, "\(name) has text")
            #expect(BenchmarkCorpus.cardKeys[id] != nil, "\(id) has a card key")
        }
        for file in BenchmarkCorpus.earlierFiles {
            if let folder = file.folder { #expect(BenchmarkCorpus.existingFolders.contains(folder)) }
        }
        #expect(BenchmarkCorpus.scenarios.count == 12)
        for scenario in BenchmarkCorpus.scenarios {
            #expect(BenchmarkCorpus.new(scenario.newFile) != nil)
            #expect(scenario.candidates.count == 5)
            #expect(scenario.candidates.allSatisfy { BenchmarkCorpus.earlier($0) != nil }, "\(scenario.id)")
            #expect(scenario.neighbours.allSatisfy(scenario.candidates.contains), "\(scenario.id)")
        }
        #expect(BenchmarkCorpus.scenarios.filter(\.neighbours.isEmpty).map(\.id) == ["S3", "S10"])
    }

    @Test func cardsAreScoredByKindAndIssuer() {
        let bill = FileCard(kind: "Electricity bill", issuer: "Northwind Electric", subject: "July", suggestedName: "x", summary: "")
        #expect(BenchmarkCorpus.score(bill, id: "E1") == (true, true))
        #expect(BenchmarkCorpus.score(bill, id: "W1") == (true, false))
        let letter = FileCard(kind: "letter", issuer: nil, subject: "", suggestedName: "x", summary: "")
        #expect(BenchmarkCorpus.score(letter, id: "E1") == (false, false))
        #expect(BenchmarkCorpus.score(nil, id: "E1") == (false, false))
    }

    @Test func decisionsAreScoredByTheBenchmarksRules() {
        func score(_ id: String, _ action: FolderDecision.Action?, _ folder: String?, _ moved: Set<String> = []) -> BenchmarkCorpus.Mark {
            BenchmarkCorpus.score(BenchmarkCorpus.scenarios.first { $0.id == id }!, action: action, folder: folder, moved: moved)
        }
        #expect(score("S1", .newFolder, "Documents/Bills/Electricity", ["E1"]) == .right)
        #expect(score("S1", .newFolder, "Documents/Electricity", ["E1"]) == .partly)
        #expect(score("S1", .join, "Documents/Bills", ["E1"]) == .partly)
        #expect(score("S1", .newFolder, "Documents/Bills/Electricity") == .wrong, "the earlier bill must move too")
        #expect(score("S1", .wait, nil) == .wrong)
        #expect(score("S2", .join, "documents/bills/water/") == .right, "case and a trailing slash don't matter")
        #expect(score("S2", .join, "Documents/Bills/Water", ["W1"]) == .wrong, "W1 is already there")
        #expect(score("S3", .wait, nil) == .right)
        #expect(score("S3", .join, "Documents/Bills") == .wrong)
        #expect(score("S7", .newFolder, "Documents/Housing", ["H1", "H2"]) == .right)
        #expect(score("S7", .newFolder, "Documents/Housing", ["H1"]) == .partly)
        #expect(score("S8", .newFolder, "Documents/Medical", ["L1"]) == .right)
        #expect(score("S8", .newFolder, "Documents/Medical", ["L1", "L2"]) == .right)
        #expect(score("S8", .newFolder, "Documents/Medical", ["L2"]) == .wrong)
        #expect(score("S12", .join, "Documents/Career", ["P1"]) == .partly)
        #expect(score("S12", .newFolder, "Documents/Payslips", ["P1"]) == .right)
        #expect(score("S12", nil, nil) == .wrong, "no valid answer")
    }

    @Test func recallCountsOnlyFilesThatShouldMatch() {
        let s2 = BenchmarkCorpus.scenarios.first { $0.id == "S2" }!
        let s3 = BenchmarkCorpus.scenarios.first { $0.id == "S3" }!
        #expect(BenchmarkCorpus.recallHit(s2, top3: ["W2", "E1", "W1"]) == true)
        #expect(BenchmarkCorpus.recallHit(s2, top3: ["W1", "E1", "R1"]) == false, "both water bills are expected")
        #expect(BenchmarkCorpus.recallHit(s3, top3: ["E1", "W1", "W2"]) == nil)
    }

    /// Ranking fixed vectors as the eval does: by cosine, best first.
    @Test func recallOnFixedVectors() {
        let query: [Float] = [1, 0, 0]
        let earlier: [String: [Float]] = ["W1": [0.9, 0.1, 0], "W2": [0.8, 0.3, 0], "E1": [0.5, 0.5, 0.5], "R1": [0, 1, 0]]
        let top3 = earlier.map { ($0.key, Vectors.cosine(query, $0.value)) }.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
        #expect(top3 == ["W1", "W2", "E1"])
        #expect(BenchmarkCorpus.recallHit(BenchmarkCorpus.scenarios.first { $0.id == "S2" }!, top3: top3) == true)
    }
}

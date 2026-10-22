import Foundation
import Testing
@testable import OrganizerCore

/// The organizer's questions to Qwen3, with a scripted model standing in for MLX.
struct MLXClassifierTests {
    let bill = facts(name: "document (4).pdf", text: "City Power. Electricity bill for March 2026. Amount due 42.10")
    let folders = [
        FolderOption(path: "Documents/Bills", purpose: "electricity and water bills", tags: []),
        FolderOption(path: "Desktop/To Delete (Review)", purpose: nil, tags: []),
    ]
    let card = #"{"kind": "electricity bill", "issuer": "City Power", "subject": "March electricity use", "date": "2026-03", "people": [], "suggested_name": "City Power electricity bill 2026-03", "summary": "A March electricity bill."}"#

    func request(_ facts: FileFacts) -> ClassificationRequest {
        ClassificationRequest(facts: facts, folders: folders, newFolderParents: ["Documents"],
                              reviewFolder: "Desktop/To Delete (Review)")
    }

    func placement(folder: String, newFolder: String? = nil, confidence: String = "high") -> String {
        let new = newFolder.map { "\"\($0)\"" } ?? "null"
        return #"{"reason": "It is a bill.", "kind": "electricity bill", "folder": "\#(folder)", "new_folder": \#(new), "new_name": null, "confidence": "\#(confidence)"}"#
    }

    // MARK: Cards

    @Test func oneCardServesDescribeAndName() async throws {
        let model = ScriptedModel(answers: [card])
        let classifier = MLXClassifier(model: model)
        let description = try await classifier.describe(bill)
        let name = try await classifier.suggestName(for: bill)
        #expect(description == FileDescription(kind: "electricity bill", category: "electricity bill"))
        #expect(name.title == "City Power electricity bill 2026-03")
        #expect(name.confidence == 0.9)
        #expect(model.requests.count == 1)
        let asked = try #require(model.requests.first)
        #expect(asked.thinking == false)
        #expect(asked.messages.first == .system(MLXClassifier.cardSystem))
        #expect(asked.messages.last?.content.contains("Electricity bill for March 2026") == true)
    }

    @Test func aNameWithoutTextIsNotTrusted() async throws {
        let model = ScriptedModel(answers: [#"{"kind": "archive", "issuer": null, "subject": "unknown", "date": null, "people": [], "suggested_name": "Archive", "summary": "An archive."}"#])
        let name = try await MLXClassifier(model: model).suggestName(for: facts(name: "download.bin", text: nil))
        #expect(name.confidence < OrganizerConfig().confidenceThreshold)
    }

    @Test func imagesWithoutTextWaitForTheVisionModel() async {
        let model = ScriptedModel(answers: [card])
        let photo = facts(name: "IMG_0001.jpg", text: nil, kind: .image)
        await #expect(throws: ClassifierError.unavailable("an image without text needs the vision model")) {
            _ = try await MLXClassifier(model: model).describe(photo)
        }
        #expect(model.requests.isEmpty)
    }

    @Test func imagesWithTextGetACard() async throws {
        let model = ScriptedModel(answers: [card])
        let screenshot = facts(name: "Screenshot.png", text: "Electricity bill, March", kind: .image)
        #expect(try await MLXClassifier(model: model).describe(screenshot).kind == "electricity bill")
    }

    @Test func aCardWithoutAKindIsAskedAgain() async throws {
        let empty = card.replacingOccurrences(of: #""kind": "electricity bill""#, with: #""kind": """#)
        let model = ScriptedModel(answers: [empty, card])
        #expect(try await MLXClassifier(model: model).describe(bill).kind == "electricity bill")
        #expect(model.requests[1].messages.last?.content.contains("\"kind\" is empty") == true)
    }

    // MARK: Where does it go?

    @Test func existingFolderWithThinkingAndReasonFirst() async throws {
        let model = ScriptedModel(answers: [card, placement(folder: "Documents/Bills")])
        let classifier = MLXClassifier(model: model)
        _ = try await classifier.describe(bill)
        let suggestion = try await classifier.suggest(request(bill))
        #expect(suggestion.destination == "Documents/Bills")
        #expect(!suggestion.isNewFolder)
        #expect(suggestion.confidence == 0.9)
        #expect(suggestion.reason == "Electricity bill: It is a bill.")
        let asked = model.requests[1]
        #expect(asked.thinking)
        let system = asked.messages[0].content
        let reason = try #require(system.range(of: #"{"reason""#))
        let folder = try #require(system.range(of: #""folder""#))
        #expect(reason.lowerBound < folder.lowerBound)
        #expect(system.contains("- Documents/Bills: electricity and water bills"))
        // The card made earlier in the run goes with the question.
        #expect(asked.messages[1].content.hasPrefix("About this file: kind: electricity bill; issuer: City Power"))
    }

    @Test func noneFitsMakesANewFolder() async throws {
        let model = ScriptedModel(answers: [placement(folder: "none of these", newFolder: "Documents/Utility Bills/")])
        let suggestion = try await MLXClassifier(model: model).suggest(request(bill))
        #expect(suggestion.destination == "Documents/Utility Bills")
        #expect(suggestion.isNewFolder)
        #expect(suggestion.reason.hasPrefix("Electricity bill: no existing folder fits, new folder \"Utility Bills\""))
    }

    @Test(arguments: [
        ("Documents/Billz", #""folder" must be copied exactly from the list, or be "none of these""#),
        ("none of these", #""folder" is "none of these", so "new_folder" must name the new folder"#),
    ])
    func badFoldersAreAskedAgain(folder: String, problem: String) async throws {
        let model = ScriptedModel(answers: [placement(folder: folder), placement(folder: "Documents/Bills")])
        let suggestion = try await MLXClassifier(model: model).suggest(request(bill))
        #expect(suggestion.destination == "Documents/Bills")
        #expect(model.requests[1].messages.last?.content
                == "That answer is invalid: \(problem). Answer again with one JSON object only.")
    }

    @Test(arguments: ["Pictures/Bills", "Documents/", "Documents/Bills/2026"])
    func newFoldersOnlyDirectlyUnderAnAllowedParent(path: String) {
        let answer = MLXClassifier.Placement(reason: "r", kind: "k", folder: "none of these", newFolder: path, confidence: "high")
        #expect(MLXClassifier.problem(with: answer, folders: folders, newFolderParents: ["Documents"]) != nil)
    }

    @Test func confidenceMustBeAWord() {
        let answer = MLXClassifier.Placement(reason: "r", kind: "k", folder: "Documents/Bills", confidence: "0.9")
        #expect(MLXClassifier.problem(with: answer, folders: folders, newFolderParents: ["Documents"]) != nil)
    }

    @Test func invalidAfterTheRetriesThrows() async {
        let model = ScriptedModel(answers: ["no", "still no", "nope"])
        await #expect(throws: ClassifierError.invalidAnswer("the answer is not a single valid JSON object")) {
            _ = try await MLXClassifier(model: model).suggest(request(bill))
        }
        #expect(model.requests.count == 3)
    }

    @Test func unavailableAsksNothing() async {
        let model = ScriptedModel(answers: [card])
        let classifier = MLXClassifier(model: model) { "Qwen3 8B isn't downloaded yet" }
        await #expect(throws: ClassifierError.unavailable("Qwen3 8B isn't downloaded yet")) {
            _ = try await classifier.describe(bill)
        }
        #expect(model.requests.isEmpty)
    }

    @Test func groupsAreAskedOnceForAllMembers() async throws {
        let model = ScriptedModel(answers: [placement(folder: "Documents/Bills")])
        let second = facts(name: "gas.pdf", text: "Gas bill, April")
        let group = GroupRequest(members: [bill, second], category: "bill", folders: folders, newFolderParents: ["Documents"],
                                 reviewFolder: "Desktop/To Delete (Review)")
        let answer = try await MLXClassifier(model: model).placeGroup(group)
        #expect(answer.belongTogether)
        #expect(answer.suggestion.destination == "Documents/Bills")
        let asked = try #require(model.requests.first)
        #expect(asked.thinking)
        #expect(asked.messages[1].content.contains("These 2 downloaded files"))
        #expect(asked.messages[1].content.contains("Gas bill, April"))
        #expect(!asked.messages[0].content.contains("new_name"))
    }

    // MARK: Folders

    @Test func unpackDecision() async throws {
        let model = ScriptedModel(answers: [#"{"reason": "Unrelated files.", "kind": "assorted downloads", "keep_together": false, "confidence": "medium"}"#])
        let answer = try await MLXClassifier(model: model).suggestUnpack(for: facts(name: "Misc", text: nil))
        #expect(answer.unpack)
        #expect(answer.kind == "assorted downloads")
        #expect(answer.confidence == 0.75)
        #expect(model.requests.first?.thinking == true)
    }

    @Test func folderPurposeWithoutThinking() async throws {
        let model = ScriptedModel(answers: [#"{"purpose": "electricity and water bills."}"#])
        let purpose = try await MLXClassifier(model: model).describeFolder(FolderProfile(path: "Documents/Bills", fileCount: 2))
        #expect(purpose == "electricity and water bills")
        #expect(model.requests.first?.thinking == false)
    }
}

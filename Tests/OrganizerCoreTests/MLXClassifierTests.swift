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

    let earlier = [
        EarlierCandidate(id: "E1", path: "/d/Downloads/gas.pdf", name: "gas.pdf", folder: nil, about: "kind: gas bill"),
        EarlierCandidate(id: "E2", path: "/h/Documents/Bills/water.pdf", name: "water.pdf", folder: "Documents/Bills",
                         about: "kind: water bill"),
    ]

    func request(_ facts: FileFacts) -> DecisionRequest {
        DecisionRequest(facts: facts, folders: folders.filter { $0.path == "Documents/Bills" }, earlier: earlier,
                        newFolderParents: ["Documents"])
    }

    func decision(_ action: String, folder: String?, earlier: [String] = [], name: String = "City Power bill March 2026") -> String {
        let folder = folder.map { "\"\($0)\"" } ?? "null"
        let ids = earlier.map { "\"\($0)\"" }.joined(separator: ", ")
        return #"{"reason": "It is a bill.", "action": "\#(action)", "folder": \#(folder), "move_earlier": [\#(ids)], "new_file_name": "\#(name)"}"#
    }

    // MARK: Cards

    @Test func oneCardServesCatalogAndName() async throws {
        let model = ScriptedModel(answers: [card])
        let classifier = MLXClassifier(model: model)
        let card = try await classifier.card(for: bill)
        let name = try await classifier.suggestName(for: bill)
        #expect(card.kind == "electricity bill")
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
            _ = try await MLXClassifier(model: model).card(for: photo)
        }
        #expect(model.requests.isEmpty)
    }

    @Test func imagesWithTextGetACard() async throws {
        let model = ScriptedModel(answers: [card])
        let screenshot = facts(name: "Screenshot.png", text: "Electricity bill, March", kind: .image)
        #expect(try await MLXClassifier(model: model).card(for: screenshot).kind == "electricity bill")
    }

    @Test func aCardWithoutAKindIsAskedAgain() async throws {
        let empty = card.replacingOccurrences(of: #""kind": "electricity bill""#, with: #""kind": """#)
        let model = ScriptedModel(answers: [empty, card])
        #expect(try await MLXClassifier(model: model).card(for: bill).kind == "electricity bill")
        #expect(model.requests[1].messages.last?.content.contains("\"kind\" is empty") == true)
    }

    // MARK: Where does it go?

    @Test func joinWithThinkingTheBenchmarkPromptAndTheEarlierFiles() async throws {
        let model = ScriptedModel(answers: [card, decision("join", folder: "Documents/Bills", earlier: ["E1"])])
        let answer = try await MLXClassifier(model: model).decide(request(bill))
        #expect(answer == FolderDecision(reason: "It is a bill.", action: .join, folder: "Documents/Bills", moveEarlier: ["E1"],
                                         newFileName: "City Power bill March 2026"))
        let asked = model.requests[1]
        #expect(asked.thinking)
        let system = asked.messages[0].content
        #expect(system.contains(#"{"reason": string, "action": "join" or "new_folder" or "wait""#))
        #expect(system.contains(#"it must start with "Documents/" and must not already exist"#))
        #expect(system.contains(#"shown as "Downloads (waiting)""#))
        #expect(!system.contains("Unsorted"))
        let message = asked.messages[1].content
        #expect(message.contains("- Documents/Bills: electricity and water bills"))
        #expect(message.contains("- id: E1 | folder: Downloads (waiting) | name: gas.pdf | about: kind: gas bill"))
        #expect(message.contains("- id: E2 | folder: Documents/Bills | name: water.pdf | about: kind: water bill"))
        #expect(message.contains("About the new file: kind: electricity bill; issuer: City Power"))
        #expect(message.contains("Electricity bill for March 2026"))
    }

    @Test func noEarlierFilesSaysSo() {
        var plain = request(bill)
        plain.earlier = []
        #expect(MLXClassifier.decisionMessage(plain, card: nil).contains("Earlier files:\n(none)"))
    }

    @Test(arguments: [
        (#"{"reason": "r", "action": "join", "folder": "Documents/Billz", "move_earlier": [], "new_file_name": "x"}"#,
         #"for "join", "folder" must be copied exactly from the list of existing folders"#),
        (#"{"reason": "r", "action": "new_folder", "folder": "Documents/Bills", "move_earlier": ["E1"], "new_file_name": "x"}"#,
         #"for "new_folder", "folder" must not already exist; use "join" for an existing folder"#),
        (#"{"reason": "r", "action": "new_folder", "folder": "Pictures/Bills", "move_earlier": ["E1"], "new_file_name": "x"}"#,
         #"for "new_folder", "folder" must start with "Documents/""#),
        (#"{"reason": "r", "action": "new_folder", "folder": "Documents/Utilities", "move_earlier": [], "new_file_name": "x"}"#,
         #"for "new_folder", "move_earlier" must list at least one earlier file id"#),
        (#"{"reason": "r", "action": "new_folder", "folder": "Documents/Bills/Old", "move_earlier": ["E2"], "new_file_name": "x"}"#,
         ""),
        (#"{"reason": "r", "action": "join", "folder": "Documents/Bills", "move_earlier": ["E7"], "new_file_name": "x"}"#,
         #""move_earlier" may only use ids from the list (E1, E2), not "E7""#),
        (#"{"reason": "r", "action": "wait", "folder": "Documents/Bills", "move_earlier": [], "new_file_name": "x"}"#,
         #"for "wait", "folder" must be null"#),
        (#"{"reason": "r", "action": "file it", "folder": null, "move_earlier": [], "new_file_name": "x"}"#,
         #"the field "action" has an invalid value"#),
    ])
    func badAnswersAreAskedAgain(answer: String, problem: String) async throws {
        let model = ScriptedModel(answers: [card, answer, decision("wait", folder: nil)])
        let result = try await MLXClassifier(model: model).decide(request(bill))
        if problem.isEmpty {
            // Valid: a new folder may sit inside an existing one.
            #expect(result.action == .newFolder)
            return
        }
        #expect(result.action == .wait)
        #expect(model.requests[2].messages.last?.content
                == "That answer is invalid: \(problem). Answer again with one JSON object only.")
    }

    @Test func aNewFolderNeedsAFileThatIsntAlreadyThere() {
        let answer = FolderDecision(reason: "r", action: .newFolder, folder: "Documents/Utilities", moveEarlier: ["E2"])
        var request = request(bill)
        request.earlier[1].folder = "Documents/Utilities"
        request.earlier[1].isProposed = true
        #expect(answer.problem(in: request) == #"for "new_folder", "move_earlier" must list at least one earlier file id"#)
    }

    @Test func invalidAfterTheRetriesThrows() async {
        let model = ScriptedModel(answers: [card, "no", "still no", "nope"])
        await #expect(throws: ClassifierError.invalidAnswer("the answer is not a single valid JSON object")) {
            _ = try await MLXClassifier(model: model).decide(request(bill))
        }
        #expect(model.requests.count == 4)
    }

    @Test func unavailableAsksNothing() async {
        let model = ScriptedModel(answers: [card])
        let classifier = MLXClassifier(model: model) { "Qwen3 8B isn't downloaded yet" }
        await #expect(throws: ClassifierError.unavailable("Qwen3 8B isn't downloaded yet")) {
            _ = try await classifier.decide(request(bill))
        }
        #expect(model.requests.isEmpty)
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

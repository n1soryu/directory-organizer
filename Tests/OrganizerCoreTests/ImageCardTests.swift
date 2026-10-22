import Foundation
import Testing
@testable import OrganizerCore
@testable import TestDataKit

struct VisionCardWriterTests {
    let card = #"{"kind": "receipt", "issuer": "A shop", "subject": "groceries", "date": null, "people": [], "suggested_name": "shop receipt", "summary": "A receipt."}"#

    func facts(_ name: String, text: String? = nil) -> FileFacts {
        OrganizerCoreTests.facts(name: name, text: text, kind: .image)
    }

    @Test func everyRequestCarriesTheImageRetriesToo() async throws {
        let model = ScriptedModel(answers: ["not json", card])
        let result = try await VisionCardWriter(model: model).card(for: facts("IMG_1.jpg"))
        #expect(result.kind == "receipt")
        #expect(model.requests.count == 2)
        #expect(model.requests.allSatisfy { $0.image == URL(filePath: "/tmp/IMG_1.jpg") })
        #expect(model.requests.allSatisfy { !$0.thinking })
    }

    @Test func promptHasTheOCRTextWhenThereIsSome() {
        #expect(VisionCardWriter.prompt(for: facts("IMG_1.jpg", text: "TOTAL 10.30")).contains("TOTAL 10.30"))
        #expect(!VisionCardWriter.prompt(for: facts("IMG_1.jpg")).contains("OCR"))
    }

    @Test func invalidAfterRetriesThrows() async {
        let model = ScriptedModel(answers: ["a", "b", "c"])
        await #expect(throws: ClassifierError.self) {
            _ = try await VisionCardWriter(model: model).card(for: facts("IMG_1.jpg"))
        }
    }

    @Test func finishReleasesTheModel() async {
        let released = Flag()
        await VisionCardWriter(model: ScriptedModel(answers: [])) { released.set() }.finish()
        #expect(released.value)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}

struct ImageEvalSetTests {
    @Test func buildsEveryImageAndNeverReplacesAFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "image-eval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let set = try ImageEvalSet.build(in: folder)
        // 11 drawn; the 6 photos and the meme only when Apple's pictures are there.
        let hasPictures = FileManager.default.fileExists(atPath: ImageEvalSet.userPictures.path)
        #expect(set.count == (hasPictures ? 18 : 11))
        for image in set {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: image.file).path), "\(image.file)")
        }
        #expect(throws: CocoaError.self) { _ = try ImageEvalSet.build(in: folder) }
    }

    @Test func scoring() {
        let image = EvalImage(file: "x.jpg", label: "receipt", kinds: ["receipt"], fact: "shop",
                              factWords: ["greenleaf"], isDocument: true)
        let right = FileCard(kind: "grocery receipt", issuer: "Greenleaf Grocers", subject: "food",
                             suggestedName: "Greenleaf receipt 2026-09-14", summary: "s")
        let wrong = FileCard(kind: "photo", subject: "paper", suggestedName: "x.jpg", summary: "s")
        #expect(ImageEvalSet.score(right, for: image) == EvalScore(kind: true, fact: true, name: true, split: true))
        #expect(ImageEvalSet.score(wrong, for: image) == EvalScore(kind: false, fact: false, name: false, split: false))
    }
}

import Foundation
import Testing
@testable import OrganizerCore
@testable import TestDataKit

/// Organize Now's image phase: the vision model cards the images first and is released before
/// the text model is asked anything; pictures keep going to Downloaded Images with a real name,
/// document-like images are decided like documents.
@Suite(.serialized) struct ImagePhaseTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "file-organizer-images-\(UUID().uuidString)")
    var downloads: URL { root.appending(path: "Downloads") }
    var home: URL { root.appending(path: "Home") }

    /// Cards by file name; records what it was asked and when it was released.
    final class FakeVision: ImageCardWriter, @unchecked Sendable {
        private let lock = NSLock()
        private var _asked: [String] = []
        private var _finished = 0
        let cards: [String: FileCard]
        var asked: [String] { lock.withLock { _asked } }
        var finished: Int { lock.withLock { _finished } }
        var isFinished: Bool { finished > 0 }

        init(_ cards: [String: FileCard]) { self.cards = cards }

        func card(for facts: FileFacts) async throws -> FileCard {
            lock.withLock { _asked.append(facts.name) }
            guard let card = cards[facts.name] else { throw ClassifierError.invalidAnswer("unreadable") }
            return card
        }

        func finish() async { lock.withLock { _finished += 1 } }
    }

    /// A text model that never gives a valid answer, and notes whether the vision model was
    /// still loaded when it was asked.
    final class TextModel: LanguageModel, @unchecked Sendable {
        private let lock = NSLock()
        private var _prompts: [String] = []
        private var _askedTooEarly = false
        let vision: FakeVision
        var prompts: [String] { lock.withLock { _prompts } }
        var askedTooEarly: Bool { lock.withLock { _askedTooEarly } }

        init(vision: FakeVision) { self.vision = vision }

        func continueChat(_ request: GenerationRequest) async throws -> GenerationOutput {
            let early = !vision.isFinished
            lock.withLock {
                _prompts.append(request.messages.map(\.content).joined(separator: "\n"))
                if early { _askedTooEarly = true }
            }
            return GenerationOutput(text: "no idea", hitTokenLimit: false)
        }
    }

    static let photo = FileCard(kind: "photo", subject: "a red bicycle", suggestedName: "Red bicycle by a wall", summary: "A bicycle.")
    static let receipt = FileCard(kind: "grocery receipt", issuer: "Corner Shop", subject: "groceries",
                                  suggestedName: "Corner Shop receipt", summary: "A receipt.")

    func setUp() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: OrganizerConfig().downloadedImages), withIntermediateDirectories: true)
        try Drawing.picture(seed: 1, to: downloads.appending(path: "IMG_0001.jpg"))
        try Drawing.picture(seed: 2, to: downloads.appending(path: "IMG_0002.jpg"))
        try Drawing.picture(seed: 3, to: downloads.appending(path: "IMG_0003.jpg"))
        // An identical copy: a duplicate, never shown to the vision model.
        try fm.copyItem(at: downloads.appending(path: "IMG_0001.jpg"), to: downloads.appending(path: "IMG_0001 (1).jpg"))
        try Data("just some notes".utf8).write(to: downloads.appending(path: "notes.txt"))
    }

    func planner(vision: FakeVision?, text: TextModel?) -> Planner {
        var planner = Planner(homeRoot: home)
        if let text { planner.classifier = MLXClassifier(model: text) }
        planner.imageCards = vision
        return planner
    }

    @Test func picturesAndDocumentsGoTheirWays() async throws {
        try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        // IMG_0003 can't be described: it falls back to the image rule.
        let vision = FakeVision(["IMG_0001.jpg": Self.photo, "IMG_0002.jpg": Self.receipt])
        let text = TextModel(vision: vision)
        let plan = try await planner(vision: vision, text: text).plan(folder: downloads)
        let byName = Dictionary(uniqueKeysWithValues: plan.actions.map { ($0.originalName, $0) })
        let images = OrganizerConfig().downloadedImages

        // Only the images the image rule would have placed: not the duplicate, not the text file.
        #expect(Set(vision.asked) == ["IMG_0001.jpg", "IMG_0002.jpg", "IMG_0003.jpg"])
        #expect(vision.finished == 1)
        // The vision model was released before the text model was asked anything.
        #expect(!text.askedTooEarly)

        let photo = try #require(byName["IMG_0001.jpg"])
        #expect(photo.destinationFolder == images)
        #expect(photo.decidedBy == .rule("image"))
        #expect(photo.finalName.hasSuffix("Red bicycle by a wall.jpg"))

        // The receipt went to the model like a document (here it gave no valid answer, so it
        // waits in Downloads).
        #expect(byName["IMG_0002.jpg"] == nil)
        #expect(plan.waiting.contains { $0.name == "IMG_0002.jpg" && $0.forMatch })
        #expect(text.prompts.contains { $0.contains("IMG_0002.jpg") })

        let unknown = try #require(byName["IMG_0003.jpg"])
        #expect(unknown.destinationFolder == images)
        #expect(unknown.decidedBy == .rule("image"))
    }

    @Test func withoutTheVisionModelImagesGoByTheRule() async throws {
        try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await planner(vision: nil, text: nil).plan(folder: downloads)
        let images = plan.actions.filter { $0.originalName.hasPrefix("IMG_000") && !$0.originalName.contains("(1)") }
        #expect(images.count == 3)
        #expect(images.allSatisfy { $0.destinationFolder == OrganizerConfig().downloadedImages })
    }

    @Test func quickScanNeverLoadsTheVisionModel() async throws {
        try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let vision = FakeVision([:])
        var quick = Planner(homeRoot: home, mode: .quick)
        quick.imageCards = vision
        _ = try await quick.plan(folder: downloads)
        #expect(vision.asked.isEmpty)
        #expect(vision.finished == 0)
    }

    @Test func cancellingStillReleasesTheVisionModel() async throws {
        try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let vision = FakeVision([:])
        let planner = planner(vision: vision, text: nil)
        let facts = await [downloads.appending(path: "IMG_0001.jpg")].asyncMap { await planner.extractor.facts(for: $0) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await planner.describingImages(facts, copies: [:], writer: vision, progress: nil)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(vision.finished == 1)
    }

    @Test func aScreenshotTheVisionModelSawGetsItsName() async throws {
        try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = downloads.appending(path: "Screenshot 2026-10-12 at 21.14.03.png")
        try Drawing.picture(seed: 4, type: .png, to: shot)
        try ScreenCapture.mark(shot)
        let card = FileCard(kind: "screenshot", issuer: "Router", subject: "wireless settings",
                            suggestedName: "Router_wireless_settings", summary: "Settings page.")
        let vision = FakeVision([shot.lastPathComponent: card])
        let plan = try await planner(vision: vision, text: TextModel(vision: vision)).plan(folder: downloads)
        let action = try #require(plan.actions.first { $0.originalName == shot.lastPathComponent })
        #expect(action.destinationFolder == OrganizerConfig().downloadedImages)
        #expect(action.finalName.hasSuffix(" Router wireless settings.png"))
    }

    @Test func modelNamesLoseTheirUnderscores() {
        #expect(Planner.validTitle("Greenleaf_Grocers_2026-09-14") == "Greenleaf Grocers 2026-09-14")
        #expect(Planner.validTitle("colorful__ovals.png") == "colorful ovals")
    }

    @Test(arguments: [
        ("receipt", true), ("grocery receipt", true), ("boarding pass", true), ("electricity bill", true),
        ("bar chart", true), ("presentation slide", true), ("Receipts", true),
        ("photo", false), ("meme", false), ("screenshot", false), ("landscape photograph", false), ("id card", true),
    ])
    func documentKinds(kind: String, isDocument: Bool) {
        #expect(ImageKinds.isDocument(kind) == isDocument)
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var result: [T] = []
        for element in self { result.append(await transform(element)) }
        return result
    }
}

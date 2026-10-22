import Foundation

/// Writes cards for images: photos, screenshots, photographed documents. The same card fields
/// as the text model's, so an image is filed like any other file afterwards.
public protocol ImageCardWriter: Sendable {
    func card(for facts: FileFacts) async throws -> FileCard
    /// The image phase is over: release the vision model before the text model loads.
    func finish() async
}

/// Image cards from a local vision model (Qwen3-VL or Gemma 3 through MLX in the app; scripted in tests).
/// The model sees the picture and, when OCR found any, the text in it. Thinking is off, as for text cards.
public struct VisionCardWriter: ImageCardWriter {
    private let model: any LanguageModel
    private let release: @Sendable () async -> Void
    /// Characters of OCR text sent along with the picture.
    public static let textLimit = 2_000

    public init(model: any LanguageModel, release: @escaping @Sendable () async -> Void = {}) {
        self.model = model
        self.release = release
    }

    static let system = """
        You look at one image that a person downloaded and describe it so it can be filed later.
        Answer with one JSON object only, no other text, with these fields:
        {"kind": string, "issuer": string or null, "subject": string, "date": string or null, "people": [string], "suggested_name": string, "summary": string}
        Field rules:
        - kind: what sort of image or document this is, in 1 to 3 lowercase words.
        - issuer: the organisation, shop, app or person that produced what is shown, or null if the image does not say.
        - subject: what it shows or is about, at most 8 words.
        - date: the most relevant date shown, as YYYY-MM-DD or YYYY-MM, or null.
        - people: names of people the image is for or about, if written in it; [] if none.
        - suggested_name: a new, descriptive file name for what the image shows, without extension; never the current file name; include the issuer and date when they help.
        - summary: one sentence.
        Use only what the image shows. Do not guess.
        """

    static func prompt(for facts: FileFacts) -> String {
        var lines = ["Image file name: \(facts.url.lastPathComponent)"]
        if facts.isScreenshot { lines.append("macOS saved it as a screenshot.") }
        let text = (facts.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            lines.append("Text found in the image (OCR, may be partial or out of order):")
            lines.append(String(text.prefix(textLimit)))
        }
        lines.append("Describe the image.")
        return lines.joined(separator: "\n")
    }

    public func card(for facts: FileFacts) async throws -> FileCard {
        let outcome = try await ask(for: facts)
        guard let card = outcome.value else {
            throw ClassifierError.invalidAnswer(outcome.problems.last?.description ?? "no answer")
        }
        return card
    }

    /// The whole exchange, retries included (the evaluation reports them).
    public func ask(for facts: FileFacts) async throws -> JSONAnswer.Outcome<FileCard> {
        try await WithImage(base: model, image: facts.url).askJSON(FileCard.self, messages: [
            .system(Self.system),
            .user(Self.prompt(for: facts)),
        ], thinking: false) { card in
            if card.kind.trimmingCharacters(in: .whitespaces).isEmpty { return "\"kind\" is empty" }
            if card.suggestedName.trimmingCharacters(in: .whitespaces).isEmpty { return "\"suggested_name\" is empty" }
            return nil
        }
    }

    public func finish() async {
        await release()
    }
}

/// Which images are documents. Anything else (a photo, a meme, a screenshot of an app) is a
/// picture, and pictures keep going to Downloaded Images: a folder decision takes a minute, too
/// long to spend on every meme. Matched on whole words of the card's `kind`.
public enum ImageKinds {
    static let documentWords: Set<String> = [
        "receipt", "invoice", "bill", "statement", "ticket", "pass", "boarding", "letter", "document", "form",
        "certificate", "contract", "notice", "reminder", "diagram", "chart", "graph", "flowchart", "slide",
        "presentation", "scan", "page", "report", "schedule", "timetable", "transcript", "itinerary", "booking",
        "confirmation", "prescription", "passport", "licence", "license", "id", "menu", "handout", "worksheet",
        "notes", "map", "table", "poster", "flyer",
    ]

    public static func isDocument(_ kind: String) -> Bool {
        kind.lowercased().split { !$0.isLetter }.contains { word in
            documentWords.contains(String(word))
                || (word.hasSuffix("s") && documentWords.contains(String(word.dropLast())))
        }
    }
}

/// Every request of one conversation carries the same image (retries included).
private struct WithImage: LanguageModel {
    let base: any LanguageModel
    let image: URL

    func continueChat(_ request: GenerationRequest) async throws -> GenerationOutput {
        var request = request
        request.image = image
        return try await base.continueChat(request)
    }
}

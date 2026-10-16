import Foundation
import FoundationModels

/// Apple's on-device model (Foundation Models framework). Runs locally, no network.
///
/// Answers are constrained with a schema built at runtime (`DynamicGenerationSchema`): the
/// destination is an `anyOf` over the folders offered, so the model can't name a folder that
/// isn't on the list. Swift still checks everything it returns.
public struct AppleClassifier: FileClassifier {
    public let name = "apple"
    /// Characters of document text to include. The model's window is ~8k tokens in total.
    public var textLimit = 2_500

    /// Offered alongside the folders; leads to the second question (which new folder?).
    static let noneFits = "none of these"
    /// The model isn't good at precise probabilities, so it picks a word; we map it to a number.
    static let confidenceLevels: [String: Double] = ["high": 0.9, "medium": 0.75, "low": 0.4]

    public init() {}

    /// nil if the model can be used, otherwise why not, in plain words.
    public static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "this Mac can't run Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is turned off (System Settings → Siri)"
        case .unavailable(.modelNotReady): "the model is still downloading or getting ready"
        case .unavailable(let other): "\(other)"
        }
    }

    public static var canSeeImages: Bool {
        SystemLanguageModel.default.capabilities.contains(.vision)
    }

    // MARK: - Where should this file go?

    public func suggest(_ request: ClassificationRequest) async throws -> ClassifierSuggestion {
        if let reason = Self.unavailableReason() { throw ClassifierError.unavailable(reason) }

        let folderChoices = request.folders.map(\.path) + [Self.noneFits]
        // Property order is generation order: describe the file, reason about which folder's
        // purpose matches, decide whether one fits, and only then pick it (a reason written
        // after the choice only defends it). Tags aren't asked for: they follow from the folder.
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "FileDecision", properties: [
            .init(name: "kind", description: "What this file is, in 2-5 words (e.g. router user manual, electricity bill, lecture slides)",
                  schema: .init(type: String.self)),
            .init(name: "reason", description: "One sentence: which listed folder's purpose matches this kind of file and why, or why none does",
                  schema: .init(type: String.self)),
            .init(name: "existingFolderFits", description: "Is there a listed folder whose purpose clearly matches this kind of file?",
                  schema: .init(name: "Fits", anyOf: ["yes", "no"])),
            .init(name: "destination", description: "The matching folder, or \"none of these\" if no folder's purpose matches",
                  schema: .init(name: "Folder", anyOf: folderChoices)),
            .init(name: "newName", description: "Only if the file name is unclear: a clear name of 2-8 words, no extension",
                  schema: .init(type: String.self), isOptional: true),
            .init(name: "confidence", description: "How sure you are",
                  schema: .init(name: "Confidence", anyOf: ["high", "medium", "low"])),
        ]), dependencies: [])

        let instructions = Self.instructions(folders: request.folders, review: request.reviewFolder,
                                             corrections: request.corrections)
        let content = try await respond(instructions: instructions, schema: schema) { limit in
            Prompt { FactSummary.describe(request.facts, textLimit: limit) }
        }

        let destination: String = try content.value(forProperty: "destination")
        let kind: String = (try? content.value(forProperty: "kind")) ?? ""
        let fits: String = (try? content.value(forProperty: "existingFolderFits")) ?? "yes"
        let because: String = (try? content.value(forProperty: "reason")) ?? ""
        let reason = kind.isEmpty ? because : "\(kind.prefix(1).uppercased() + kind.dropFirst()): \(because)"
        let level: String = (try? content.value(forProperty: "confidence")) ?? "low"
        let suggestion = ClassifierSuggestion(
            destination: destination,
            newBaseName: try? content.value(String?.self, forProperty: "newName"),
            confidence: Self.confidenceLevels[level] ?? 0.4,
            reason: reason
        )
        // No folder fits: ask a second, simpler question about a new folder.
        if destination == Self.noneFits || (fits == "no" && destination == request.reviewFolder) {
            return try await newFolder(for: request, kind: kind, newName: suggestion.newBaseName)
        }
        return suggestion
    }

    /// The second question: which general category folder should this kind of file get?
    private func newFolder(for request: ClassificationRequest, kind: String, newName: String?) async throws -> ClassifierSuggestion {
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "NewFolder", properties: [
            .init(name: "folderName", description: "A general category name, 1-3 words, plural (e.g. Manuals, Bills, Receipts)",
                  schema: .init(type: String.self)),
            .init(name: "parent", description: "Where the new folder goes",
                  schema: .init(name: "Parent", anyOf: request.newFolderParents)),
            .init(name: "confidence", description: "How sure you are that this category suits the file and similar files",
                  schema: .init(name: "Confidence", anyOf: ["high", "medium", "low"])),
        ]), dependencies: [])
        let existing = request.folders.map { $0.path.split(separator: "/").last.map(String.init) ?? $0.path }
        let instructions = """
            You organize downloaded files on a Mac. None of the existing folders fits this file, so it needs a new folder. \
            Name the folder after the general kind of file, so similar files can go there too: \
            "Manuals" for any user guide, "Bills" for any utility bill. Never use the file's own name, a brand or a date. \
            Existing folder names, for reference: \(existing.joined(separator: ", ")).
            """
        let content = try await respond(instructions: instructions, schema: schema) { limit in
            Prompt { "This file is: \(kind)\n\n" + FactSummary.describe(request.facts, textLimit: min(limit, 800)) }
        }
        let name: String = try content.value(forProperty: "folderName")
        let parent: String = try content.value(forProperty: "parent")
        let level: String = (try? content.value(forProperty: "confidence")) ?? "low"
        let folder = name.trimmingCharacters(in: CharacterSet(charactersIn: " /\"'."))
        return ClassifierSuggestion(
            destination: parent + "/" + folder, isNewFolder: true, newBaseName: newName,
            confidence: Self.confidenceLevels[level] ?? 0.4,
            reason: "\(kind.prefix(1).uppercased() + kind.dropFirst()): no existing folder fits, new folder \"\(folder)\"")
    }

    // MARK: - What should this file be called?

    public func suggestName(for facts: FileFacts) async throws -> NameSuggestion {
        if let reason = Self.unavailableReason() { throw ClassifierError.unavailable(reason) }

        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "FileName", properties: [
            .init(name: "title", description: "2-8 words saying what this is, like a good file name. No date, no extension.",
                  schema: .init(type: String.self)),
            .init(name: "confidence", description: "How sure you are",
                  schema: .init(name: "Confidence", anyOf: ["high", "medium", "low"])),
        ]), dependencies: [])

        let showImage = facts.kind == .image && Self.canSeeImages
        let instructions = """
            You name downloaded files on a Mac. Given a file's details\(showImage ? " and the picture itself" : ""), \
            write a short, specific, descriptive title, the way a careful person would name the file. \
            Describe what it is (e.g. "Router wireless settings page", "Bank statement September"), not its format. \
            If you can't tell what it is, say so with low confidence.
            """
        let content = try await respond(instructions: instructions, schema: schema) { limit in
            Prompt {
                FactSummary.describe(facts, textLimit: limit)
                if showImage {
                    Attachment(imageURL: facts.url)
                }
            }
        }
        let title: String = try content.value(forProperty: "title")
        let level: String = (try? content.value(forProperty: "confidence")) ?? "low"
        return NameSuggestion(title: title, confidence: Self.confidenceLevels[level] ?? 0.4)
    }

    // MARK: - Keep this folder together, or unpack it?

    public func suggestUnpack(for facts: FileFacts) async throws -> UnpackSuggestion {
        if let reason = Self.unavailableReason() { throw ClassifierError.unavailable(reason) }

        // Describe first, then decide: the description steers the answer.
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "FolderDecision", properties: [
            .init(name: "kind", description: "What this folder is, in 2-5 words (e.g. photo album, film with subtitles, course pack, mixed downloads)",
                  schema: .init(type: String.self)),
            .init(name: "belongsTogether", description: "Do the items only make sense together, as one thing?",
                  schema: .init(name: "Together", anyOf: ["yes", "no"])),
            .init(name: "reason", description: "One sentence explaining the choice",
                  schema: .init(type: String.self)),
            .init(name: "confidence", description: "How sure you are",
                  schema: .init(name: "Confidence", anyOf: ["high", "medium", "low"])),
        ]), dependencies: [])
        let instructions = """
            You organize downloaded folders on a Mac. Decide whether a folder is one thing that must stay \
            together, or just a container of separate items that each belong in a different place.
            Keep together when the parts depend on each other or form one collection: a software project, \
            a website, an album or photo set from one event, a course pack, a game, a document with its attachments.
            Unpack when the items are unrelated or of different kinds, so each one can be filed on its own: \
            a folder of assorted downloads, a mix of bills, manuals and pictures, a film with only extras around it.
            When in doubt, keep it together.
            """
        let content = try await respond(instructions: instructions, schema: schema) { limit in
            Prompt { FactSummary.describe(facts, textLimit: min(limit, 500)) }
        }
        let together: String = (try? content.value(forProperty: "belongsTogether")) ?? "yes"
        let kind: String = (try? content.value(forProperty: "kind")) ?? ""
        let reason: String = (try? content.value(forProperty: "reason")) ?? ""
        let level: String = (try? content.value(forProperty: "confidence")) ?? "low"
        return UnpackSuggestion(unpack: together == "no", kind: kind,
                                confidence: Self.confidenceLevels[level] ?? 0.4, reason: reason)
    }

    // MARK: - Shared

    /// One fresh session per question, so files don't influence each other. Greedy sampling
    /// gives the same answer for the same file every time. If the text doesn't fit the
    /// context window, retries once with a shorter excerpt.
    private func respond(instructions: String, schema: GenerationSchema,
                         prompt: (Int) -> Prompt) async throws -> GeneratedContent {
        var limit = textLimit
        while true {
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(
                    to: prompt(limit), schema: schema, options: GenerationOptions(samplingMode: .greedy))
                return response.content
            } catch let error as LanguageModelError {
                switch error {
                case .contextSizeExceeded where limit > 500:
                    limit /= 3
                case .guardrailViolation, .refusal:
                    throw ClassifierError.declined("\(error)")
                default:
                    throw error
                }
            }
        }
    }

    static func instructions(folders: [FolderOption], review: String, corrections: [String] = []) -> String {
        let list = folders.map { folder in
            var line = "- \(folder.path)"
            if let purpose = folder.purpose { line += ": \(purpose)" }
            let examples = folder.examples.prefix(3).map { String($0.prefix(40)) }
            if !examples.isEmpty { line += " (holds e.g. \(examples.joined(separator: "; ")))" }
            return line
        }.joined(separator: "\n")
        var text = """
            You sort downloaded files into folders on a Mac. You only suggest; code checks your answer \
            and the owner can undo it.

            Folders, with what they're for and files already in them:
            \(list)

            Rules:
            - A folder fits only if its purpose matches what the file is. Compare with the files already in it.
            - Don't force a file into a folder because a word matches: a recipe is not a work document, \
            a phone manual is not school material.
            - If no folder's purpose matches what the file is, choose "none of these": a new folder will be made for it.
            - If you can't tell what the file is, choose \(review) with low confidence.
            - Suggest a new name only when the current name is unclear.
            """
        if !corrections.isEmpty {
            text += "\n\nThe owner corrected these earlier choices; don't repeat them:\n"
                + corrections.map { "- \($0)" }.joined(separator: "\n")
        }
        return text
    }

    // MARK: - What is this folder of yours for?

    public func describeFolder(_ profile: FolderProfile) async throws -> String {
        if let reason = Self.unavailableReason() { throw ClassifierError.unavailable(reason) }
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "FolderPurpose", properties: [
            .init(name: "purpose", description: "What kind of files belong in this folder, 2-8 words, plural (e.g. electricity and water bills, router and appliance manuals)",
                  schema: .init(type: String.self)),
        ]), dependencies: [])
        let instructions = """
            You describe a folder on a Mac so that new files can be matched to it. Say what kind of \
            files it holds, judging by the files themselves more than by the folder's name. Be specific \
            but general enough for similar future files. No dates, no file names.
            """
        var lines = ["Folder: \(profile.path)", "Files directly inside: \(profile.fileCount)"]
        let kinds = profile.kinds.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }
        if !kinds.isEmpty { lines.append("Kinds: \(kinds.joined(separator: ", "))") }
        if !profile.examples.isEmpty { lines.append("Examples: \(profile.examples.joined(separator: "; "))") }
        if !profile.sources.isEmpty { lines.append("Downloaded from: \(profile.sources.joined(separator: ", "))") }
        if profile.fileCount == 0 { lines.append("The folder is empty: go by its name and where it is.") }
        let summary = lines.joined(separator: "\n")
        let content = try await respond(instructions: instructions, schema: schema) { _ in Prompt { summary } }
        let purpose: String = try content.value(forProperty: "purpose")
        return purpose.trimmingCharacters(in: CharacterSet(charactersIn: " .\"'\n"))
    }
}

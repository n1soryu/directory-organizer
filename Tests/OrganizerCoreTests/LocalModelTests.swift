import Foundation
import Testing
@testable import OrganizerCore

/// A language model that plays back scripted outputs and records what it was asked.
/// The tests never load a real model (5 GB, ~1 min per decision); real runs are `organize model-check`.
final class ScriptedModel: LanguageModel, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [GenerationOutput]
    private(set) var requests: [GenerationRequest] = []

    init(_ outputs: [GenerationOutput]) {
        self.outputs = outputs
    }

    convenience init(answers: [String]) {
        self.init(answers.map { GenerationOutput(text: $0, hitTokenLimit: false) })
    }

    func continueChat(_ request: GenerationRequest) async throws -> GenerationOutput {
        try lock.withLock {
            requests.append(request)
            guard !outputs.isEmpty else { throw CancellationError() }
            return outputs.removeFirst()
        }
    }
}

struct ThinkingTextTests {
    @Test func splitsThinkingFromTheAnswer() {
        let (thinking, answer) = ThinkingText.split("<think>\nThe bill is from March.\n</think>\n\n{\"a\": 1}")
        #expect(thinking == "The bill is from March.")
        #expect(answer == "{\"a\": 1}")
    }

    @Test func noThinkingAtAll() {
        let (thinking, answer) = ThinkingText.split("  {\"a\": 1}\n")
        #expect(thinking == nil)
        #expect(answer == "{\"a\": 1}")
    }

    @Test func thinkingThatNeverClosedHasNoAnswer() {
        let (thinking, answer) = ThinkingText.split("<think>\nStill going")
        #expect(thinking == "Still going")
        #expect(answer.isEmpty)
    }

    @Test func emptyThinkingBlockFromThinkingOff() {
        let (thinking, answer) = ThinkingText.split("<think>\n\n</think>\n\n{}")
        #expect(thinking == "")
        #expect(answer == "{}")
    }
}

struct JSONAnswerTests {
    struct Card: Decodable, Sendable, Equatable { var reason: String; var kind: String; var issuer: String? }

    @Test func plainObject() throws {
        let card = try JSONAnswer.decode(Card.self, from: #"{"reason": "r", "kind": "bill", "issuer": null}"#)
        #expect(card == Card(reason: "r", kind: "bill", issuer: nil))
    }

    @Test func fencedObjectAfterThinking() throws {
        let answer = "<think>hm</think>\n```json\n{\"reason\": \"r\", \"kind\": \"bill\"}\n```"
        #expect(try JSONAnswer.decode(Card.self, from: answer).kind == "bill")
    }

    @Test func plainFenceToo() throws {
        #expect(try JSONAnswer.decode(Card.self, from: "```\n{\"reason\": \"r\", \"kind\": \"x\"}\n```").kind == "x")
    }

    @Test(arguments: [
        ("", "the answer is empty"),
        ("Sure! Here it is.", "the answer is not a single valid JSON object"),
        (#"{"reason": "r"} {"kind": "x"}"#, "the answer is not a single valid JSON object"),
        ("[1, 2]", "the answer is JSON but not an object"),
        (#"{"kind": "bill"}"#, #"the field "reason" is missing"#),
        (#"{"reason": "r", "kind": 3}"#, #"the field "kind" has the wrong type"#),
        (#"{"reason": "r", "kind": null}"#, #"the field "kind" is null"#),
    ])
    func rejected(answer: String, problem: String) {
        #expect(throws: JSONAnswer.Problem(problem)) { try JSONAnswer.decode(Card.self, from: answer) }
    }

    @Test func checkRejectsAValidButWrongAnswer() {
        #expect(throws: JSONAnswer.Problem("kind must not be empty")) {
            try JSONAnswer.decode(Card.self, from: #"{"reason": "r", "kind": ""}"#) {
                $0.kind.isEmpty ? "kind must not be empty" : nil
            }
        }
    }

    @Test func retryMessageWording() {
        #expect(JSONAnswer.retryMessage(for: .init("the answer is empty"))
                == "That answer is invalid: the answer is empty. Answer again with one JSON object only.")
    }
}

struct AskJSONTests {
    struct Answer: Decodable, Sendable { var reason: String; var day: Int }
    let question: [ChatMessage] = [.system("s"), .user("q")]

    @Test func validFirstTimeAsksOnce() async throws {
        let model = ScriptedModel(answers: [#"{"reason": "r", "day": 15}"#])
        let outcome = try await model.askJSON(Answer.self, messages: question, thinking: false)
        #expect(outcome.value?.day == 15)
        #expect(outcome.problems.isEmpty)
        #expect(model.requests.count == 1)
        #expect(model.requests[0].maxTokens == ReplyLimits().answerTokens)
        #expect(model.requests[0].thinking == false)
    }

    @Test func retriesWithTheProblemThenSucceeds() async throws {
        let model = ScriptedModel(answers: ["not json", #"{"reason": "r", "day": 15}"#])
        let outcome = try await model.askJSON(Answer.self, messages: question, thinking: false)
        #expect(outcome.value?.day == 15)
        #expect(outcome.problems == [.init("the answer is not a single valid JSON object")])
        // The second request carries the bad answer and the correction.
        let retry = model.requests[1].messages
        #expect(retry.count == 4)
        #expect(retry[2] == .assistant("not json"))
        #expect(retry[3] == .user("That answer is invalid: the answer is not a single valid JSON object. Answer again with one JSON object only."))
    }

    @Test func givesUpAfterTwoRetries() async throws {
        let model = ScriptedModel(answers: ["a", "b", "c", #"{"reason": "r", "day": 15}"#])
        let outcome = try await model.askJSON(Answer.self, messages: question, thinking: false)
        #expect(outcome.value == nil)
        #expect(outcome.problems.count == 3)
        #expect(model.requests.count == 3)
    }

    @Test func checkFailuresAreRetriedToo() async throws {
        let model = ScriptedModel(answers: [#"{"reason": "r", "day": 14}"#, #"{"reason": "r", "day": 15}"#])
        let outcome = try await model.askJSON(Answer.self, messages: question, thinking: false) {
            $0.day == 15 ? nil : "the day is wrong"
        }
        #expect(outcome.value?.day == 15)
        #expect(outcome.problems == [.init("the day is wrong")])
    }

    @Test func onlyTheAnswerGoesBackNotTheThinking() async throws {
        let model = ScriptedModel(answers: ["<think>secret</think>oops", #"{"reason": "r", "day": 15}"#])
        _ = try await model.askJSON(Answer.self, messages: question, thinking: true)
        #expect(model.requests[1].messages[2] == .assistant("oops"))
    }

    @Test func modelErrorsAreThrownNotRetried() async {
        let model = ScriptedModel([])
        await #expect(throws: CancellationError.self) {
            _ = try await model.askJSON(Answer.self, messages: question, thinking: false)
        }
    }
}

/// Budget forcing: when thinking runs out of tokens, it's closed and the model answers.
struct ThinkingBudgetTests {
    let limits = ReplyLimits(thinkingTokens: 100, answerTokens: 20)

    @Test func thinkingWithinTheCapIsOneCall() async throws {
        let model = ScriptedModel([GenerationOutput(text: "<think>ok</think>\n{}", hitTokenLimit: false, generatedTokens: 50, seconds: 2)])
        let reply = try await model.reply(to: [.user("q")], thinking: true, limits: limits)
        #expect(reply == ModelReply(thinking: "ok", answer: "{}", thinkingWasCapped: false, generatedTokens: 50, seconds: 2))
        #expect(model.requests.map(\.maxTokens) == [100])
    }

    @Test func cappedThinkingIsClosedAndAnswered() async throws {
        let model = ScriptedModel([
            GenerationOutput(text: "<think>\nlong thoughts", hitTokenLimit: true, generatedTokens: 100, seconds: 4),
            GenerationOutput(text: "{\"a\": 1}", hitTokenLimit: false, generatedTokens: 8, seconds: 1),
        ])
        let reply = try await model.reply(to: [.user("q")], thinking: true, limits: limits)
        #expect(reply.thinkingWasCapped)
        #expect(reply.thinking == "long thoughts")
        #expect(reply.answer == "{\"a\": 1}")
        #expect(reply.generatedTokens == 108)
        #expect(reply.seconds == 5)
        let second = model.requests[1]
        #expect(second.prefix == "<think>\nlong thoughts\n</think>\n\n")
        #expect(second.maxTokens == 20)
        #expect(second.messages == [.user("q")])
        #expect(second.thinking)
    }

    @Test func answerCutOffAfterThinkingIsFinishedNotReclosed() async throws {
        let model = ScriptedModel([
            GenerationOutput(text: "<think>t</think>\n{\"a\":", hitTokenLimit: true),
            GenerationOutput(text: " 1}", hitTokenLimit: false),
        ])
        let reply = try await model.reply(to: [.user("q")], thinking: true, limits: limits)
        #expect(!reply.thinkingWasCapped)
        #expect(reply.answer == "{\"a\": 1}")
        #expect(model.requests[1].prefix == "<think>t</think>\n{\"a\":")
    }

    @Test func thinkingOffNeverContinues() async throws {
        let model = ScriptedModel([GenerationOutput(text: "{\"a\":", hitTokenLimit: true)])
        let reply = try await model.reply(to: [.user("q")], thinking: false, limits: limits)
        #expect(reply.answer == "{\"a\":")
        #expect(model.requests.map(\.maxTokens) == [20])
    }
}

struct ModelStoreTests {
    let store = ModelStore(directory: FileManager.default.temporaryDirectory.appending(path: "models-\(UUID().uuidString)"))

    @Test func modelsArePinnedToCommits() {
        for spec in ModelSpec.all {
            #expect(spec.revision.count == 40 && spec.revision.allSatisfy(\.isHexDigit), "\(spec.repo) isn't pinned")
        }
        #expect(ModelSpec.language.repo == "mlx-community/Qwen3-8B-4bit-DWQ")
        #expect(ModelSpec.embedder.repo == "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ")
        #expect(ModelSpec.all.filter(\.role.isLarge).count == 1)
    }

    @Test func readyOnlyWithMarkerAndFiles() throws {
        let spec = ModelSpec.embedder
        #expect(!store.isReady(spec))
        // Files alone (a download that didn't finish) aren't enough.
        try FileManager.default.createDirectory(at: store.snapshotDirectory(for: spec), withIntermediateDirectories: true)
        #expect(!store.isReady(spec))
        try store.markReady(spec)
        #expect(store.isReady(spec))
        #expect(store.missing() == [.language])
        // Someone deleted the files: no longer ready.
        try FileManager.default.removeItem(at: store.directory.appending(path: "models--mlx-community--Qwen3-Embedding-0.6B-4bit-DWQ"))
        #expect(!store.isReady(spec))
    }

    @Test func snapshotPathMatchesTheHubLayout() {
        #expect(store.snapshotDirectory(for: .language).path.hasSuffix(
            "models--mlx-community--Qwen3-8B-4bit-DWQ/snapshots/abdc7a619e12b13119e292c889ebf8e90f4ef592"))
    }

    @Test func availableSpaceForAFolderThatDoesntExistYet() {
        #expect((store.availableBytes() ?? 0) > 0)
    }

    @Test func spaceCheckKeepsAMargin() {
        let gb: Int64 = 1_000_000_000
        #expect(SpaceCheck.check(needed: 5 * gb, available: 7 * gb) == .enough)
        #expect(SpaceCheck.check(needed: 5 * gb, available: 6 * gb) == .enough)
        #expect(SpaceCheck.check(needed: 5 * gb, available: 5 * gb) == .short(by: gb))
        #expect(SpaceCheck.check(needed: 5 * gb, available: nil) == .unknown)
    }
}

import Foundation

/// One turn of a chat with a local model.
public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant }

    public var role: Role
    public var content: String

    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> ChatMessage { .init(.system, content) }
    public static func user(_ content: String) -> ChatMessage { .init(.user, content) }
    public static func assistant(_ content: String) -> ChatMessage { .init(.assistant, content) }
}

/// One raw generation: the chat's prompt, then `prefix` as the start of the model's turn,
/// continued for at most `maxTokens` tokens.
public struct GenerationRequest: Sendable, Equatable {
    public var messages: [ChatMessage]
    /// Qwen3's thinking switch (`enable_thinking` in its chat template).
    public var thinking: Bool
    /// Text the model's turn already starts with. Empty for a fresh answer.
    public var prefix: String
    public var maxTokens: Int
    /// An image the model sees with the first user message (vision models only).
    public var image: URL?

    public init(messages: [ChatMessage], thinking: Bool, prefix: String = "", maxTokens: Int, image: URL? = nil) {
        self.messages = messages
        self.thinking = thinking
        self.prefix = prefix
        self.maxTokens = maxTokens
        self.image = image
    }
}

public struct GenerationOutput: Sendable, Equatable {
    /// What the model wrote after the prefix, thinking included.
    public var text: String
    /// It stopped because it ran out of tokens, not because it was done.
    public var hitTokenLimit: Bool
    public var promptTokens: Int
    public var generatedTokens: Int
    public var seconds: Double

    public init(text: String, hitTokenLimit: Bool, promptTokens: Int = 0, generatedTokens: Int = 0, seconds: Double = 0) {
        self.text = text
        self.hitTokenLimit = hitTokenLimit
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.seconds = seconds
    }
}

/// A local language model. Implemented with MLX in OrganizerMLX; faked in tests,
/// so they need neither the GPU nor the 5 GB of models. A vision model is one too:
/// its requests carry an image.
public protocol LanguageModel: Sendable {
    func continueChat(_ request: GenerationRequest) async throws -> GenerationOutput
}

/// A local embedding model: text in, a unit-length vector out.
public protocol TextEmbedder: Sendable {
    func embed(_ text: String) async throws -> [Float]
}

/// How long a reply may get. The benchmark's decisions twice hit 4,096 thinking tokens.
public struct ReplyLimits: Sendable, Equatable {
    public var thinkingTokens: Int
    public var answerTokens: Int

    public init(thinkingTokens: Int = 4_096, answerTokens: Int = 512) {
        self.thinkingTokens = thinkingTokens
        self.answerTokens = answerTokens
    }
}

/// A finished reply, with the thinking separated from the answer.
public struct ModelReply: Sendable, Equatable {
    public var thinking: String?
    public var answer: String
    /// The thinking ran out of tokens and was closed for the model ("budget forcing").
    public var thinkingWasCapped: Bool
    public var generatedTokens: Int
    public var seconds: Double
}

/// Qwen3 writes its thinking inline as `<think>…</think>` before the answer.
public enum ThinkingText {
    static let open = "<think>"
    static let close = "</think>"

    /// Splits raw output into thinking and answer. An unclosed `<think>` means there's no answer yet.
    public static func split(_ text: String) -> (thinking: String?, answer: String) {
        if let end = text.range(of: close, options: .backwards) {
            var thinking = String(text[..<end.lowerBound])
            if let start = thinking.range(of: open) { thinking = String(thinking[start.upperBound...]) }
            return (trimmed(thinking), trimmed(String(text[end.upperBound...])))
        }
        if let start = text.range(of: open) {
            return (trimmed(String(text[start.upperBound...])), "")
        }
        return (nil, trimmed(text))
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension LanguageModel {
    /// Asks for one reply. With thinking on, the thinking gets `limits.thinkingTokens`; if that
    /// runs out mid-thought, the thinking is closed for the model and it answers from there
    /// ("budget forcing"), instead of the whole minute-long call being wasted.
    public func reply(to messages: [ChatMessage], thinking: Bool, limits: ReplyLimits = .init()) async throws -> ModelReply {
        let first = try await continueChat(GenerationRequest(
            messages: messages, thinking: thinking,
            maxTokens: thinking ? limits.thinkingTokens : limits.answerTokens))
        guard thinking, first.hitTokenLimit else {
            return Self.reply(from: first.text, capped: false, outputs: [first])
        }
        // Out of tokens: either still thinking (close it) or already answering (let it finish).
        let stillThinking = !first.text.contains(ThinkingText.close)
        let prefix = stillThinking ? first.text + "\n\(ThinkingText.close)\n\n" : first.text
        let second = try await continueChat(GenerationRequest(
            messages: messages, thinking: thinking, prefix: prefix, maxTokens: limits.answerTokens))
        return Self.reply(from: prefix + second.text, capped: stillThinking, outputs: [first, second])
    }

    private static func reply(from text: String, capped: Bool, outputs: [GenerationOutput]) -> ModelReply {
        let (thinking, answer) = ThinkingText.split(text)
        return ModelReply(thinking: thinking, answer: answer, thinkingWasCapped: capped,
                          generatedTokens: outputs.reduce(0) { $0 + $1.generatedTokens },
                          seconds: outputs.reduce(0) { $0 + $1.seconds })
    }
}

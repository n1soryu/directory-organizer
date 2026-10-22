import Foundation

/// Reading a model's JSON answer leniently, and asking again when it's wrong.
/// The benchmark's answers were valid JSON on the first try without forcing a format,
/// so there's no grammar here: just tolerance for a ```json fence and a short retry loop.
public enum JSONAnswer {
    /// Why an answer was rejected, worded for the model ("That answer is invalid: …").
    public struct Problem: Error, Sendable, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// The single JSON object in an answer. Leftover thinking and whitespace are dropped,
    /// and one ```json (or plain ```) fence around it is accepted.
    public static func object(in answer: String) throws(Problem) -> Data {
        var text = ThinkingText.split(answer).answer
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            if lines.count >= 2, lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
                lines.removeFirst()
                lines.removeLast()
                text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !text.isEmpty else { throw Problem("the answer is empty") }
        let data = Data(text.utf8)
        guard let value = try? JSONSerialization.jsonObject(with: data) else {
            throw Problem("the answer is not a single valid JSON object")
        }
        guard value is [String: Any] else { throw Problem("the answer is JSON but not an object") }
        return data
    }

    /// Decodes an answer into `T`, then applies `check` (which returns a problem, or nil if fine).
    public static func decode<T: Decodable>(_ type: T.Type, from answer: String,
                                            check: (T) -> String? = { _ in nil }) throws(Problem) -> T {
        let data = try object(in: answer)
        let value: T
        do {
            value = try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            throw Problem(describe(error))
        } catch {
            throw Problem("the answer doesn't match the format")
        }
        if let problem = check(value) { throw Problem(problem) }
        return value
    }

    static func describe(_ error: DecodingError) -> String {
        func field(_ path: [CodingKey], _ key: CodingKey? = nil) -> String {
            let names = (path + (key.map { [$0] } ?? [])).map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return "\"" + names.joined(separator: ".").replacingOccurrences(of: ".[", with: "[") + "\""
        }
        switch error {
        case .keyNotFound(let key, let context): return "the field \(field(context.codingPath, key)) is missing"
        case .typeMismatch(_, let context): return "the field \(field(context.codingPath)) has the wrong type"
        case .valueNotFound(_, let context): return "the field \(field(context.codingPath)) is null"
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "the answer is not valid JSON" : "the field \(field(context.codingPath)) has an invalid value"
        @unknown default: return "the answer doesn't match the format"
        }
    }

    /// The message sent back when an answer is rejected.
    public static func retryMessage(for problem: Problem) -> String {
        "That answer is invalid: \(problem). Answer again with one JSON object only."
    }

    /// The outcome of `ask`: the value, or nil when every attempt was invalid
    /// (the caller then does the safe thing, like leaving the file to wait).
    public struct Outcome<T: Sendable>: Sendable {
        public var value: T?
        public var replies: [ModelReply]
        /// One per rejected answer, in order.
        public var problems: [Problem]
    }
}

extension LanguageModel {
    /// Asks for a JSON answer, and up to `retries` more times if it's invalid, each time telling
    /// the model what was wrong. Errors from the model itself (not loaded, cancelled) are thrown.
    public func askJSON<T: Decodable & Sendable>(
        _ type: T.Type, messages: [ChatMessage], thinking: Bool, limits: ReplyLimits = .init(),
        retries: Int = 2, check: @Sendable (T) -> String? = { _ in nil }
    ) async throws -> JSONAnswer.Outcome<T> {
        var conversation = messages
        var outcome = JSONAnswer.Outcome<T>(value: nil, replies: [], problems: [])
        for attempt in 0...retries {
            try Task.checkCancellation()
            let reply = try await reply(to: conversation, thinking: thinking, limits: limits)
            outcome.replies.append(reply)
            do {
                outcome.value = try JSONAnswer.decode(T.self, from: reply.answer, check: check)
                return outcome
            } catch {
                outcome.problems.append(error)
                guard attempt < retries else { break }
                // Only the answer goes back into the chat; Qwen3's template drops old thinking anyway.
                conversation += [.assistant(reply.answer), .user(JSONAnswer.retryMessage(for: error))]
            }
        }
        return outcome
    }
}

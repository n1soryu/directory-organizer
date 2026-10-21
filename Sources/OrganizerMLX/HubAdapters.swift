import Foundation
import HuggingFace
import MLXLMCommon
import OrganizerCore
import Tokenizers

// The two bridges MLX needs to reach Hugging Face. mlx-swift-lm offers them as macros
// (#hubDownloader, #huggingFaceTokenizerLoader); writing them out by hand avoids compiling
// swift-syntax and needing -skipMacroValidation. They mirror what those macros generate.

enum HubDownloaderError: LocalizedError {
    case invalidRepository(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepository(let id): "\"\(id)\" isn't a Hugging Face repository name"
        }
    }
}

/// Fetches model files into the app's model folder.
/// With `localOnly`, it never touches the network: loading for Organize Now uses that,
/// so only the "Download models" action ever downloads.
struct HubDownloader: MLXLMCommon.Downloader {
    let client: HubClient
    let localOnly: Bool

    init(store: ModelStore, localOnly: Bool) {
        client = HubClient(cache: HubCache(cacheDirectory: store.directory))
        self.localOnly = localOnly
    }

    func download(id: String, revision: String?, matching patterns: [String], useLatest: Bool,
                  progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else { throw HubDownloaderError.invalidRepository(id) }
        return try await client.downloadSnapshot(
            of: repo, revision: revision ?? "main", matching: patterns, localFilesOnly: localOnly,
            progressHandler: { @MainActor progress in progressHandler(progress) })
    }
}

/// Loads a model's tokenizer with swift-transformers.
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers calls it `decode(tokens:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

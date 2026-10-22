import Foundation
import MLX
import MLXEmbedders
import MLXLLM
import MLXLMCommon
import OrganizerCore

public enum MLXEngineError: LocalizedError, Equatable {
    case notDownloaded(String)
    case noShaders

    public var errorDescription: String? {
        switch self {
        case .notDownloaded(let name): "\(name) isn't downloaded yet (Settings → Download Models)"
        case .noShaders: "MLX's GPU shaders are missing (they're only built when full Xcode with its Metal toolchain is installed)"
        }
    }
}

/// How much GPU memory MLX holds, in bytes.
public struct GPUMemory: Sendable {
    public var active: Int
    public var cache: Int
    public var peak: Int
}

/// The only way into the GPU. One actor means one model runs at a time, and the memory rule
/// holds: at most one large model is loaded (loading another replaces it); the small embedder
/// may stay loaded next to it. Models are only read from the model folder, never downloaded here.
public actor MLXEngine: OrganizerCore.LanguageModel, OrganizerCore.TextEmbedder {
    public let store: ModelStore
    private var language: (spec: ModelSpec, container: ModelContainer)?
    private var embedder: (spec: ModelSpec, container: EmbedderModelContainer)?

    public init(store: ModelStore = ModelStore()) {
        self.store = store
    }

    /// Whether MLX will find its compiled shaders. Without them its first GPU call aborts the
    /// whole program (a build without Xcode's Metal toolchain has none), so this is checked
    /// before any model is loaded.
    /// The places mirror MLX's own search: next to the executable, or a bundle the app can see.
    public static let shadersAvailable: Bool = {
        let fm = FileManager.default
        let bundle = "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
        var folders = [Bundle.main.bundleURL, Bundle.main.resourceURL].compactMap { $0 }
        folders += Bundle.allBundles.compactMap(\.resourceURL)
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            if fm.fileExists(atPath: executable.appending(path: "mlx.metallib").path) { return true }
            folders.append(executable)
        }
        return folders.contains { fm.fileExists(atPath: $0.appending(path: bundle).path) }
    }()

    /// nil if `spec` can run here; otherwise why not, in plain words.
    public static func unavailableReason(_ spec: ModelSpec = .language, store: ModelStore = ModelStore()) -> String? {
        if !shadersAvailable { return MLXEngineError.noShaders.localizedDescription }
        if !store.isReady(spec) { return MLXEngineError.notDownloaded(spec.displayName).localizedDescription }
        return nil
    }

    public var loaded: [ModelSpec] {
        [language?.spec, embedder?.spec].compactMap { $0 }
    }

    /// Loads a downloaded model. A large model replaces the large one already loaded.
    public func load(_ spec: ModelSpec) async throws {
        guard !loaded.contains(spec) else { return }
        guard Self.shadersAvailable else { throw MLXEngineError.noShaders }
        guard store.isReady(spec) else { throw MLXEngineError.notDownloaded(spec.displayName) }
        let downloader = HubDownloader(store: store, localOnly: true)
        let configuration = ModelConfiguration(id: spec.repo, revision: spec.revision)
        switch spec.role {
        case .language:
            unload(.language)
            let container = try await LLMModelFactory.shared.loadContainer(
                from: downloader, using: TransformersTokenizerLoader(), configuration: configuration)
            language = (spec, container)
        case .embedder:
            unload(.embedder)
            let container = try await EmbedderModelFactory.shared.loadContainer(
                from: downloader, using: TransformersTokenizerLoader(), configuration: configuration)
            embedder = (spec, container)
        }
    }

    public func unload(_ role: ModelSpec.Role) {
        switch role {
        case .language: language = nil
        case .embedder: embedder = nil
        }
        if Self.shadersAvailable { Memory.clearCache() }  // touching MLX without shaders would abort
    }

    /// Releases everything (the end of Organize Now).
    public func unloadAll() {
        language = nil
        embedder = nil
        if Self.shadersAvailable { Memory.clearCache() }  // touching MLX without shaders would abort
    }

    public nonisolated func memory() -> GPUMemory {
        let snapshot = Memory.snapshot()
        return GPUMemory(active: snapshot.activeMemory, cache: snapshot.cacheMemory, peak: snapshot.peakMemory)
    }

    /// Starts a new peak measurement.
    public nonisolated func resetPeakMemory() {
        Memory.peakMemory = 0  // the value is ignored: setting it resets the peak
    }

    // MARK: - LanguageModel

    public func continueChat(_ request: GenerationRequest) async throws -> GenerationOutput {
        // Loaded on first use (Organize Now's model phase); `unloadAll()` releases it.
        if language == nil { try await load(.language) }
        guard let container = language?.container else { throw MLXEngineError.notDownloaded(ModelSpec.language.displayName) }
        let start = Date()
        return try await container.perform { context in
            // UserInput isn't Sendable, so it's built here, inside the container.
            let chat: [Chat.Message] = request.messages.map {
                switch $0.role {
                case .system: .system($0.content)
                case .user: .user($0.content)
                case .assistant: .assistant($0.content)
                }
            }
            let input = UserInput(chat: chat, additionalContext: ["enable_thinking": request.thinking])
            var prepared = try await context.processor.prepare(input: input)
            if !request.prefix.isEmpty {
                // Continue a turn the model already started: prompt tokens + the prefix's tokens.
                var extra = MLXArray(context.tokenizer.encode(text: request.prefix, addSpecialTokens: false))
                    .asType(prepared.text.tokens.dtype)
                if prepared.text.tokens.ndim == 2 { extra = extra.expandedDimensions(axis: 0) }
                prepared = LMInput(tokens: concatenated([prepared.text.tokens, extra], axis: -1))
            }
            let promptTokens = prepared.text.tokens.size
            // Greedy, as in the benchmark (11/12 decisions with these settings).
            let parameters = GenerateParameters(maxTokens: request.maxTokens, temperature: 0)
            var text = ""
            var info: GenerateCompletionInfo?
            for await event in try MLXLMCommon.generate(input: prepared, parameters: parameters, context: context) {
                switch event {
                case .chunk(let chunk): text += chunk
                case .info(let completion): info = completion
                default: break
                }
            }
            try Task.checkCancellation()
            return GenerationOutput(
                text: text, hitTokenLimit: info?.stopReason == .length,
                promptTokens: info?.promptTokenCount ?? promptTokens,
                generatedTokens: info?.generationTokenCount ?? 0,
                seconds: Date().timeIntervalSince(start))
        }
    }

    // MARK: - TextEmbedder

    public func embed(_ text: String) async throws -> [Float] {
        if embedder == nil { try await load(.embedder) }
        guard let container = embedder?.container else { throw MLXEngineError.notDownloaded(ModelSpec.embedder.displayName) }
        return await container.perform { context in
            var tokens = context.tokenizer.encode(text: text, addSpecialTokens: true)
            // Qwen3-Embedding pools the last token, which must be the end-of-text token.
            if let eos = context.tokenizer.eosTokenId, tokens.last != eos { tokens.append(eos) }
            let input = MLXArray(tokens).expandedDimensions(axis: 0)
            let mask = MLXArray.ones([1, tokens.count])
            let hidden = context.model(input, positionIds: nil, tokenTypeIds: nil, attentionMask: mask)
            let pooled = context.pooling(hidden, mask: mask, normalize: true)
            pooled.eval()
            return pooled[0].asArray(Float.self)
        }
    }
}

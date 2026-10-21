import Foundation
import OrganizerCore
import OrganizerMLX

/// `organize model-check [--download]`: loads each model and runs one short, built-in sample,
/// to test MLX outside the app. The samples are made up here, never taken from the test or
/// evaluation data, and they don't shape any prompt the organizer uses.
func runModelCheck(download: Bool) async {
    let store = ModelStore()
    print("Models folder: \(store.directory.path)")

    let missing = store.missing()
    if !missing.isEmpty {
        guard download else {
            fail("not downloaded: \(missing.map(\.displayName).joined(separator: ", ")). Download them in the app (Settings → Download Models), or run model-check --download.")
        }
        do {
            try await ModelDownloader(store: store).downloadMissing { spec, fraction in
                ModelCheckProgress.show(spec, fraction)
            }
        } catch {
            fail("download failed: \(error.localizedDescription)")
        }
    }

    print("GPU: \(OrganizerMLX.GPUCheck.run() == 30 ? "ok" : "wrong result")")
    let engine = MLXEngine(store: store)
    var failures = 0

    // 1. A card-style answer, thinking off.
    struct Card: Decodable, Sendable { var reason: String; var kind: String; var issuer: String?; var date: String? }
    failures += await check("Card, thinking off", engine: engine, spec: .language) {
        let outcome = try await engine.askJSON(Card.self, messages: [
            .system("You describe downloaded files. Answer with one JSON object only."),
            .user("""
                File name: scan0042.pdf
                Text: "Riverside Public Library. Your library card expires on 30 November 2026. \
                Renew it at any branch with proof of address."
                Answer as {"reason": string, "kind": string, "issuer": string or null, "date": "YYYY-MM-DD" or null}.
                """),
        ], thinking: false)
        return (outcome.value.map { "kind: \($0.kind); issuer: \($0.issuer ?? "–"); date: \($0.date ?? "–")" }, outcome)
    }

    // 2. A short question with thinking on: exercises <think> stripping and the thinking cap.
    struct Sum: Decodable, Sendable { var reason: String; var day: Int }
    failures += await check("Question, thinking on", engine: engine, spec: .language) {
        let outcome = try await engine.askJSON(Sum.self, messages: [
            .user("""
                One file was downloaded on 3 March, another 12 days later. On which day of March was the second one downloaded?
                Answer with one JSON object: {"reason": string, "day": number}.
                """),
        ], thinking: true, limits: ReplyLimits(thinkingTokens: 1_024, answerTokens: 256)) { $0.day == 15 ? nil : "the day is wrong" }
        return (outcome.value.map { "day \($0.day)" }, outcome)
    }
    await engine.unload(.language)

    // 3. Embeddings: two related sentences should be closer than an unrelated one.
    do {
        print("\nEmbeddings (\(ModelSpec.embedder.displayName))")
        engine.resetPeakMemory()
        let loadStart = Date()
        try await engine.load(.embedder)
        print("  loaded in \(seconds(since: loadStart))")
        _ = try await engine.embed("warm-up")  // the first call compiles GPU kernels; don't time it
        let start = Date()
        let a = try await engine.embed("kind: electricity bill; issuer: city power company; subject: March usage")
        let b = try await engine.embed("kind: gas bill; issuer: regional gas supplier; subject: winter heating")
        let c = try await engine.embed("kind: holiday photo; subject: a beach at sunset")
        let near = cosine(a, b), far = cosine(a, c)
        let perText = Date().timeIntervalSince(start) / 3
        print("  \(a.count) numbers per vector, \(Int(perText * 1000)) ms per text")
        print("  bill ↔ bill \(String(format: "%.2f", near)), bill ↔ photo \(String(format: "%.2f", far))")
        if a.count != 1_024 || near <= far {
            print("  ✗ unexpected result"); failures += 1
        } else {
            print("  ✓ ok")
        }
        print("  peak GPU memory \(gigabytes(engine.memory().peak))")
    } catch {
        print("  ✗ \(error.localizedDescription)"); failures += 1
    }
    await engine.unloadAll()

    print(failures == 0 ? "\nAll model checks passed." : "\n\(failures) model check(s) failed.")
    exit(failures == 0 ? 0 : 1)
}

/// Runs one language-model sample and prints what happened. Returns 1 on failure.
private func check<T: Sendable>(_ title: String, engine: MLXEngine, spec: ModelSpec,
                                _ body: () async throws -> (String?, JSONAnswer.Outcome<T>)) async -> Int {
    print("\n\(title) (\(spec.displayName))")
    do {
        if await !engine.loaded.contains(spec) {
            engine.resetPeakMemory()
            let loadStart = Date()
            try await engine.load(spec)
            print("  loaded in \(seconds(since: loadStart))")
        }
        let (summary, outcome) = try await body()
        for (index, reply) in outcome.replies.enumerated() {
            let rate = reply.seconds > 0 ? Double(reply.generatedTokens) / reply.seconds : 0
            var line = "  try \(index + 1): \(reply.generatedTokens) tokens in \(String(format: "%.1f", reply.seconds)) s (\(String(format: "%.1f", rate)) tok/s)"
            if let thinking = reply.thinking { line += ", thought \(thinking.count) characters" }
            if reply.thinkingWasCapped { line += ", thinking capped" }
            print(line)
            if index < outcome.problems.count { print("    rejected: \(outcome.problems[index])") }
        }
        print("  peak GPU memory \(gigabytes(engine.memory().peak))")
        guard let summary else {
            print("  ✗ no valid answer after \(outcome.replies.count) tries"); return 1
        }
        print("  ✓ \(summary)")
        return 0
    } catch {
        print("  ✗ \(error.localizedDescription)"); return 1
    }
}

@MainActor private enum ModelCheckProgress {
    static var last: [String: Int] = [:]

    static func show(_ spec: ModelSpec, _ fraction: Double) {
        let percent = Int(fraction * 100)
        guard last[spec.id] != percent else { return }
        last[spec.id] = percent
        FileHandle.standardError.write(Data("\rDownloading \(spec.displayName): \(percent)%   \(percent == 100 ? "\n" : "")".utf8))
    }
}

private func cosine(_ a: [Float], _ b: [Float]) -> Float {
    // The vectors are unit length, so the dot product is the cosine.
    zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
}

private func seconds(since start: Date) -> String {
    String(format: "%.1f s", Date().timeIntervalSince(start))
}

private func gigabytes(_ bytes: Int) -> String {
    String(format: "%.1f GB", Double(bytes) / 1e9)
}

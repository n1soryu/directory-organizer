import Foundation
import OrganizerCore
import OrganizerMLX
import TestDataKit

/// `organize eval`: the benchmark's test set (TestDataKit's `BenchmarkCorpus`) and C's image set,
/// run through the app's own code, scored by the benchmark's rules and compared with its numbers
/// (docs/mlx-plan.md, Milestone F). Everything happens in a new temporary folder; the results
/// are saved in eval-results/<date>.json, so each run can be compared with the last one.
enum EvalPart: String, CaseIterable, Codable {
    case cards, decisions, embeddings, images, pipeline

    /// The pipeline takes longest (the whole Planner per file), so it only runs when asked.
    static let standard: [EvalPart] = [.cards, .decisions, .embeddings, .images]
}

/// Counts what the model did between two `take()`s: questions, retries after an invalid answer,
/// thinking that ran out of tokens, tokens and time.
actor Recorder: LanguageModel {
    struct Tally: Codable {
        var asks = 0
        var retries = 0
        var continued = 0
        var tokens = 0
        var seconds = 0.0
    }

    let base: any LanguageModel
    private var tally = Tally()

    init(_ base: any LanguageModel) {
        self.base = base
    }

    func continueChat(_ request: GenerationRequest) async throws -> GenerationOutput {
        let output = try await base.continueChat(request)
        if !request.prefix.isEmpty {
            tally.continued += 1  // the thinking ran out of tokens and was closed (budget forcing)
        } else if request.messages.last?.content.hasPrefix("That answer is invalid") == true {
            tally.retries += 1    // JSONAnswer.retryMessage
        } else {
            tally.asks += 1
        }
        tally.tokens += output.generatedTokens
        tally.seconds += output.seconds
        return output
    }

    func take() -> Tally {
        defer { tally = Tally() }
        return tally
    }
}

/// One run's results, as saved in eval-results/<date>.json.
struct EvalReport: Codable {
    struct Cards: Codable {
        var total = 0, kinds = 0, issuers = 0, firstTry = 0
        var secondsPerFile = 0.0, tokensPerSecond = 0.0, peakGB = 0.0
        var rows: [String: String] = [:]
    }

    struct Decisions: Codable {
        var right = 0, partly = 0, wrong = 0, firstTry = 0, continued = 0
        var secondsPerDecision = 0.0, tokensPerSecond = 0.0, peakGB = 0.0
        var marks: [String: String] = [:]
        var answers: [String: String] = [:]
    }

    struct Embeddings: Codable {
        var total = 0, recallAt3 = 0
        var averageTop1: Float = 0, lowestTop1: Float = 0
        var noMatchTop1: [String: Float] = [:]
        var millisecondsPerEmbedding = 0.0
        var top3: [String: [String]] = [:]
    }

    struct Images: Codable {
        var total = 0, kinds = 0, facts = 0, names = 0, rightWay = 0, firstTry = 0
        var secondsPerImage = 0.0, peakGB = 0.0
    }

    struct Pipeline: Codable {
        var right = 0, partly = 0, wrong = 0, neighboursInTop5 = 0, withNeighbours = 0
        var secondsPerFile = 0.0, peakGB = 0.0
        var marks: [String: String] = [:]
        var outcomes: [String: String] = [:]
    }

    var date = Date()
    var languageModel = ModelSpec.language.id
    var visionModel = ModelSpec.vision.id
    var embedder = ModelSpec.embedder.id
    var cards: Cards?
    var decisions: Decisions?
    var embeddings: Embeddings?
    var images: Images?
    var pipeline: Pipeline?
}

func runEval(parts: [EvalPart], scenarios only: Set<String>?, download: Bool) async {
    // Line by line, so a long run can be followed in a log file.
    setvbuf(stdout, nil, _IOLBF, 0)
    let store = ModelStore()
    let needed: [ModelSpec] = [.language, .embedder] + (parts.contains(.images) ? [.vision] : [])
    let missing = store.missing(needed)
    if !missing.isEmpty {
        guard download else {
            fail("not downloaded: \(missing.map(\.displayName).joined(separator: ", ")). Run eval --download (once).")
        }
        do {
            try await ModelDownloader(store: store).downloadMissing(missing) { spec, fraction in
                ModelCheckProgress.show(spec, fraction)
            }
        } catch {
            fail("download failed: \(error.localizedDescription)")
        }
    }
    for spec in needed {
        if let reason = MLXEngine.unavailableReason(spec, store: store) { fail("the models can't run: \(reason)") }
    }

    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    // The real path (/private/var/…, not the /var/… symlink): the Planner lists folders by their real
    // path, and the catalog's paths must match it, or waiting files aren't recognised as waiting.
    // (Foundation's resolvingSymlinksInPath strips /private again, so realpath.)
    let temporary = FileManager.default.temporaryDirectory
    let real = realpath(temporary.path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) }
    let root = (real.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? temporary).appending(path: "organizer-eval-\(stamp)")
    let awake = KeepAwake(reason: "organize eval: running the on-device models")
    defer { awake.end() }

    let engine = MLXEngine(store: store)
    let recorder = Recorder(engine)
    let classifier = MLXClassifier(model: recorder)
    var report = EvalReport()
    var eval = CorpusEval(root: root, engine: engine, recorder: recorder, classifier: classifier)
    if let only { eval.scenarios = BenchmarkCorpus.scenarios.filter { only.contains($0.id) } }
    do {
        try await eval.prepare()
    } catch {
        fail("couldn't write the test files: \(error.localizedDescription)")
    }
    print("Test files: \(root.path)")

    // The 8B first (cards, decisions), then the embedder, then the vision model (it takes the
    // 8B's place in memory), then the pipeline (8B and embedder again).
    let needsCards = parts.contains(.cards) || parts.contains(.embeddings) || parts.contains(.pipeline)
    if needsCards { report.cards = await eval.cards() }
    if parts.contains(.decisions) { report.decisions = await eval.decisions() }
    await engine.unload(.language)
    if parts.contains(.embeddings) { report.embeddings = await eval.embeddings() }
    if parts.contains(.images) { report.images = await evalImages(engine: engine, folder: root.appending(path: "images")) }
    if parts.contains(.pipeline) { report.pipeline = await eval.pipeline() }
    await engine.unloadAll()

    let previous = EvalReport.latest()
    report.printSummary(previous: previous)
    do {
        let file = try report.save()
        print("\nSaved: \(file.path)")
    } catch {
        print("\ncouldn't save the results: \(error.localizedDescription)")
    }
}

/// The 27 text files of the benchmark, written into `root/corpus`.
struct CorpusEval {
    let root: URL
    let engine: MLXEngine
    let recorder: Recorder
    let classifier: MLXClassifier
    var facts: [String: FileFacts] = [:]
    var cards: [String: FileCard] = [:]
    /// All 12, or the ones asked for (`--scenarios`).
    var scenarios = BenchmarkCorpus.scenarios

    var corpus: URL { root.appending(path: "corpus") }

    init(root: URL, engine: MLXEngine, recorder: Recorder, classifier: MLXClassifier) {
        self.root = root
        self.engine = engine
        self.recorder = recorder
        self.classifier = classifier
    }

    mutating func prepare() async throws {
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        for (id, name) in BenchmarkCorpus.allFiles {
            let url = corpus.appending(path: name)
            try Data(BenchmarkCorpus.text(name).utf8).write(to: url, options: .withoutOverwriting)
            facts[id] = await FactExtractor().facts(for: url)
        }
    }

    // MARK: - Cards (the benchmark's Task 1)

    mutating func cards() async -> EvalReport.Cards {
        print("\nCards (\(ModelSpec.language.displayName), thinking off)")
        var result = EvalReport.Cards()
        var timed: [Double] = []
        var tokens = 0, seconds = 0.0
        engine.resetPeakMemory()
        for (index, (id, name)) in BenchmarkCorpus.allFiles.enumerated() {
            guard let facts = facts[id] else { continue }
            let start = Date()
            let card = try? await classifier.card(for: facts)
            let elapsed = Date().timeIntervalSince(start)
            let tally = await recorder.take()
            let score = BenchmarkCorpus.score(card, id: id)
            result.total += 1
            if score.kind { result.kinds += 1 }
            if score.issuer { result.issuers += 1 }
            if card != nil, tally.retries == 0 { result.firstTry += 1 }
            if index > 0 { timed.append(elapsed) }  // the first includes loading the model
            tokens += tally.tokens
            seconds += tally.seconds
            cards[id] = card
            let line = card?.line ?? "no valid card"
            result.rows[id] = line
            print("  \(id.padding(toLength: 4, withPad: " ", startingAt: 0)) \(name.padding(toLength: 22, withPad: " ", startingAt: 0))"
                  + " kind \(mark(score.kind)) issuer \(mark(score.issuer))\(tally.retries > 0 ? " (\(tally.retries) retr\(tally.retries == 1 ? "y" : "ies"))" : "")"
                  + String(format: " %4.1f s · ", elapsed) + line.prefix(90))
        }
        result.secondsPerFile = average(timed)
        result.tokensPerSecond = seconds > 0 ? Double(tokens) / seconds : 0
        result.peakGB = Double(engine.memory().peak) / 1e9
        return result
    }

    // MARK: - Decisions (Task 2: each scenario's five earlier files, as the benchmark gave them)

    func decisions() async -> EvalReport.Decisions {
        print("\nDecisions (\(ModelSpec.language.displayName), thinking on; the benchmark's fixed candidates)")
        var result = EvalReport.Decisions()
        var timed: [Double] = []
        var tokens = 0, seconds = 0.0
        engine.resetPeakMemory()
        let folders = BenchmarkCorpus.existingFolders.map { FolderOption(path: $0, purpose: nil, tags: []) }
        for scenario in scenarios {
            guard let facts = facts[scenario.newFile] else { continue }
            // The app's ids (E1…E5), mapped back to the corpus's afterwards.
            let candidates = scenario.candidates.compactMap(BenchmarkCorpus.earlier)
            let earlier = candidates.enumerated().map { index, file in
                EarlierCandidate(id: "E\(index + 1)", path: corpus.appending(path: file.fileName).path, name: file.fileName,
                                 folder: file.folder, about: file.about)
            }
            let request = DecisionRequest(facts: facts, folders: folders, earlier: earlier, newFolderParents: ["Documents"])
            _ = await recorder.take()
            let start = Date()
            var answer: FolderDecision?
            var problem: String?
            do {
                answer = try await classifier.decide(request)
            } catch {
                problem = "\(error)"
            }
            let elapsed = Date().timeIntervalSince(start)
            let tally = await recorder.take()
            timed.append(elapsed)
            tokens += tally.tokens
            seconds += tally.seconds
            result.continued += tally.continued

            let moved = Set((answer?.moveEarlier ?? []).compactMap { id -> String? in
                guard let index = Int(id.dropFirst()), id.hasPrefix("E"), candidates.indices.contains(index - 1) else { return nil }
                return candidates[index - 1].id
            })
            let score = BenchmarkCorpus.score(scenario, action: answer?.action, folder: answer?.folder, moved: moved)
            switch score {
            case .right: result.right += 1
            case .partly: result.partly += 1
            case .wrong: result.wrong += 1
            }
            if answer != nil, tally.retries == 0 { result.firstTry += 1 }
            let shown = answer.map { "\($0.action.rawValue) \($0.folder ?? "–") moving [\(moved.sorted().joined(separator: ", "))]" }
                ?? "no answer (\(problem ?? "?"))"
            result.marks[scenario.id] = score.rawValue
            result.answers[scenario.id] = shown
            print("  \(score.rawValue) \(scenario.id.padding(toLength: 4, withPad: " ", startingAt: 0)) \(scenario.newFile.padding(toLength: 4, withPad: " ", startingAt: 0))"
                  + String(format: "%5.1f s  ", elapsed) + shown
                  + (tally.retries > 0 ? " (\(tally.retries) retr\(tally.retries == 1 ? "y" : "ies"))" : ""))
            if let reason = answer?.reason { print("         \(reason.prefix(150))") }
        }
        result.secondsPerDecision = average(timed)
        result.tokensPerSecond = seconds > 0 ? Double(tokens) / seconds : 0
        result.peakGB = Double(engine.memory().peak) / 1e9
        return result
    }

    // MARK: - Embeddings (recall@3 of the card lines, as the benchmark measured it)

    func embeddings() async -> EvalReport.Embeddings {
        print("\nEmbeddings (\(ModelSpec.embedder.displayName), card lines)")
        var result = EvalReport.Embeddings()
        var vectors: [String: [Float]] = [:]
        var timed: [Double] = []
        for (id, _) in BenchmarkCorpus.allFiles {
            guard let line = cards[id]?.line else { continue }
            let start = Date()
            vectors[id] = try? await engine.embed(line)
            timed.append(Date().timeIntervalSince(start))
        }
        result.millisecondsPerEmbedding = average(Array(timed.dropFirst())) * 1_000
        var withMatch: [Float] = []
        for scenario in scenarios {
            guard let query = vectors[scenario.newFile] else {
                print("  \(scenario.newFile): no card, not embedded")
                continue
            }
            // Ranked against all 15 earlier files.
            let ranked = BenchmarkCorpus.earlierFiles.compactMap { file in vectors[file.id].map { (file.id, Vectors.cosine(query, $0)) } }
                .sorted { $0.1 > $1.1 }
            let top3 = ranked.prefix(3).map(\.0)
            result.top3[scenario.newFile] = top3
            let top1 = ranked.first?.1 ?? 0
            let hit = BenchmarkCorpus.recallHit(scenario, top3: top3)
            if let hit {
                result.total += 1
                if hit { result.recallAt3 += 1 }
                withMatch.append(top1)
            } else {
                result.noMatchTop1[scenario.newFile] = top1
            }
            let shown = ranked.prefix(3).map { "\($0.0) \(String(format: "%.3f", $0.1))" }.joined(separator: ", ")
            print("  \(hit.map(mark) ?? "–") \(scenario.newFile.padding(toLength: 4, withPad: " ", startingAt: 0)) top 3: \(shown)"
                  + (scenario.neighbours.isEmpty ? "  (nothing should match)" : "  (expected \(scenario.neighbours.joined(separator: ", ")))"))
        }
        result.averageTop1 = withMatch.isEmpty ? 0 : withMatch.reduce(0, +) / Float(withMatch.count)
        result.lowestTop1 = withMatch.min() ?? 0
        return result
    }

    // MARK: - Pipeline (the real Planner, with the catalog)

    /// A sandbox like a real one: the filed earlier files in their Home folders, moved there by
    /// the Applier (so the move log has them), the others waiting in Downloads; all catalogued
    /// with their cards. Then each new file, one at a time, goes into Downloads and the real
    /// Planner plans the folder. Nothing is applied; each new file is moved aside afterwards.
    func pipeline() async -> EvalReport.Pipeline {
        print("\nPipeline (the real Planner: catalog, nearest 5, decision, checks)")
        var result = EvalReport.Pipeline()
        let fm = FileManager.default
        let base = root.appending(path: "pipeline")
        let home = base.appending(path: "Home")
        let downloads = base.appending(path: "Downloads")
        let staging = base.appending(path: "staging")
        let done = base.appending(path: "done")
        let journal = MoveJournal(url: MoveJournal.url(forHome: home))
        do {
            for folder in [downloads, staging, done] + BenchmarkCorpus.existingFolders.map({ home.appending(path: $0) }) {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            var actions: [ProposedAction] = []
            for file in BenchmarkCorpus.earlierFiles {
                let data = Data(BenchmarkCorpus.text(file.fileName).utf8)
                guard let folder = file.folder else {
                    try data.write(to: downloads.appending(path: file.fileName), options: .withoutOverwriting)
                    continue
                }
                let source = staging.appending(path: file.fileName)
                try data.write(to: source, options: .withoutOverwriting)
                let modified = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                actions.append(ProposedAction(source: source, originalName: file.fileName, sourceSize: Int64(data.count),
                                              sourceModified: modified, destinationFolder: folder, finalName: file.fileName,
                                              tags: [], confidence: 1, reason: "eval: filed before", decidedBy: .rule("eval"),
                                              alerts: [], createsFolders: []))
            }
            let applied = Applier(homeRoot: home, journal: journal).apply(actions)
            if let failure = applied.first(where: { $0.outcome != .moved }) {
                print("  ✗ couldn't file the earlier files: \(failure.outcome)")
                return result
            }
        } catch {
            print("  ✗ couldn't build the sandbox: \(error.localizedDescription)")
            return result
        }

        // Catalogue the earlier files with their cards (as Organize Now would have, back then).
        let records = (try? journal.records()) ?? []
        var entries: [CatalogEntry] = []
        for file in BenchmarkCorpus.earlierFiles {
            let url = file.folder.map { home.appending(path: $0).appending(path: file.fileName) } ?? downloads.appending(path: file.fileName)
            guard let card = cards[file.id], let vector = try? await engine.embed(card.line) else {
                print("  \(file.id): no card or embedding; left out of the catalog")
                continue
            }
            let move = records.first { URL(filePath: $0.movedPath).lastPathComponent == file.fileName }
            entries.append(CatalogEntry(sha256: try? FileHash.sha256(url), moveID: move?.moveID, path: url.path, card: card,
                                        cardSource: .text, line: card.line, embedding: Vectors.encode(vector),
                                        embedder: ModelSpec.embedder.id, decidedBy: "eval",
                                        waited: file.folder == nil ? true : nil))
        }
        do {
            try CatalogStore(forHome: home).append(entries)
        } catch {
            print("  ✗ couldn't write the catalog: \(error.localizedDescription)")
            return result
        }
        let catalog = Catalog(entries: entries, records: records, embedder: ModelSpec.embedder.id)
        let earlierNames = Dictionary(uniqueKeysWithValues: BenchmarkCorpus.earlierFiles.map { ($0.fileName, $0.id) })
        let review = OrganizerConfig().reviewFolder

        var timed: [Double] = []
        engine.resetPeakMemory()
        for scenario in scenarios {
            guard let file = BenchmarkCorpus.new(scenario.newFile) else { continue }
            let url = downloads.appending(path: file.fileName)
            do {
                try Data(BenchmarkCorpus.text(file.fileName).utf8).write(to: url, options: .withoutOverwriting)
            } catch {
                print("  ✗ \(scenario.id): \(error.localizedDescription)"); continue
            }
            var planner = Planner(homeRoot: home)
            planner.classifier = MLXClassifier(model: recorder)
            planner.catalog = CatalogContext(catalog: catalog, records: records, embedder: engine, embedderID: ModelSpec.embedder.id)
            let start = Date()
            let plan: Plan
            do {
                let steps = StepLog()
                plan = try await planner.plan(folder: downloads) { steps.show($0) }
            } catch {
                print("  ✗ \(scenario.id): \(error.localizedDescription)"); continue
            }
            let elapsed = Date().timeIntervalSince(start)
            timed.append(elapsed)
            _ = await recorder.take()

            // What happened to the new file.
            let mine = plan.actions.first { $0.source.lastPathComponent == file.fileName && !$0.isEarlierFile }
            var action: FolderDecision.Action?
            var folder: String?
            var moved: Set<String> = []
            var outcome: String
            if let mine, mine.destinationFolder != review, !mine.destinationFolder.hasPrefix(review + "/") {
                action = mine.createsFolders.isEmpty ? .join : .newFolder
                folder = mine.destinationFolder
                moved = Set(plan.actions.filter { $0.isEarlierFile && $0.groupID != nil && $0.groupID == mine.groupID }
                    .compactMap { earlierNames[$0.source.lastPathComponent] })
                outcome = "\(action!.rawValue) \(mine.destinationFolder) moving [\(moved.sorted().joined(separator: ", "))] (\(mine.decidedBy))"
            } else if let mine {
                outcome = "to \(mine.destinationFolder) (\(mine.decidedBy)): \(mine.reason.prefix(100))"
            } else if let waiting = plan.waiting.first(where: { $0.name == file.fileName }) {
                action = .wait
                outcome = "wait: \(waiting.reason.prefix(110))"
            } else {
                outcome = plan.skipped.first { $0.name == file.fileName }.map { "skipped: \($0.reason)" } ?? "not in the plan"
            }
            let score = BenchmarkCorpus.score(scenario, action: action, folder: folder, moved: moved)
            switch score {
            case .right: result.right += 1
            case .partly: result.partly += 1
            case .wrong: result.wrong += 1
            }
            // Were the files it should be grouped with among the 5 it was shown?
            var neighbours = ""
            if let entry = plan.catalogEntries.first(where: { URL(filePath: $0.path).lastPathComponent == file.fileName }),
               let vector = Vectors.decode(entry.embedding) {
                let nearest = catalog.nearest(to: vector, k: 5).compactMap { earlierNames[URL(filePath: $0.item.path).lastPathComponent] }
                if !scenario.neighbours.isEmpty {
                    result.withNeighbours += 1
                    let found = scenario.neighbours.allSatisfy(nearest.contains)
                    if found { result.neighboursInTop5 += 1 }
                    neighbours = " · shown \(nearest.joined(separator: ", ")) \(mark(found))"
                } else {
                    neighbours = " · shown \(nearest.joined(separator: ", "))"
                }
            }
            // Anything else the plan would do (it shouldn't touch the waiting files on its own).
            let others = plan.actions.filter { $0.source.lastPathComponent != file.fileName && !($0.groupID != nil && $0.groupID == mine?.groupID) }
            if !others.isEmpty { outcome += " · also: " + others.map { "\($0.originalName) → \($0.destinationFolder)" }.joined(separator: ", ") }
            result.marks[scenario.id] = score.rawValue
            result.outcomes[scenario.id] = outcome
            print("  \(score.rawValue) \(scenario.id.padding(toLength: 4, withPad: " ", startingAt: 0)) \(file.fileName.padding(toLength: 18, withPad: " ", startingAt: 0))"
                  + String(format: "%5.1f s  ", elapsed) + outcome + neighbours)

            // Moved aside, never deleted.
            let aside = done.appending(path: scenario.id)
            try? fm.createDirectory(at: aside, withIntermediateDirectories: true)
            try? fm.moveItem(at: url, to: aside.appending(path: file.fileName))
        }
        result.secondsPerFile = average(timed)
        result.peakGB = Double(engine.memory().peak) / 1e9
        return result
    }
}

/// C's image set, carded by the app's vision model.
func evalImages(engine: MLXEngine, folder: URL) async -> EvalReport.Images {
    print("\nImages (\(ModelSpec.vision.displayName))")
    var result = EvalReport.Images()
    let images: [EvalImage]
    do {
        images = try ImageEvalSet.build(in: folder)
    } catch {
        print("  ✗ couldn't build the image set: \(error.localizedDescription)")
        return result
    }
    let writer = VisionCardWriter(model: engine)
    var timed: [Double] = []
    engine.resetPeakMemory()
    for (index, image) in images.enumerated() {
        let facts = await FactExtractor().facts(for: folder.appending(path: image.file))
        let start = Date()
        let outcome = try? await writer.ask(for: facts)
        let elapsed = Date().timeIntervalSince(start)
        if index > 0 { timed.append(elapsed) }
        let card = outcome?.value
        let score = card.map { ImageEvalSet.score($0, for: image) } ?? EvalScore(kind: false, fact: false, name: false, split: false)
        result.total += 1
        if score.kind { result.kinds += 1 }
        if score.fact { result.facts += 1 }
        if score.name { result.names += 1 }
        if score.split { result.rightWay += 1 }
        if card != nil, outcome?.replies.count == 1 { result.firstTry += 1 }
        print("  \(image.label.padding(toLength: 24, withPad: " ", startingAt: 0)) kind \(mark(score.kind)) fact \(mark(score.fact))"
              + " name \(mark(score.name)) way \(mark(score.split))" + String(format: " %4.1f s · ", elapsed)
              + (card.map { "\($0.kind) | \($0.suggestedName)" } ?? "no valid card"))
    }
    result.secondsPerImage = average(timed)
    result.peakGB = Double(engine.memory().peak) / 1e9
    await engine.unload(.vision)
    return result
}

extension EvalReport {
    static var folder: URL { URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "eval-results") }

    /// The newest earlier run, if any.
    static func latest() -> EvalReport? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let newest = files.filter({ $0.pathExtension == "json" }).max(by: { $0.lastPathComponent < $1.lastPathComponent }),
              let data = try? Data(contentsOf: newest) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(EvalReport.self, from: data)
    }

    /// A new file per run (never replacing one).
    func save() throws -> URL {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        let file = Self.folder.appending(path: "\(stamp).json")
        try encoder().encode(self).write(to: file, options: .withoutOverwriting)
        return file
    }

    func printSummary(previous: EvalReport?) {
        typealias Base = BenchmarkCorpus.Baseline
        print("\nSummary (benchmark / C baseline in brackets; ⚠ below it; last run's value after →)")
        func line(_ label: String, _ value: Int, of total: Int, baseline: Int?, last: Int?) {
            let flag = baseline.map { value < $0 ? " ⚠" : "" } ?? ""
            let base = baseline.map { " [\($0)]" } ?? ""
            let change = last.map { $0 == value ? "" : " (last run \($0) → \(value))" } ?? ""
            print("  \(label.padding(toLength: 34, withPad: " ", startingAt: 0)) \(value)/\(total)\(base)\(flag)\(change)")
        }
        func score(_ label: String, _ value: Float, baseline: Float, last: Float?, lowerIsBetter: Bool = false) {
            let worse = lowerIsBetter ? value > baseline + 0.02 : value < baseline - 0.02
            let change = last.map { abs($0 - value) < 0.0005 ? "" : String(format: " (last run %.3f → %.3f)", $0, value) } ?? ""
            print("  \(label.padding(toLength: 34, withPad: " ", startingAt: 0)) " + String(format: "%.3f [%.3f]", value, baseline)
                  + (worse ? " ⚠" : "") + change)
        }
        if let cards {
            line("cards: kind", cards.kinds, of: cards.total, baseline: Base.cardKinds, last: previous?.cards?.kinds)
            line("cards: issuer", cards.issuers, of: cards.total, baseline: Base.cardIssuers, last: previous?.cards?.issuers)
            line("cards: valid JSON first try", cards.firstTry, of: cards.total, baseline: nil, last: previous?.cards?.firstTry)
            print(String(format: "  cards: %.1f s per file, %.0f tokens/s, peak %.1f GB", cards.secondsPerFile, cards.tokensPerSecond, cards.peakGB))
        }
        if let decisions {
            let total = decisions.right + decisions.partly + decisions.wrong
            line("decisions: right (✓)", decisions.right, of: total, baseline: Base.decisions.right, last: previous?.decisions?.right)
            line("decisions: partly (~)", decisions.partly, of: total, baseline: nil, last: previous?.decisions?.partly)
            line("decisions: valid JSON first try", decisions.firstTry, of: total, baseline: nil, last: previous?.decisions?.firstTry)
            print(String(format: "  decisions: %.1f s each, %.0f tokens/s, thinking capped %d×, peak %.1f GB",
                         decisions.secondsPerDecision, decisions.tokensPerSecond, decisions.continued, decisions.peakGB))
            if let last = previous?.decisions {
                let changed = decisions.marks.keys.sorted().filter { last.marks[$0] != nil && last.marks[$0] != decisions.marks[$0] }
                if !changed.isEmpty { print("  decisions changed since last run: " + changed.map { "\($0) \(last.marks[$0]!) → \(decisions.marks[$0]!)" }.joined(separator: ", ")) }
            }
        }
        if let embeddings {
            line("embeddings: recall@3", embeddings.recallAt3, of: embeddings.total, baseline: Base.recallAt3, last: previous?.embeddings?.recallAt3)
            score("embeddings: average top-1 (match)", embeddings.averageTop1, baseline: Base.averageTop1, last: previous?.embeddings?.averageTop1)
            score("embeddings: lowest top-1 (match)", embeddings.lowestTop1, baseline: Base.lowestTop1, last: previous?.embeddings?.lowestTop1)
            for (id, value) in embeddings.noMatchTop1.sorted(by: { $0.key < $1.key }) {
                score("embeddings: \(id) top-1 (no match)", value, baseline: Base.noMatchTop1[id] ?? 0, last: previous?.embeddings?.noMatchTop1[id], lowerIsBetter: true)
            }
            print(String(format: "  embeddings: %.0f ms each", embeddings.millisecondsPerEmbedding))
        }
        if let images {
            line("images: kind", images.kinds, of: images.total, baseline: Base.imageKinds, last: previous?.images?.kinds)
            line("images: key fact", images.facts, of: images.total, baseline: Base.imageFacts, last: previous?.images?.facts)
            line("images: usable name", images.names, of: images.total, baseline: Base.imageNames, last: previous?.images?.names)
            line("images: sent the right way", images.rightWay, of: images.total, baseline: Base.imagesRightWay, last: previous?.images?.rightWay)
            line("images: valid JSON first try", images.firstTry, of: images.total, baseline: nil, last: previous?.images?.firstTry)
            print(String(format: "  images: %.1f s each, peak %.1f GB", images.secondsPerImage, images.peakGB))
        }
        if let pipeline {
            let total = pipeline.right + pipeline.partly + pipeline.wrong
            // No benchmark number for this: compared with the fixed-candidate decisions instead.
            line("pipeline: right (✓)", pipeline.right, of: total, baseline: nil, last: previous?.pipeline?.right)
            line("pipeline: partly (~)", pipeline.partly, of: total, baseline: nil, last: previous?.pipeline?.partly)
            line("pipeline: expected files in the 5 shown", pipeline.neighboursInTop5, of: pipeline.withNeighbours, baseline: nil,
                 last: previous?.pipeline?.neighboursInTop5)
            print(String(format: "  pipeline: %.1f s per file (the whole plan), peak %.1f GB", pipeline.secondsPerFile, pipeline.peakGB))
            if let last = previous?.pipeline {
                let changed = pipeline.marks.keys.sorted().filter { last.marks[$0] != nil && last.marks[$0] != pipeline.marks[$0] }
                if !changed.isEmpty { print("  pipeline changed since last run: " + changed.map { "\($0) \(last.marks[$0]!) → \(pipeline.marks[$0]!)" }.joined(separator: ", ")) }
            }
        }
        if previous == nil { print("  (no earlier run in eval-results to compare with)") }
    }
}

/// The Planner's steps, each with the time it took (to stderr): where a slow plan spends it.
final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (key: String, start: Date)?

    func show(_ progress: Planner.Progress) {
        let key = "\(progress.step.rawValue): \(progress.file)"
        lock.lock()
        defer { lock.unlock() }
        guard current?.key != key else { return }
        if let current {
            FileHandle.standardError.write(Data(String(format: "      %5.1f s  %@\n", Date().timeIntervalSince(current.start), current.key).utf8))
        }
        current = (key, Date())
    }
}

private func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }

private func average(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

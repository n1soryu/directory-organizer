import Foundation
import OrganizerCore
import OrganizerMLX

let usage = """
    organize: sorts downloads into your folders. Nothing moves without your approval.

    Usage:
      organize plan <folder> [--home <folder>] [--json] [--no-model] [--quick]
          Show where every item in <folder> would go. Moves nothing.
          --quick      what the app's automatic scan sees: rules only, no text recognition,
                       no model; images, scans and leftovers are listed as waiting
      organize apply <folder> [--home <folder>] [--yes] [--no-model]
          Show the plan, ask for approval (all / one by one / cancel), then move and tag.
          --yes        approve everything without asking
          --no-model   rules only: files no rule can place go to review
      Without the models, or without MLX's GPU shaders (built only when Xcode's Metal
      toolchain is installed), files no rule can place go to review.
      organize model
          Can the on-device model (Qwen3 8B, via MLX) run here? Which models are downloaded?
      organize model-check [--download]
          Load each MLX model and run one short sample: valid JSON, speed, memory.
          --download   fetch missing models first (~5 GB, once)
          Needs MLX's GPU shaders, which are built only when Xcode's Metal toolchain is installed.
      organize image-eval [--download | --images-only]
          Developer tool: compare the vision models on a built-in image set (docs/mlx-plan.md, C).
          --download      fetch missing models first (~3 GB each, once)
          --images-only   just build the image set (in a new temporary folder) to look at
      organize undo --last | --batch <id> | --all | <file name>  [--home <folder>]
          Put files back exactly as they were (original folder, name and tags).
      organize log [--home <folder>]
          List moves and undos, newest first.
      organize facts <file>
          Show everything extracted from one file (as JSON).
      organize catalog [--home <folder>]
          The catalog: every file carded so far, filed / waiting / undone / gone.
      organize similar <file> [--home <folder>]
          The 5 catalogued files most similar to <file> in meaning, with their scores.
      organize describe <file>...
          Each file's card: what Qwen3 says it is, and the name it suggests.

      --home   stand-in home folder (default: <folder>/../Home for plan/apply, TestData/Home otherwise)
      The move log is kept next to the home folder: <home>/../moves.jsonl
      This tool only works on the sandbox; the app handles your real folders.

    Example:
      swift run make-testdata && swift run organize apply TestData/Downloads
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("organize: \(message)\n".utf8))
    exit(1)
}

func path(_ string: String) -> URL {
    URL(filePath: (string as NSString).expandingTildeInPath, relativeTo: .currentDirectory()).standardizedFileURL
}

/// Until you say otherwise, never read your real Downloads or file into your real home folder.
func refuseRealFolders(_ urls: URL...) {
    for url in urls where FolderAccess.isRealUserFolder(url) {
        fail("\(url.path) is one of your real folders. This tool only runs on the sandbox (TestData).")
    }
}

func journal(for home: URL) -> MoveJournal {
    MoveJournal(url: MoveJournal.url(forHome: home))
}

func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

/// Parses `[--home <folder>] [flags...] [positional]`.
struct Arguments {
    var flags: Set<String> = []
    var values: [String: String] = [:]
    var positional: [String] = []

    init(_ args: [String], valued: Set<String> = ["--home", "--batch"]) {
        var args = args
        while !args.isEmpty {
            let arg = args.removeFirst()
            if valued.contains(arg) {
                guard !args.isEmpty else { fail("\(arg) needs a value") }
                values[arg] = args.removeFirst()
            } else if arg.hasPrefix("--") {
                flags.insert(arg)
            } else {
                positional.append(arg)
            }
        }
    }

    /// The input folder and home folder for plan/apply.
    func folders() -> (folder: URL, home: URL) {
        guard positional.count == 1 else { fail("which folder?\n\n\(usage)") }
        let folder = path(positional[0])
        let home = values["--home"].map(path) ?? folder.deletingLastPathComponent().appending(path: "Home")
        guard FileManager.default.fileExists(atPath: home.path) else {
            fail("no home folder at \(home.path); pass --home <folder>")
        }
        refuseRealFolders(folder, home)
        return (folder, home)
    }

    /// The home folder for undo/log.
    func home() -> URL {
        let home = path(values["--home"] ?? "TestData/Home")
        guard FileManager.default.fileExists(atPath: home.path) else {
            fail("no home folder at \(home.path); pass --home <folder>")
        }
        refuseRealFolders(home)
        return home
    }
}

func makePlan(_ folder: URL, _ home: URL, useModel: Bool, quick: Bool = false) async -> Plan {
    var planner = Planner(homeRoot: home, mode: quick ? .quick : .full)
    // What earlier runs learned about the folders, and the model moves you undid.
    let store = ProfileStore(forHome: home)
    planner.profiles = store.load()
    planner.corrections = Correction.from((try? journal(for: home).records()) ?? [], homeRoot: home)
    var engine: MLXEngine?
    if useModel, !quick {
        if let reason = MLXEngine.unavailableReason() {
            FileHandle.standardError.write(Data("note: the model can't run (\(reason)); files no rule can place go to review.\n".utf8))
        } else {
            let mlx = MLXEngine()
            planner.classifier = MLXClassifier(model: mlx) { MLXEngine.unavailableReason() }
            if let reason = MLXEngine.unavailableReason(.vision) {
                FileHandle.standardError.write(Data("note: \(reason); images go by the image rule.\n".utf8))
            } else {
                // The image phase: the vision model is released before the text model loads.
                planner.imageCards = VisionCardWriter(model: mlx) { await mlx.unload(.vision) }
            }
            if let reason = MLXEngine.unavailableReason(.embedder) {
                FileHandle.standardError.write(Data("note: \(reason); similar files are found by shared words, and nothing is catalogued.\n".utf8))
            } else {
                planner.catalog = catalogContext(home: home, embedder: mlx)
            }
            engine = mlx
        }
    }
    do {
        let plan = try await planner.plan(folder: folder)
        await engine?.unloadAll()
        try? store.save(plan.profiles)
        do {
            try CatalogStore(forHome: home).append(plan.catalogEntries)
        } catch {
            FileHandle.standardError.write(Data("note: couldn't save \(plan.catalogEntries.count) catalog entries: \(error.localizedDescription)\n".utf8))
        }
        return plan
    } catch {
        fail("couldn't read \(folder.path): \(error.localizedDescription)")
    }
}

/// The catalog as it is now, read with the move log that tells where each file went.
func catalog(home: URL) -> (catalog: Catalog, records: [MoveRecord], damaged: Int) {
    let store = CatalogStore(forHome: home)
    let log = journal(for: home)
    _ = try? log.recover()
    let records = (try? log.records()) ?? []
    let entries = (try? store.entries()) ?? []
    return (Catalog(entries: entries, records: records, embedder: ModelSpec.embedder.id), records,
            (try? store.damagedLineCount()) ?? 0)
}

func catalogContext(home: URL, embedder: MLXEngine) -> CatalogContext {
    let read = catalog(home: home)
    return CatalogContext(catalog: read.catalog, records: read.records, embedder: embedder, embedderID: ModelSpec.embedder.id)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()
let interactive = isatty(STDIN_FILENO) != 0
let printer = PlanPrinter(useColor: isatty(STDOUT_FILENO) != 0)

switch command {
case "plan":
    let arguments = Arguments(args)
    let (folder, home) = arguments.folders()
    let plan = await makePlan(folder, home, useModel: !arguments.flags.contains("--no-model"),
                              quick: arguments.flags.contains("--quick"))
    if arguments.flags.contains("--json") {
        print(String(decoding: try encoder().encode(plan), as: UTF8.self))
    } else {
        printer.print(plan)
    }

case "apply":
    let arguments = Arguments(args)
    let (folder, home) = arguments.folders()
    let plan = await makePlan(folder, home, useModel: !arguments.flags.contains("--no-model"))
    printer.print(plan)
    guard !plan.actions.isEmpty else { print("\nNothing to do."); exit(0) }

    let approved: [ProposedAction]
    if arguments.flags.contains("--yes") {
        approved = plan.actions
    } else {
        guard interactive else { fail("can't ask for approval without a terminal; use --yes") }
        approved = Approval(printer: printer).ask(plan.actions)
    }
    guard !approved.isEmpty else { print("Nothing approved; nothing moved."); exit(0) }

    let results = Applier(homeRoot: home, journal: journal(for: home)).apply(approved)
    printer.print(results, home: home)
    // Scripts can tell: not everything approved was moved.
    if results.contains(where: { $0.outcome != .moved }) { exit(1) }

case "undo":
    let arguments = Arguments(args)
    let home = arguments.home()
    let undoer = Undoer(journal: journal(for: home))
    let candidates = try undoer.undoable()
    let chosen: [MoveRecord]
    if arguments.flags.contains("--all") {
        chosen = candidates
    } else if arguments.flags.contains("--last") {
        guard let last = candidates.first else { fail("nothing to undo") }
        chosen = candidates.filter { $0.batchID == last.batchID }
    } else if let batch = arguments.values["--batch"] {
        chosen = candidates.filter { $0.batchID.uuidString.lowercased().hasPrefix(batch.lowercased()) }
        // A prefix that fits several batches would undo more than you meant.
        let batches = Set(chosen.map(\.batchID))
        guard batches.count <= 1 else { fail("\(batch) matches \(batches.count) batches; give more of the id (see `organize log`)") }
    } else if let name = arguments.positional.first {
        // Match the current name or the original name.
        chosen = candidates.filter {
            URL(filePath: $0.movedPath).lastPathComponent == name || URL(filePath: $0.originalPath).lastPathComponent == name
        }
    } else {
        fail("undo what? --last, --batch <id>, --all or a file name\n\n\(usage)")
    }
    guard !chosen.isEmpty else { fail("no matching moves to undo (see `organize log`)") }
    printer.print(undoer.undo(chosen), home: home)

case "log":
    let arguments = Arguments(args)
    let home = arguments.home()
    let log = journal(for: home)
    try log.recover()
    printer.printLog(try log.records(), home: home)

case "model":
    let store = ModelStore()
    for spec in ModelSpec.all {
        print("\(spec.displayName): \(store.isReady(spec) ? "downloaded" : "not downloaded") (\(spec.repo) @ \(spec.revision.prefix(7)))")
    }
    print("Models folder: \(store.directory.path)")
    if let reason = MLXEngine.unavailableReason(store: store) {
        print("The model can't run: \(reason).")
        print("Files no rule can place go to review until it can.")
    } else {
        print("The model can run.")
    }

case "model-check":
    let arguments = Arguments(args)
    guard arguments.positional.isEmpty, arguments.flags.isSubset(of: ["--download"]) else {
        fail("model-check takes only --download")
    }
    await runModelCheck(download: arguments.flags.contains("--download"))

case "image-eval":
    let arguments = Arguments(args)
    guard arguments.positional.isEmpty, arguments.flags.isSubset(of: ["--download", "--images-only"]) else {
        fail("image-eval takes only --download or --images-only")
    }
    await runImageEval(download: arguments.flags.contains("--download"), imagesOnly: arguments.flags.contains("--images-only"))

case "facts":
    let arguments = Arguments(args)
    guard arguments.flags.isEmpty, arguments.positional.count == 1, let file = arguments.positional.first.map(path) else {
        fail("which file? (one file, no options)")
    }
    refuseRealFolders(file.deletingLastPathComponent())
    let facts = await FactExtractor().facts(for: file)
    print(String(decoding: try encoder().encode(facts), as: UTF8.self))

case "catalog":
    let arguments = Arguments(args)
    let home = arguments.home()
    let read = catalog(home: home)
    let items = read.catalog.items
    print("Catalog: \(CatalogStore(forHome: home).url.path)")
    for state in [CatalogItem.State.filed, .waiting, .undone, .gone] {
        let matching = items.filter { $0.state == state }
        guard !matching.isEmpty else { continue }
        print("\n\(state.rawValue) (\(matching.count))")
        for item in matching {
            let shown = item.path.replacingOccurrences(of: home.deletingLastPathComponent().path + "/", with: "")
            print("  \(shown)\n      \(item.entry.cardSource.rawValue) · \(item.entry.line.prefix(110))")
        }
    }
    if items.isEmpty { print("\nNothing catalogued yet: Organize Now (or organize plan) catalogues the files it cards.") }
    if !read.catalog.stale.isEmpty { print("\n\(read.catalog.stale.count) made by another embedder: embedded again at the next run") }
    if read.damaged > 0 { print("\n\(read.damaged) damaged line(s) skipped") }

case "similar":
    let arguments = Arguments(args)
    guard let target = arguments.positional.first.map(path) else { fail("which file?") }
    let home = arguments.home()
    refuseRealFolders(target.deletingLastPathComponent())
    let read = catalog(home: home)
    let hash = try? FileHash.sha256(target)
    var vector = hash.flatMap { h in read.catalog.items.first { $0.entry.sha256 == h }?.vector }
    let engine = MLXEngine()
    if vector == nil {
        // Not catalogued yet: card it and embed the card, as Organize Now would.
        if let reason = MLXEngine.unavailableReason() ?? MLXEngine.unavailableReason(.embedder) {
            fail("it isn't catalogued, and the models can't run: \(reason)")
        }
        let facts = await FactExtractor().facts(for: target)
        var card: FileCard?
        if facts.kind == .image, MLXEngine.unavailableReason(.vision) == nil {
            card = try? await VisionCardWriter(model: engine).card(for: facts)
            await engine.unload(.vision)
        } else {
            card = try? await MLXClassifier(model: engine).card(for: facts)
        }
        guard let line = card.map(CatalogEntry.line(for:)) ?? CatalogEntry.line(forText: facts.text) else {
            fail("nothing to compare: no card and no text")
        }
        print("\(target.lastPathComponent): \(line)")
        vector = try? await engine.embed(line)
    }
    guard let vector else { fail("couldn't embed it") }
    let nearest = read.catalog.nearest(to: vector, k: 5, excluding: hash)
    if nearest.isEmpty { print("Nothing in the catalog to compare with yet.") }
    for (item, score) in nearest {
        let shown = item.path.replacingOccurrences(of: home.deletingLastPathComponent().path + "/", with: "")
        print(String(format: "  %.2f  ", score) + "\(item.state.rawValue): \(shown)\n        \(item.entry.line.prefix(110))")
    }
    await engine.unloadAll()

case "describe":
    guard !args.isEmpty else { fail("which files?") }
    if let reason = MLXEngine.unavailableReason() { fail("the model can't run: \(reason)") }
    let engine = MLXEngine()
    let classifier = MLXClassifier(model: engine)
    for file in args.map(path) {
        refuseRealFolders(file.deletingLastPathComponent())
        let facts = await FactExtractor().facts(for: file)
        do {
            let card = try await classifier.card(for: facts)
            print("\(file.lastPathComponent): \(card.line)")
            print("  suggested name: \(card.suggestedName)\(card.date.map { "; date: \($0)" } ?? "")\(card.people.isEmpty ? "" : "; people: " + card.people.joined(separator: ", "))")
        } catch {
            print("\(file.lastPathComponent): \(error)")
        }
    }
    await engine.unloadAll()

case "-h", "--help", "help":
    print(usage)

default:
    fail("unknown command \(command)\n\n\(usage)")
}

import Foundation
import OrganizerCore

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
      organize model
          Is Apple's on-device model available?
      organize undo --last | --batch <id> | --all | <file name>  [--home <folder>]
          Put files back exactly as they were (original folder, name and tags).
      organize log [--home <folder>]
          List moves and undos, newest first.
      organize facts <file>
          Show everything extracted from one file (as JSON).

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
    let realHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    let protected = [realHome] + ["Downloads", "Documents", "Desktop", "Pictures", "Movies", "Music"]
        .map { realHome + "/" + $0 }
    for url in urls {
        let p = url.resolvingSymlinksInPath().path
        if protected.contains(where: { p == $0 || ($0 != realHome && p.hasPrefix($0 + "/")) }) {
            fail("\(p) is one of your real folders. For now this only runs on the sandbox (TestData).")
        }
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
    if useModel, !quick {
        planner.classifier = AppleClassifier()
        if let reason = AppleClassifier.unavailableReason() {
            FileHandle.standardError.write(Data("note: Apple's model isn't available (\(reason)); files no rule can place go to review.\n".utf8))
        }
    }
    do {
        return try await planner.plan(folder: folder)
    } catch {
        fail("couldn't read \(folder.path): \(error.localizedDescription)")
    }
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
    if let reason = AppleClassifier.unavailableReason() {
        print("Apple's on-device model: not available (\(reason)).")
        print("Files no rule can place will go to review until it is.")
    } else {
        print("Apple's on-device model: available\(AppleClassifier.canSeeImages ? ", can look at images" : "").")
    }

case "facts":
    guard let file = args.first.map(path) else { fail("which file?") }
    refuseRealFolders(file.deletingLastPathComponent())
    let facts = await FactExtractor().facts(for: file)
    print(String(decoding: try encoder().encode(facts), as: UTF8.self))

case "-h", "--help", "help":
    print(usage)

default:
    fail("unknown command \(command)\n\n\(usage)")
}

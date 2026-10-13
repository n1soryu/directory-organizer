import Foundation
import OrganizerCore

let usage = """
    organize: proposes where your downloads should go. Plan only: nothing is moved.

    Usage:
      organize plan <folder> [--home <folder>] [--json]
          Show the proposed action for every item in <folder>.
          --home   stand-in home folder for destinations (default: <folder>/../Home)
          --json   print the plan as JSON
      organize facts <file>
          Show everything extracted from one file (as JSON).

    Example:
      swift run make-testdata && swift run organize plan TestData/Downloads
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
            fail("\(p) is one of your real folders. Milestone 1 only runs on the sandbox (TestData).")
        }
    }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

switch command {
case "plan":
    var json = false
    var home: URL?
    var folder: URL?
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--json": json = true
        case "--home":
            guard !args.isEmpty else { fail("--home needs a folder") }
            home = path(args.removeFirst())
        default:
            guard folder == nil, !arg.hasPrefix("-") else { fail("unexpected argument \(arg)\n\n\(usage)") }
            folder = path(arg)
        }
    }
    guard let folder else { fail("which folder?\n\n\(usage)") }
    let homeRoot = home ?? folder.deletingLastPathComponent().appending(path: "Home")
    guard FileManager.default.fileExists(atPath: homeRoot.path) else {
        fail("no home folder at \(homeRoot.path); pass --home <folder>")
    }
    refuseRealFolders(folder, homeRoot)

    let plan: Plan
    do {
        plan = try await Planner(homeRoot: homeRoot).plan(folder: folder)
    } catch {
        fail("couldn't read \(folder.path): \(error.localizedDescription)")
    }
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(plan), as: UTF8.self))
    } else {
        PlanPrinter(useColor: isatty(STDOUT_FILENO) != 0).print(plan)
    }

case "facts":
    guard let file = args.first.map(path) else { fail("which file?") }
    refuseRealFolders(file.deletingLastPathComponent())
    let facts = await FactExtractor().facts(for: file)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(facts), as: UTF8.self))

case "-h", "--help", "help":
    print(usage)

default:
    fail("unknown command \(command)\n\n\(usage)")
}

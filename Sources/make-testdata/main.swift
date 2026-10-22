import Foundation
import TestDataKit

// Usage: make-testdata [folder]            (default: ./TestData)
//        make-testdata --round2 [folder]   add a few later downloads to an existing sandbox
// Builds Downloads/ (fake downloads) and Home/ (a stand-in home folder) plus expected.json.

var arguments = Array(CommandLine.arguments.dropFirst())
let round2 = arguments.first == "--round2"
if round2 { arguments.removeFirst() }
let root = URL(filePath: ((arguments.first ?? "TestData") as NSString).expandingTildeInPath,
               relativeTo: .currentDirectory())
    .standardizedFileURL

if round2 {
    do {
        let added = try TestDataBuilder.addRound2(at: root)
        print("Added to \(root.path)/Downloads: \(added.joined(separator: ", "))")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("make-testdata: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

do {
    let expected = try TestDataBuilder.build(at: root)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(expected).write(to: root.appending(path: "expected.json"))
    print("Built \(expected.count) test downloads in \(root.path)/Downloads")
    print("Stand-in home folder: \(root.path)/Home")
    print("Expected results:     \(root.path)/expected.json")
} catch {
    FileHandle.standardError.write(Data("make-testdata: \(error.localizedDescription)\n".utf8))
    exit(1)
}

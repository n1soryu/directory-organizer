import Foundation
import TestDataKit

// Usage: make-testdata [folder]   (default: ./TestData)
// Builds Downloads/ (fake downloads) and Home/ (a stand-in home folder) plus expected.json.

let root = URL(filePath: ((CommandLine.arguments.dropFirst().first ?? "TestData") as NSString).expandingTildeInPath,
               relativeTo: .currentDirectory())
    .standardizedFileURL

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

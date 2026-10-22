import Foundation
import Testing
@testable import OrganizerCore

/// Folder profiles: learned from your folders' contents instead of written into the code.
@Suite(.serialized) struct ProfileTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "file-organizer-profiles-\(UUID().uuidString)")
    let config = OrganizerConfig()

    func make(_ folder: String, files: [String] = [], from source: String? = nil) throws {
        let url = home.appending(path: folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in files {
            try Data(name.utf8).write(to: url.appending(path: name))
            if let source { try WhereFroms.write([source], to: url.appending(path: name)) }
        }
    }

    /// Writes a purpose for every folder and counts how often it's asked.
    final class Describer: FileClassifier, @unchecked Sendable {
        let name = "describer"
        private let lock = NSLock()
        private var _asked: [String] = []
        var asked: [String] { lock.withLock { _asked } }
        func suggest(_ request: ClassificationRequest) async throws -> ClassifierSuggestion {
            ClassifierSuggestion(destination: request.reviewFolder, confidence: 0.9, reason: "")
        }
        func suggestName(for facts: FileFacts) async throws -> NameSuggestion { throw ClassifierError.unavailable("") }
        func describeFolder(_ profile: FolderProfile) async throws -> String {
            lock.withLock { _asked.append(profile.path) }
            return "things in \(profile.path.split(separator: "/").last ?? "")"
        }
    }

    @Test func aProfileIsWhatsInTheFolder() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try make("Documents/Bills", files: ["desco_sep.pdf", "desco_aug.pdf", "wasa.pdf"], from: "https://www.desco.org.bd/bill")
        let bills = try #require(FolderProfiler.profiles(homeRoot: home, config: config).first { $0.path == "Documents/Bills" })
        #expect(bills.fileCount == 3)
        #expect(bills.kinds == ["pdf": 3])
        #expect(Set(bills.examples) == ["desco_sep.pdf", "desco_aug.pdf", "wasa.pdf"])
        #expect(bills.sources == ["www.desco.org.bd"])
        #expect(bills.purpose == nil)
    }

    @Test func purposesAreLearnedInFullRunsOnlyAndOnlyOnce() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try make("Documents/Bills", files: ["a.pdf"])
        try make("Pictures/Trips", files: ["x.jpg"])
        try make("Documents/FSAE")      // empty: its name alone isn't enough to go on
        try make("Downloads")
        let model = Describer()

        var quick = Planner(homeRoot: home, mode: .quick)
        quick.classifier = model
        #expect(try await quick.plan(folder: home.appending(path: "Downloads")).profiles.allSatisfy { $0.purpose == nil })
        #expect(model.asked.isEmpty)

        var full = Planner(homeRoot: home)
        full.classifier = model
        let first = try await full.plan(folder: home.appending(path: "Downloads")).profiles
        #expect(first.first { $0.path == "Documents/Bills" }?.purpose == "things in Bills")
        #expect(Set(model.asked) == ["Documents/Bills", "Pictures/Trips"])
        #expect(first.first { $0.path == "Documents/FSAE" }?.purpose == nil)

        // Next run, with what was learned: nothing asked again, nothing forgotten.
        full.profiles = first
        let second = try await full.plan(folder: home.appending(path: "Downloads")).profiles
        #expect(model.asked.count == 2)
        #expect(second == first)
    }

    @Test func aDownloadedFolderOfVideosGetsNewFoldersUnderMovies() {
        var inside = FolderContents()
        inside.kinds = ["video": 1, "text": 2]
        inside.kindBytes = ["video": 2_000_000_000, "text": 90_000]   // a film with subtitles
        #expect(FolderCatalog.newFolderParents(for: .folder, inside: inside) == ["Movies"])
        inside.kindBytes = ["video": 4_000, "text": 900_000]          // notes with a clip
        #expect(FolderCatalog.newFolderParents(for: .folder, inside: inside) == ["Documents"])
    }

    @Test func aPurposeIsRewrittenWhenTheFolderChangesALot() {
        var profile = FolderProfile(path: "Documents/Bills", purpose: "bills", fileCount: 4)
        profile.purposeFileCount = 4
        #expect(!profile.needsPurpose)
        profile.fileCount = 5            // one more file: same folder
        #expect(!profile.needsPurpose)
        profile.fileCount = 9            // more than doubled
        #expect(profile.needsPurpose)
    }

    @Test func eachFileIsOfferedTheMostRelevantFolders() throws {
        var folders = FolderCatalog.universal(config)
        for index in 0..<40 {
            folders.append(FolderOption(path: "Documents/Topic \(index)", purpose: "notes about topic \(index)", tags: []))
        }
        folders.append(FolderOption(path: "Documents/Bills", purpose: "electricity and water bills", tags: [],
                                    examples: ["desco_sep.pdf"], kinds: ["pdf": 1], sources: ["desco.org.bd"]))
        var bill = facts(name: "bill_oct.pdf", text: "Electricity bill, October")
        bill.whereFroms = ["https://www.desco.org.bd/bill.pdf"]

        let offered = FolderCatalog.relevant(folders, to: bill, config: config)
        #expect(offered.count == FolderCatalog.maxOffered)
        #expect(offered.prefix(3).map(\.path) == [config.secure, config.reviewFolder, "Documents/Bills"])
    }

    @Test func thePromptHasNoPersonalDetails() {
        let folders = FolderCatalog.universal(config) + [
            FolderOption(path: "Documents/Bills", purpose: "electricity and water bills", tags: [], examples: ["desco_sep.pdf"]),
        ]
        let prompt = MLXClassifier.instructions(folders: folders, review: config.reviewFolder, newFolderParents: ["Documents"],
                                                corrections: [Correction(fileName: "notes.txt", wrongFolder: "Documents/Bills").sentence])
        for personal in ["North South", "NSU", "Formula", "economics", "Bangladesh"] {
            #expect(!prompt.contains(personal), "\(personal) in the prompt")
        }
        #expect(prompt.contains("Documents/Bills: electricity and water bills (holds e.g. desco_sep.pdf)"))
        #expect(prompt.contains("\"notes.txt\" does not belong in Documents/Bills"))
    }

    @Test func undoneModelMovesBecomeCorrections() {
        func record(_ name: String, to folder: String, by: String, _ state: MoveRecord.State) -> MoveRecord {
            MoveRecord(moveID: UUID(), batchID: UUID(), time: Date(), originalPath: "/x/Downloads/\(name)",
                       movedPath: home.appending(path: "\(folder)/\(name)").path, sha256: nil, tagsBefore: [], tagsAfter: [],
                       createdFolders: [], reason: nil, decidedBy: by, state: state)
        }
        let corrections = Correction.from([
            record("notes.txt", to: "Documents/FSAE", by: "model: apple", .undone),
            record("kept.pdf", to: "Documents/Bills", by: "model: apple", .moved),       // you kept it
            record("lecture.pdf", to: "Documents/Essays", by: "rule: course", .undone),  // a rule's, not the model's
        ], homeRoot: home)
        #expect(corrections == [Correction(fileName: "notes.txt", wrongFolder: "Documents/FSAE")])
    }

    @Test func anImageThatCouldntBeReadIsNeverFiledAsClean() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try make("Pictures/Downloaded Images")
        var image = facts(name: "IMG_1.jpg", text: "")
        image.kind = .image
        image.needsDeepRead = true      // text recognition failed
        let decision = await Planner(homeRoot: home).decide(image)
        #expect(decision.destination == config.reviewFolder)
        #expect(decision.source == .safety("unreadable"))
    }
}

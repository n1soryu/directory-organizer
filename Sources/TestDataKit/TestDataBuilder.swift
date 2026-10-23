import Foundation
import OrganizerCore
import UniformTypeIdentifiers

/// Where a fixture should end up with rules only. Used by the tests now, and as
/// the labeled set for the rules-vs-model evaluation in Milestone 5.
public struct ExpectedOutcome: Codable, Sendable {
    public var file: String
    /// Folder relative to the home root.
    public var folder: String
    public var name: String
    public var alerts: [String]
}

/// Builds a sandbox: `<root>/Downloads` full of realistic fake downloads, and
/// `<root>/Home` standing in for your home folder, with some files already filed.
public enum TestDataBuilder {
    /// Marks a folder as ours, so rebuilding may safely delete it.
    static let marker = ".file-organizer-testdata"

    /// Round 2: a few later downloads, added to a sandbox that's already there (round 1 planned
    /// and applied), so regrouping has earlier files to work with: a second electricity bill, a
    /// second appliance manual and a second shopping list. Never replaces a file. For checking
    /// the pipeline only: never use them, or anything about them, as prompt examples.
    public static func addRound2(at root: URL) throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appending(path: marker).path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "\(root.path) isn't a test data folder; run make-testdata first",
            ])
        }
        let downloads = root.appending(path: "Downloads")
        let names = ["desco_oct.pdf", "kettle_EK1700.pdf", "groceries.txt"]
        for name in names where fm.fileExists(atPath: downloads.appending(path: name).path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "\(name) is already in Downloads"])
        }
        try Drawing.textPDF(pages: [
            "Dhaka Electric Supply Company Limited (DESCO)\nElectricity Bill, October 2026\n\nAccount No: 12345678\nBilling period: 01 Oct 2026 to 31 Oct 2026\nUnits consumed: 198 kWh\nAmount payable: BDT 1,705\nDue date: 20 November 2026",
        ], to: downloads.appending(path: "desco_oct.pdf"))
        try Drawing.textPDF(pages: [
            "EK1700 Electric Kettle\nInstruction Manual\n\nSafety instructions\nFilling the kettle\nBoiling water\nDescaling and cleaning",
        ], title: "Electric Kettle Instruction Manual", to: downloads.appending(path: "kettle_EK1700.pdf"))
        try "bread\nonions\ntea\nsoap\n".write(to: downloads.appending(path: "groceries.txt"), atomically: true, encoding: .utf8)
        return names
    }

    public static func build(at root: URL) throws -> [ExpectedOutcome] {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            let contents = try fm.contentsOfDirectory(atPath: root.path)
            guard contents.isEmpty || contents.contains(marker) else {
                throw CocoaError(.fileWriteFileExists, userInfo: [
                    NSLocalizedDescriptionKey: "\(root.path) exists and isn't a test data folder; refusing to replace it",
                ])
            }
            try fm.removeItem(at: root)
        }
        let downloads = root.appending(path: "Downloads")
        let home = root.appending(path: "Home")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: marker))

        let config = OrganizerConfig()
        for folder in ["Documents/University/ECO372", Builder.records, Builder.fsae, config.essays, config.secure,
                       "Movies", config.downloadedImages, config.reviewFolder, "Developer", "Music"] {
            try fm.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
        }

        let builder = Builder(downloads: downloads, home: home)
        try builder.makeAll()
        return builder.expected
    }
}

/// The sandbox owner's own tags. (The app has no rules for them: it learns folders and tags.)
extension Tag {
    public static let nsu = Tag("NSU", .blue)
    public static let fsae = Tag("FSAE", .green)
}

private final class Builder {
    /// The sandbox owner's university and team folders. No rule knows them any more: without the
    /// model their new files go to review; with it, the model learns these folders from what's in them.
    static let records = "Documents/University/Records"
    static let fsae = "Documents/FSAE"

    let downloads: URL
    let home: URL
    let config = OrganizerConfig()
    let today = FileNames.day(Date())
    let month = FileNames.month(Date())
    var expected: [ExpectedOutcome] = []

    init(downloads: URL, home: URL) {
        self.downloads = downloads
        self.home = home
    }

    func file(_ name: String) -> URL { downloads.appending(path: name) }

    func expect(_ name: String, _ folder: String, _ finalName: String? = nil, alerts: [Alert.Kind] = []) {
        expected.append(ExpectedOutcome(file: name, folder: folder, name: finalName ?? name,
                                        alerts: alerts.map(\.rawValue)))
    }

    func from(_ url: URL, _ sources: String...) throws {
        try WhereFroms.write(sources, to: url)
    }

    func makeAll() throws {
        try alreadyFiled()
        try university()
        try fsae()
        try media()
        try sensitive()
        try installersAndCode()
        try leftovers()
        try folders()
    }

    // MARK: Your folders, already in use (what folder profiles learn from)

    func alreadyFiled() throws {
        let fm = FileManager.default
        func place(_ folder: String, _ name: String, tags: [Tag] = [], source: String? = nil,
                   make: (URL) throws -> Void) throws {
            let url = home.appending(path: "\(folder)/\(name)")
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try make(url)
            if !tags.isEmpty { try FinderTags.writeRaw(tags.map(FinderTags.encode), to: url) }
            if let source { try WhereFroms.write([source], to: url) }
        }

        try place(Self.fsae, "2026-09 FSAE Meeting Minutes.docx", tags: [.fsae]) {
            try Zipper.docx(paragraphs: ["NSU Formula SAE Team: Meeting Minutes", "Frame jig ordered. Brake supplier shortlisted."], to: $0)
        }
        try place(Self.fsae, "Chassis Design Review.pdf", tags: [.fsae]) {
            try Drawing.textPDF(pages: ["Formula SAE Chassis Design Review\nSpaceframe, 4130 steel\nTorsional stiffness target: 2000 Nm/deg"], to: $0)
        }
        try place(Self.fsae, "Sponsorship Deck Notes.docx", tags: [.fsae]) {
            try Zipper.docx(paragraphs: ["Sponsorship deck: tiers, logo placement, team photo"], to: $0)
        }

        try place(config.essays, "Urban transport essay.docx", tags: [.personal]) {
            try Zipper.docx(paragraphs: ["Why Dhaka needs bus rapid transit", "Traffic costs the city millions of working hours each year."], to: $0)
        }
        try place(config.essays, "Reflection on microfinance.docx", tags: [.personal]) {
            try Zipper.docx(paragraphs: ["Microfinance and women's empowerment: a reflection", "Group lending changed how credit reaches villages."], to: $0)
        }

        for (name, text) in [("ECO372 Lecture 04.pdf", "ECO 372 Introduction to Econometrics\nLecture 4: Multicollinearity"),
                             ("ECO372 Problem Set 2.pdf", "ECO 372 Introduction to Econometrics\nProblem Set 2: OLS assumptions")] {
            try place("Documents/University/ECO372", name, tags: [.nsu], source: "https://www.northsouth.edu/eco372") {
                try Drawing.textPDF(pages: [text], to: $0)
            }
        }
        try place("\(Self.records)/Grades", "2026-02-10 Grade History.pdf", tags: [.nsu],
                  source: "https://rds2.northsouth.edu/index.php/common/grade_history") {
            try Drawing.textPDF(pages: ["North South University\nGrade History\n\nFall 2025  ECO 101  A"], to: $0)
        }

        for name in ["Inception (2010).mp4", "Interstellar (2014).mkv"] {
            try place(config.films, name) { try Data("fake video \(name)".utf8).write(to: $0) }
        }
        try place("Music", "Lofi Study Mix.mp3") { try Data("fake audio".utf8).write(to: $0) }
    }

    // MARK: University (no rules: review without the model; with it, your course folders are learned)

    func university() throws {
        // A lecture, an identical second download, and an older different version already filed.
        let lecture = file("ECO372 Lecture 05.pdf")
        try Drawing.textPDF(pages: [
            "ECO 372 Introduction to Econometrics\nLecture 5: Heteroskedasticity\n\nWhen the variance of the error term differs across observations, OLS is still unbiased but the usual standard errors are wrong. We test for it with the Breusch-Pagan and White tests and fix it with robust standard errors.",
            "Example: wage regressions. Larger firms show more spread in wages, so the residual plot fans out as firm size grows.",
        ], to: lecture)
        try FileManager.default.copyItem(at: lecture, to: file("ECO372 Lecture 05 (1).pdf"))
        try Drawing.textPDF(pages: ["ECO 372 Introduction to Econometrics\nLecture 5 (last year's slides)"],
                            to: home.appending(path: "Documents/University/ECO372/ECO372 Lecture 05.pdf"))
        expect("ECO372 Lecture 05.pdf", config.reviewFolder)
        expect("ECO372 Lecture 05 (1).pdf", config.reviewFolder, alerts: [.duplicate])

        // An unclear name: only the content says it's the ECO201 outline.
        let outline = file("document (3).pdf")
        try Drawing.textPDF(pages: [
            "North South University\nDepartment of Economics\n\nECO 201: Intermediate Microeconomic Theory I\nCourse Outline, Fall 2026\n\nPrerequisites: ECO 101 and ECO 135\n\nThis course covers consumer choice, production and cost, market structure and an introduction to general equilibrium. Assessment: two midterms, a final and weekly problem sets.",
        ], to: outline)
        try from(outline, "https://www.northsouth.edu/files/eco/ECO201-outline-fall26.pdf")
        expect("document (3).pdf", config.reviewFolder)

        // Records from the university's portal.
        let grades = file("GradeHistory.pdf")
        try Drawing.textPDF(pages: ["North South University\nGrade History\n\nSpring 2026  ECO 104  A-\nSummer 2026  ECO 172  B+"], to: grades)
        try from(grades, "https://rds2.northsouth.edu/index.php/common/grade_history", "https://rds2.northsouth.edu/")
        expect("GradeHistory.pdf", config.reviewFolder)

        let curriculum = file("Curriculum_BS_Economics.pdf")
        try Drawing.textPDF(pages: [
            "DEPARTMENT OF ECONOMICS\nCurriculum of BS in Economics\n\nENG 103 ENG 105 BUS 251 BEN 205 PHI 101 HIS 103 ECO 101 ECO 104 MIS 107 ECO 172 ECO 135 ECO 173 MAT 125 ECO 245 ECO 201 ECO 204 ECO 301 ECO 304 ECO 372 ECO 490",
        ], title: "BS in Economics", to: curriculum)
        try from(curriculum, "https://www.northsouth.edu/newassets/images/Eco/curriculum.pdf")
        expect("Curriculum_BS_Economics.pdf", config.reviewFolder)

        // The course is only in the slide text.
        try Zipper.pptx(slides: [
            ["ECO 204 Intermediate Macroeconomic Theory I", "Week 3: The IS-LM model"],
            ["Goods market equilibrium", "Money market equilibrium"],
        ], to: file("Week3_Slides.pptx"))
        expect("Week3_Slides.pptx", config.reviewFolder)

        // A course with no folder yet.
        try Drawing.textPDF(pages: ["Some notes from a class I might take next semester."], to: file("MAT999 notes.pdf"))
        expect("MAT999 notes.pdf", config.reviewFolder)
    }

    // MARK: FSAE (no rules either)

    func fsae() throws {
        // A phone scan with no text layer: needs OCR.
        try Drawing.scannedPDF(text: """
            NSU FORMULA SAE TEAM
            Meeting Minutes
            12 October 2026

            Attendees: chassis, powertrain and business leads
            1. Chassis: frame jig welded, torsion test next week
            2. Powertrain: intake manifold reprint
            3. Business: sponsorship deck due Friday
            """, to: file("scan0001.pdf"))
        expect("scan0001.pdf", config.reviewFolder)

        try Zipper.docx(paragraphs: [
            "NSU Formula SAE Team: Meeting Minutes",
            "Suspension geometry review moved to Thursday.",
            "Budget request for brake calipers approved.",
        ], to: file("minutes_oct.docx"))
        expect("minutes_oct.docx", config.reviewFolder)

        try Zipper.xlsx(strings: ["Item", "Cost (BDT)", "Brake calipers", "Tyres", "Fuel pump"], to: file("FSAE_Budget_2026.xlsx"))
        expect("FSAE_Budget_2026.xlsx", config.reviewFolder)
    }

    // MARK: Films, TV, images

    func media() throws {
        // Not real video data: the names are what matters here.
        for name in ["Avengers_Infinity_War_4K_BluRay.mpeg", "Severance.S01E04.1080p.WEB-DL.x265-GROUP.mkv",
                     "The.Matrix.1999.1080p.BluRay.x264-YIFY.mp4"] {
            try Data("fake video \(name)".utf8).write(to: file(name))
        }
        expect("Avengers_Infinity_War_4K_BluRay.mpeg", config.films, "Avengers Infinity War.mpeg")
        expect("Severance.S01E04.1080p.WEB-DL.x265-GROUP.mkv", "\(config.tvShows)/Severance", "Severance S01E04.mkv")
        expect("The.Matrix.1999.1080p.BluRay.x264-YIFY.mp4", config.films, "The Matrix (1999).mp4")

        try Drawing.picture(seed: 1, type: .png, to: file("IMG_4821.png"))
        expect("IMG_4821.png", config.downloadedImages)

        let screenshot = file("Screenshot 2026-10-12 at 21.14.03.png")
        try Drawing.textImage("Router admin\nWireless settings\nChannel: auto", to: screenshot)
        try ScreenCapture.mark(screenshot)
        expect("Screenshot 2026-10-12 at 21.14.03.png", config.downloadedImages)

        // Already in Pictures, byte for byte.
        let wallpaper = file("wallpaper.jpg")
        try Drawing.picture(seed: 7, to: wallpaper)
        try FileManager.default.copyItem(at: wallpaper, to: home.appending(path: "\(config.downloadedImages)/wallpaper.jpg"))
        expect("wallpaper.jpg", config.reviewFolder, alerts: [.duplicate])
    }

    // MARK: Sensitive (all fake, generated fresh each time, never committed)

    func sensitive() throws {
        // 12 random BIP-39 words: the same shape as a real recovery phrase, but random.
        var generator = SystemRandomNumberGenerator()
        let words = (0..<12).map { _ in BIP39.orderedWords.randomElement(using: &generator)! }
        let phrase = words.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        try Drawing.textImage("Wallet backup\n\n" + phrase, width: 900, height: 1300, fontSize: 44, type: .jpeg, to: file("IMG_5012.jpg"))
        expect("IMG_5012.jpg", config.secure, "\(today) Recovery Phrase.jpg", alerts: [.sensitive])

        try """
            name,url,username,password,note
            example.com,https://example.com/login,student@example.com,FAKE-not-a-real-password-1,
            test.org,https://test.org/,me@example.com,FAKE-not-a-real-password-2,
            """.write(to: file("Chrome Passwords.csv"), atomically: true, encoding: .utf8)
        expect("Chrome Passwords.csv", config.reviewFolder, alerts: [.sensitive])

        let body = (0..<6).map { _ in
            Data((0..<52).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        }.joined(separator: "\n")
        try "-----BEGIN OPENSSH PRIVATE KEY-----\n\(body)\n-----END OPENSSH PRIVATE KEY-----\n"
            .write(to: file("id_ed25519"), atomically: true, encoding: .utf8)
        expect("id_ed25519", config.secure, alerts: [.sensitive])
    }

    // MARK: Installers, firmware, code

    func installersAndCode() throws {
        for (name, source) in [
            ("Archer_AX55v1_firmware.bin", "https://static.tp-link.com/upload/firmware/Archer_AX55v1.zip"),
            ("Docker.dmg", "https://desktop.docker.com/mac/main/arm64/Docker.dmg"),
            ("Zoom.pkg", "https://zoom.us/client/latest/Zoom.pkg"),
        ] {
            try Data("fake installer \(name)".utf8 + Array(repeating: 0xA5, count: 2048)).write(to: file(name))
            try from(file(name), source)
            expect(name, config.reviewFolder)
        }

        try Zipper.zip(files: [
            "ig-follow-audit-main/Package.swift": "// swift-tools-version: 6.0\nimport PackageDescription\n",
            "ig-follow-audit-main/Sources/App/main.swift": "print(\"hello\")\n",
        ], to: file("ig-follow-audit-main.zip"))
        try from(file("ig-follow-audit-main.zip"), "https://codeload.github.com/n1soryu/ig-follow-audit/zip/refs/heads/main")
        expect("ig-follow-audit-main.zip", config.reviewFolder)
    }

    // MARK: Leftovers (no rule applies; the model handles these from Milestone 3)

    func leftovers() throws {
        try Zipper.zip(files: ["beach.txt": "pretend photo", "sunset.txt": "pretend photo"], to: file("photos.zip"))
        expect("photos.zip", config.reviewFolder)

        try Zipper.docx(paragraphs: [
            "Why cities should plant more trees",
            "Urban heat islands raise summer temperatures by several degrees. Street trees shade pavements and cool the air through evaporation.",
        ], title: "Climate essay draft", to: file("Climate essay draft.docx"))
        expect("Climate essay draft.docx", config.reviewFolder)

        try "eggs\nmilk\nrice\nlentils\n".write(to: file("notes.txt"), atomically: true, encoding: .utf8)
        expect("notes.txt", config.reviewFolder)

        // No folder exists for these yet: the model may propose one ("Manuals", "Bills").
        try Drawing.textPDF(pages: [
            "Archer AX55 AX3000 Dual Band Gigabit Wi-Fi 6 Router\nUser Guide\n\nChapter 1: Get to Know About Your Router\nChapter 2: Connect the Hardware\nChapter 3: Log In to Your Router\nChapter 4: Set Up Internet Connection",
        ], title: "Archer AX55 User Guide", to: file("AX55_UserGuide.pdf"))
        try from(file("AX55_UserGuide.pdf"), "https://static.tp-link.com/upload/manual/Archer_AX55_UG.pdf")
        expect("AX55_UserGuide.pdf", config.reviewFolder)

        try Drawing.textPDF(pages: [
            "Dhaka Electric Supply Company Limited (DESCO)\nElectricity Bill, September 2026\n\nAccount No: 12345678\nBilling period: 01 Sep 2026 to 30 Sep 2026\nUnits consumed: 214 kWh\nAmount payable: BDT 1,842\nDue date: 20 October 2026",
        ], to: file("bill_sep.pdf"))
        expect("bill_sep.pdf", config.reviewFolder)

        // Homework for a course you have a folder for, under a name that says nothing.
        let homework = file("download.pdf")
        try Drawing.textPDF(pages: [
            "ECO 372 Introduction to Econometrics\nHomework: Instrumental Variables\n\n1. Explain why OLS is inconsistent when a regressor is correlated with the error term.\n2. Estimate the returns to education using distance to college as an instrument.",
        ], to: homework)
        expect("download.pdf", config.reviewFolder)

        // Still downloading: must be skipped (and the folders below are made after it).
        try Data(repeating: 0, count: 100).write(to: file("bigfile.zip.crdownload"))
    }

    // MARK: Folders (whole trees; without a model they stay together)

    func folders() throws {
        let fm = FileManager.default
        func write(_ text: String, _ path: String) throws {
            let url = file(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        // An unzipped GitHub download: a code project, kept whole and parked in review.
        try write("{\"name\": \"todo-app\", \"version\": \"1.0.0\"}\n", "todo-app-main/package.json")
        try write("console.log('hello')\n", "todo-app-main/src/index.js")
        expect("todo-app-main", config.reviewFolder)

        // A recovery phrase two levels down: the folder is flagged and stays whole in review.
        var generator = SystemRandomNumberGenerator()
        let words = (0..<12).map { _ in BIP39.orderedWords.randomElement(using: &generator)! }
        try write(words.joined(separator: " ") + "\n", "Old phone backup/notes/seed.txt")
        try write("Shopping: rice, lentils\n", "Old phone backup/notes/list.txt")
        expect("Old phone backup", config.reviewFolder, alerts: [.sensitive])

        try fm.createDirectory(at: file("New Folder"), withIntermediateDirectories: true)
        expect("New Folder", config.reviewFolder)

        // Unrelated things in one folder: the model should unpack this one.
        try fm.createDirectory(at: file("Misc downloads"), withIntermediateDirectories: true)
        try Drawing.textPDF(pages: [
            "Dhaka WASA\nWater Bill, September 2026\n\nAccount No: 99887766\nAmount payable: BDT 640\nDue date: 25 October 2026",
        ], to: file("Misc downloads/wasa_bill.pdf"))
        try Drawing.textPDF(pages: [
            "Philips HD9252 Airfryer\nUser Manual\n\nImportant safety information\nBefore first use\nUsing the appliance",
        ], title: "Airfryer User Manual", to: file("Misc downloads/HD9252_manual.pdf"))
        try "Lab 3 notes: bring calculator\n".write(to: file("Misc downloads/reminder.txt"), atomically: true, encoding: .utf8)
        expect("Misc downloads", config.reviewFolder)

        // A film with its extras: one thing.
        let film = "Dune.Part.Two.2024.1080p.WEB-DL"
        try fm.createDirectory(at: file(film), withIntermediateDirectories: true)
        // Still not real video, but by far the biggest file, as a film is.
        try (Data("fake video \(film)".utf8) + Data(repeating: 0x5A, count: 64 * 1024)).write(to: file("\(film)/\(film).mp4"))
        try write("1\n00:00:01,000 --> 00:00:04,000\nThe spice must flow.\n", "\(film)/\(film).en.srt")
        try write("Release notes\n", "\(film)/\(film).nfo")
        expect(film, config.reviewFolder)

        // Downloaded a while ago, so none of them counts as still being written.
        let past = Date().addingTimeInterval(-600)
        for name in ["todo-app-main", "Old phone backup", "New Folder", "Misc downloads", film] {
            let top = file(name)
            let inside = fm.enumerator(at: top, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            for url in inside.reversed() + [top] {
                try fm.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
            }
        }
    }
}

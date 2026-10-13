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
        for folder in ["Documents/University/ECO372", config.records, config.fsae, config.essays, config.secure,
                       "Movies", config.downloadedImages, config.reviewFolder, "Developer", "Music"] {
            try fm.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
        }

        let builder = Builder(downloads: downloads, home: home)
        try builder.makeAll()
        return builder.expected
    }
}

private final class Builder {
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
        try university()
        try fsae()
        try media()
        try sensitive()
        try installersAndCode()
        try leftovers()
    }

    // MARK: University

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
        expect("ECO372 Lecture 05.pdf", "Documents/University/ECO372", "ECO372 Lecture 05 (\(today)).pdf", alerts: [.nameClash])
        expect("ECO372 Lecture 05 (1).pdf", config.reviewFolder, alerts: [.duplicate])

        // An unclear name: only the content says it's the ECO201 outline.
        let outline = file("document (3).pdf")
        try Drawing.textPDF(pages: [
            "North South University\nDepartment of Economics\n\nECO 201: Intermediate Microeconomic Theory I\nCourse Outline, Fall 2026\n\nPrerequisites: ECO 101 and ECO 135\n\nThis course covers consumer choice, production and cost, market structure and an introduction to general equilibrium. Assessment: two midterms, a final and weekly problem sets.",
        ], to: outline)
        try from(outline, "https://www.northsouth.edu/files/eco/ECO201-outline-fall26.pdf")
        expect("document (3).pdf", "Documents/University/ECO201", "ECO201 Course Outline.pdf")

        // Records: dated with the download date, kept side by side.
        let grades = file("GradeHistory.pdf")
        try Drawing.textPDF(pages: ["North South University\nGrade History\n\nSpring 2026  ECO 104  A-\nSummer 2026  ECO 172  B+"], to: grades)
        try from(grades, "https://rds2.northsouth.edu/index.php/common/grade_history", "https://rds2.northsouth.edu/")
        expect("GradeHistory.pdf", "\(config.records)/Grades", "\(today) Grade History.pdf")

        let curriculum = file("Curriculum_BS_Economics.pdf")
        try Drawing.textPDF(pages: [
            "DEPARTMENT OF ECONOMICS\nCurriculum of BS in Economics\n\nENG 103 ENG 105 BUS 251 BEN 205 PHI 101 HIS 103 ECO 101 ECO 104 MIS 107 ECO 172 ECO 135 ECO 173 MAT 125 ECO 245 ECO 201 ECO 204 ECO 301 ECO 304 ECO 372 ECO 490",
        ], title: "BS in Economics", to: curriculum)
        try from(curriculum, "https://www.northsouth.edu/newassets/images/Eco/curriculum.pdf")
        expect("Curriculum_BS_Economics.pdf", "\(config.records)/Curriculum", "\(today) Curriculum BS Economics.pdf")

        // Course found from the slide text.
        try Zipper.pptx(slides: [
            ["ECO 204 Intermediate Macroeconomic Theory I", "Week 3: The IS-LM model"],
            ["Goods market equilibrium", "Money market equilibrium"],
        ], to: file("Week3_Slides.pptx"))
        expect("Week3_Slides.pptx", "Documents/University/ECO204")

        // A course code that isn't in the course list.
        try Drawing.textPDF(pages: ["Some notes from a class I might take next semester."], to: file("MAT999 notes.pdf"))
        expect("MAT999 notes.pdf", config.reviewFolder, alerts: [.unknownCourse])
    }

    // MARK: FSAE

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
        expect("scan0001.pdf", config.fsae, "\(month) FSAE Meeting Minutes.pdf")

        try Zipper.docx(paragraphs: [
            "NSU Formula SAE Team: Meeting Minutes",
            "Suspension geometry review moved to Thursday.",
            "Budget request for brake calipers approved.",
        ], to: file("minutes_oct.docx"))
        expect("minutes_oct.docx", config.fsae)

        try Zipper.xlsx(strings: ["Item", "Cost (BDT)", "Brake calipers", "Tyres", "Fuel pump"], to: file("FSAE_Budget_2026.xlsx"))
        expect("FSAE_Budget_2026.xlsx", config.fsae)
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

        // Still downloading: must be skipped.
        try Data(repeating: 0, count: 100).write(to: file("bigfile.zip.crdownload"))
    }
}

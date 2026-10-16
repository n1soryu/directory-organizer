import Foundation
import Testing
@testable import OrganizerCore

@Suite struct NameQualityTests {
    @Test(arguments: ["document (3)", "IMG_4821", "scan0001", "DSC01234", "Untitled", "download",
                      "a8f3c9e1b2d4e5f60718293a4b5c6d7e", "1697203345", "20261013_142233", "x"])
    func unclear(_ name: String) {
        #expect(NameQuality.isUnclear(name))
    }

    @Test(arguments: ["ECO372 Lecture 05", "GradeHistory", "Chrome Passwords", "minutes_oct", "Week3_Slides",
                      "Screenshot 2026-10-12 at 21.14.03", "id_ed25519", "Docker", "notes"])
    func clear(_ name: String) {
        #expect(!NameQuality.isUnclear(name))
    }

    @Test func stripsCopySuffixes() {
        #expect(NameQuality.stripCopySuffix("report (3)") == "report")
        #expect(NameQuality.stripCopySuffix("notes copy 2") == "notes")
        #expect(NameQuality.stripCopySuffix("ECO372 Lecture 05") == "ECO372 Lecture 05")
    }
}

@Suite struct MediaNameTests {
    @Test(arguments: [
        ("Avengers_Infinity_War_4K_BluRay", "Avengers Infinity War"),
        ("The.Matrix.1999.1080p.BluRay.x264-YIFY", "The Matrix (1999)"),
        ("Severance.S01E04.1080p.WEB-DL.x265-GROUP", "Severance S01E04"),
        ("Severance.S01.E04.1080p.WEB-DL", "Severance S01E04"),           // marker split by a dot
        ("Blade.Runner.2049.2017.1080p.BluRay", "Blade Runner 2049 (2017)"), // 2049 is title
        ("Blade Runner 2049", "Blade Runner 2049"),
        ("CSI.MIAMI.S02E05.720p", "CSI Miami S02E05"),
        ("the.office.us.s02e01.720p.hdtv", "The Office Us S02E01"),
        ("Mad.Max.Fury.Road.2015.2160p.UHD.BluRay", "Mad Max Fury Road (2015)"),
        ("2001.A.Space.Odyssey.1968.1080p", "2001 A Space Odyssey (1968)"),
        ("[YTS.MX] Dune Part Two (2024) [1080p]", "Dune Part Two (2024)"),
        ("Holiday clip", "Holiday clip"),
    ])
    func cleans(_ input: String, _ expected: String) {
        #expect(MediaNameCleaner.parse(input).displayName == expected)
    }

    @Test func releaseTags() {
        #expect(MediaNameCleaner.hasReleaseTags("Avengers_Infinity_War_4K_BluRay"))
        #expect(!MediaNameCleaner.hasReleaseTags("Holiday clip"))
        #expect(!MediaNameCleaner.hasReleaseTags("Mad Max"))
    }
}

@Suite struct FileNameTests {
    @Test func sanitizes() {
        #expect(FileNames.sanitize("a/b:c") == "a-b-c")
        #expect(FileNames.sanitize("..hidden") == "hidden")
        #expect(FileNames.sanitize("  spaced   out  ") == "spaced out")
        #expect(FileNames.sanitize("line\nbreak") == "line break")      // a line break separates words
        #expect(FileNames.sanitize(String(repeating: "x", count: 200)).count == FileNames.maxBaseLength)
    }

    @Test func humanizes() {
        #expect(FileNames.humanize("GradeHistory") == "Grade History")
        #expect(FileNames.humanize("Curriculum_BS_Economics") == "Curriculum BS Economics")
        #expect(FileNames.humanize("ECO372 Lecture 05") == "ECO372 Lecture 05")
    }

    @Test func clashNamesAddTheDate() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 13))!
        let names = FileNames.clashAlternatives("Report", "pdf", date: date)
        #expect(names.prefix(2) == ["Report (2026-10-13).pdf", "Report (2026-10-13) 2.pdf"])
        // A name that already carries the date just gets a counter.
        #expect(FileNames.clashAlternatives("2026-10-13 Grade History", "pdf", date: date).first
                == "2026-10-13 Grade History 2.pdf")
    }
}

/// MED-27, MED-28, MED-31, LOW-13/14/15: names the filesystem and Finder will accept as meant.
@Suite struct NameSafetyTests {
    @Test func longNamesFitTheFilesystem() {
        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 80)        // 80 characters, 25 bytes each
        #expect(FileNames.sanitize(emoji).utf8.count <= FileNames.maxBaseBytes)
        let dotted = String(repeating: "a", count: 79) + ".b"
        #expect(!FileNames.sanitize(dotted).hasSuffix("."))
    }

    @Test func invisibleAndControlCharacters() {
        #expect(FileNames.sanitize("Hello\nWorld") == "Hello World")
        #expect(FileNames.sanitize("invoice\u{202E}fdp.exe") == "invoicefdp.exe")
        #expect(FileNames.sanitize("Cafe\u{301}") == FileNames.sanitize("Café"))
    }

    @Test func datesAreGregorianWhateverTheMacsCalendar() {
        let date = Date(timeIntervalSince1970: 1_791_900_000)     // 2026-10-13
        #expect(FileNames.day(date).hasPrefix("2026-"))
    }
}

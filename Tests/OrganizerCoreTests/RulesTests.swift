import Foundation
import Testing
@testable import OrganizerCore

@Suite struct CourseCatalogTests {
    let courses = CourseCatalog.bsEconomics

    @Test func normalizesCodes() {
        #expect(CourseCatalog.codes(in: "eco 101, ECO-104 and PHY107L, ECO_372") == ["ECO101", "ECO104", "PHY107", "ECO372"])
        // Not course codes: camera counters, longer numbers, letters glued on.
        #expect(CourseCatalog.codes(in: "IMG_4821 AX55v1 SAE2026 x264") == [])
    }

    @Test func uppercaseOnlyForFileNames() {
        #expect(CourseCatalog.codes(in: "abc123 notes", uppercaseOnly: true) == [])
        #expect(CourseCatalog.codes(in: "MAT999 notes", uppercaseOnly: true) == ["MAT999"])
    }

    @Test func curriculumCourses() {
        #expect(courses.contains("ECO372"))
        #expect(courses.contains("MAT125"))
        #expect(!courses.contains("CSE115"))
        #expect(courses.titles.count == 50)
    }

    @Test func findsCourseByTitle() {
        #expect(courses.codeByTitle(in: "Slides for Introduction to Econometrics, week 2") == "ECO372")
        // "Intermediate Microeconomic Theory II" must not be read as "... Theory I".
        #expect(courses.codeByTitle(in: "Intermediate Microeconomic Theory II midterm") == "ECO301")
        #expect(courses.codeByTitle(in: "Biology I notes") == nil)
    }
}

@Suite struct RuleOrderTests {
    let engine = RulesEngine.standard
    let config = OrganizerConfig()

    @Test func recoveryPhraseImageGoesToSecureNotPictures() {
        let phrase = BIP39.orderedWords.prefix(12).joined(separator: " ")
        let decision = engine.decide(facts(name: "IMG_9.jpg", text: phrase), config: config)
        #expect(decision?.destination == config.secure)
        #expect(decision?.alerts.first?.kind == .sensitive)
    }

    @Test func courseFileBeatsRecordWords() {
        var item = facts(name: "ECO201 registration notes.pdf", text: "ECO 201 notes")
        item.whereFroms = ["https://www.northsouth.edu/x.pdf"]
        // "registration" in the name of an NSU file is a record...
        #expect(engine.decide(item, config: config)?.destination == "\(config.records)/Registration")
        // ...but in the text, the course wins.
        item = facts(name: "ECO201 week 4.pdf", text: "ECO 201\nCourse registration closes Friday")
        item.whereFroms = ["https://www.northsouth.edu/x.pdf"]
        #expect(engine.decide(item, config: config)?.destination == "\(config.university)/ECO201")
    }

    @Test func curriculumIsNotACourse() {
        let codes = ["ECO101", "ECO104", "ECO201", "ECO204", "ECO301", "ECO304", "ECO372"].joined(separator: " ")
        var item = facts(name: "BS in Economics Curriculum.pdf", text: "Curriculum\n" + codes)
        item.whereFroms = ["https://www.northsouth.edu/newassets/images/Eco/curriculum.pdf"]
        let decision = engine.decide(item, config: config)
        #expect(decision?.destination == "\(config.records)/Curriculum")
        #expect(decision?.newBaseName?.hasSuffix(" BS in Economics Curriculum") == true)
    }

    @Test func recordsNeedNSUContext() {
        // A YouTube transcript is not an NSU record.
        #expect(engine.decide(facts(name: "lecture transcript.txt", text: "so today we..."), config: config) == nil)
    }

    @Test func videosByLength() {
        var clip = facts(name: "holiday.mov", text: nil)
        clip.media = MediaInfo(duration: 95, title: nil)
        #expect(engine.decide(clip, config: config)?.destination == config.clips)

        var film = facts(name: "some film.mp4", text: nil)
        film.media = MediaInfo(duration: 2 * 3600, title: nil)
        #expect(engine.decide(film, config: config)?.destination == config.films)
    }

    @Test func installersAndFirmwareGoToReview() {
        for name in ["Docker.dmg", "ubuntu.iso", "Zoom.pkg", "router.bin"] {
            #expect(engine.decide(facts(name: name, text: nil), config: config)?.destination == config.reviewFolder)
        }
    }
}

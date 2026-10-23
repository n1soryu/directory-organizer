import Foundation
import Testing
@testable import OrganizerCore

@Suite struct RuleOrderTests {
    let engine = RulesEngine.standard
    let config = OrganizerConfig()

    @Test func recoveryPhraseImageGoesToSecureNotPictures() {
        let phrase = BIP39.orderedWords.prefix(12).joined(separator: " ")
        let decision = engine.decide(facts(name: "IMG_9.jpg", text: phrase), config: config)
        #expect(decision?.destination == config.secure)
        #expect(decision?.alerts.first?.kind == .sensitive)
    }

    /// No personal rules: course files, university records and team files are the model's to
    /// place, by what it learns from your folders.
    @Test func personalFilesAreLeftToTheModel() {
        var record = facts(name: "GradeHistory.pdf", text: "Grade History\nSpring 2026  ECO 104  A-")
        record.whereFroms = ["https://rds2.example.edu/grade_history"]
        let course = facts(name: "ECO201 week 4.pdf", text: "ECO 201\nCourse registration closes Friday")
        let team = facts(name: "FSAE_Budget_2026.xlsx", text: "Item Cost Brake calipers")
        for item in [record, course, team] {
            #expect(engine.decide(item, config: config) == nil, "\(item.name)")
        }
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

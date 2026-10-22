import Foundation
import PDFKit
import Testing
@testable import OrganizerCore

/// Files that are hard to read: hostile, locked, huge or in another encoding. Unread must never
/// count as clean.
@Suite(.serialized) struct ReadingTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "file-organizer-reading-\(UUID().uuidString)")

    func file(_ name: String, _ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: name)
        try data.write(to: url)
        return url
    }

    /// HIGH-6: a page 10^19 points wide used to crash the app when rendered for OCR.
    @Test func aPDFWithAnAbsurdPageSizeDoesntCrash() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = """
            %PDF-1.4
            1 0 obj <</Type/Catalog/Pages 2 0 R>> endobj
            2 0 obj <</Type/Pages/Kids[3 0 R]/Count 1>> endobj
            3 0 obj <</Type/Page/Parent 2 0 R/MediaBox[0 0 10000000000000000000 10000000000000000000]>> endobj
            trailer <</Root 1 0 R>>
            %%EOF
            """
        let url = try file("scan.pdf", Data(pdf.utf8))
        let images = PDFText.renderPages(url, maxPages: 1)
        #expect(images.allSatisfy { CGFloat($0.width) <= PDFText.maxRenderSide && CGFloat($0.height) <= PDFText.maxRenderSide })
        _ = await FactExtractor().facts(for: url)        // reaching here is the test
    }

    /// HIGH-9: a password-protected PDF can't be read, so it can't be called clean.
    @Test func aLockedPDFIsUnreadableNotClean() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "statement.pdf")
        #expect(document.write(to: url, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
        let facts = await FactExtractor().facts(for: url)
        #expect(facts.needsDeepRead)
        #expect(facts.notes.contains("PDF is password-protected"))
        let decision = await Planner(homeRoot: root).decide(facts).decision
        #expect(decision?.destination == OrganizerConfig().reviewFolder)
        #expect(decision?.source == .safety("unreadable"))
    }

    /// HIGH-7: UTF-16 text used to be skipped as binary.
    @Test func aUTF16FileIsReadAndChecked() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n"
        for (name, data) in [("bom.txt", key.data(using: .utf16)!),                    // with a byte-order mark
                             ("plain.txt", key.data(using: .utf16LittleEndian)!)] {   // without one
            let facts = await FactExtractor().facts(for: try file(name, data))
            #expect(SensitiveDetector.check(facts)?.kind == .privateKey, "\(name)")
        }
    }

    /// HIGH-7/MED-1: a password export far bigger than the excerpt kept for the model.
    @Test func aBigPasswordExportIsStillCaught() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var csv = "name,url,username,password\n"
        while csv.utf8.count < 700_000 { csv += "site,https://example.com,me@example.com,FAKE-password\n" }
        let facts = await FactExtractor().facts(for: try file("passwords.csv", Data(csv.utf8)))
        #expect((facts.text?.count ?? 0) <= FactExtractor().deepTextLimit)
        #expect(SensitiveDetector.check(facts)?.kind == .unencryptedPasswordExport)
    }

    /// MED-1: a key well past the excerpt is found too.
    @Test func aKeyPastTheExcerptIsFound() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "Meeting notes, nothing to see here.\n", count: 400)
            + "-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----\n"
        let facts = await FactExtractor().facts(for: try file("notes.txt", Data(text.utf8)))
        #expect(SensitiveDetector.check(facts)?.kind == .privateKey)
    }
}

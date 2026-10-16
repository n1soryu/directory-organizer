import Foundation
import Testing
@testable import OrganizerCore

func facts(name: String, text: String?, kind: FileKind? = nil) -> FileFacts {
    let url = URL(filePath: "/tmp/\(name)")
    let ext = url.pathExtension.lowercased()
    return FileFacts(
        url: url, name: name, baseName: url.deletingPathExtension().lastPathComponent, fileExtension: ext,
        kind: kind ?? FileKind(fileExtension: ext, isDirectory: false), isDirectory: false, size: 100,
        whereFroms: [], text: text, isScreenshot: false,
        nameIsUnclear: NameQuality.isUnclear(url.deletingPathExtension().lastPathComponent), notes: []
    )
}

@Suite struct SensitiveDetectorTests {
    @Test(arguments: [
        "name,url,username,password,note",                                          // Chrome
        "Title,URL,Username,Password,Notes,OTPAuth",                                // Apple Passwords
        "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp", // Bitwarden
        "\"url\",\"username\",\"password\",\"httpRealm\",\"formActionOrigin\"",     // Firefox
    ])
    func passwordExports(_ header: String) {
        let finding = SensitiveDetector.check(facts(name: "export.csv", text: header + "\nexample.com,a,b,c,d"))
        #expect(finding?.kind == .unencryptedPasswordExport)
        #expect(finding?.belongsInReview == true)
    }

    @Test func ordinaryCSVIsFine() {
        #expect(SensitiveDetector.check(facts(name: "grades.csv", text: "course,grade,credits\nECO101,A,3")) == nil)
        // A password column alone (no site/user column) isn't an export.
        #expect(SensitiveDetector.check(facts(name: "x.csv", text: "id,password_policy\n1,strong")) == nil)
    }

    @Test func recoveryPhrase() {
        let words = Array(BIP39.orderedWords.shuffled().prefix(12))
        let numbered = words.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let finding = SensitiveDetector.check(facts(name: "IMG_1.jpg", text: "Wallet backup\n" + numbered))
        #expect(finding?.kind == .recoveryPhrase)
        #expect(finding?.belongsInReview == false)
    }

    @Test func tenWordsAreNotAPhrase() {
        let text = BIP39.orderedWords.prefix(10).joined(separator: " ")
        #expect(SensitiveDetector.check(facts(name: "a.txt", text: text)) == nil)
    }

    /// Text recognition misread one word of twelve (and split it in two).
    @Test func aPhraseWithOneMisreadWordIsStillCaught() {
        var words = Array(BIP39.orderedWords.shuffled().prefix(12))
        words[5] = "wa11xq"
        let text = "Wallet backup\n" + words.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        #expect(SensitiveDetector.longestRecoveryPhraseRun(in: text) ?? 0 < 12)
        #expect(SensitiveDetector.check(facts(name: "IMG_2.jpg", text: text))?.kind == .recoveryPhrase)
    }

    @Test func proseIsNotAPhrase() {
        let prose = """
            When the variance of the error term differs across observations, OLS is still unbiased but the
            usual standard errors are wrong. We test for it with the Breusch-Pagan and White tests and fix it
            with robust standard errors. Larger firms show more spread in wages, so the residual plot fans out.
            Urban heat islands raise summer temperatures by several degrees. Street trees shade pavements and
            cool the air through evaporation, which can lower energy bills during long hot seasons.
            """
        #expect((SensitiveDetector.longestRecoveryPhraseRun(in: prose) ?? 0) < 12)
        #expect(SensitiveDetector.check(facts(name: "lecture.pdf", text: prose)) == nil)
    }

    @Test func privateKeysButNotPublicOnes() {
        for header in ["-----BEGIN OPENSSH PRIVATE KEY-----", "-----BEGIN RSA PRIVATE KEY-----",
                       "-----BEGIN PRIVATE KEY-----", "-----BEGIN PGP PRIVATE KEY BLOCK-----"] {
            #expect(SensitiveDetector.check(facts(name: "key", text: header + "\nabc"))?.kind == .privateKey)
        }
        for header in ["-----BEGIN PUBLIC KEY-----", "-----BEGIN CERTIFICATE-----", "ssh-ed25519 AAAAC3Nz me@mac"] {
            #expect(SensitiveDetector.check(facts(name: "key.pub", text: header + "\nabc")) == nil)
        }
    }

    @Test func credentialFilesByExtension() {
        #expect(SensitiveDetector.check(facts(name: "vault.kdbx", text: nil))?.kind == .credentialFile)
        #expect(SensitiveDetector.check(facts(name: "work.ovpn", text: nil))?.kind == .credentialFile)
        #expect(SensitiveDetector.check(facts(name: "export.1pux", text: nil))?.kind == .unencryptedPasswordExport)
    }
}

@Suite struct DestinationValidatorTests {
    let config = OrganizerConfig()

    @Test(arguments: ["Documents/University/ECO372", "Movies/TV Shows/Severance", "Pictures/Wallpapers",
                      "Desktop/To Delete (Review)", "Developer/new-project"])
    func allowed(_ path: String) {
        #expect(DestinationValidator.problem(with: path, config: config) == nil)
    }

    @Test(arguments: ["", "/etc", "~/Documents", "Documents/../Library", "Library/Preferences",
                      "Documents/.hidden", "Pictures/Photos Library.photoslibrary/originals",
                      "Desktop", "Desktop/Other", "Downloads", "Documents//x", "Applications/Evil.app"])
    func rejected(_ path: String) {
        #expect(DestinationValidator.problem(with: path, config: config) != nil)
    }
}

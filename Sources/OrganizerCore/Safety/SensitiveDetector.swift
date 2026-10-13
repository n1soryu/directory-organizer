import Foundation

/// A sensitive file and what kind it is. Found by fixed checks only, never by the model.
public struct SensitiveFinding: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Passwords in plain text (CSV/JSON export). Goes to review so you can delete it.
        case unencryptedPasswordExport
        /// 12-24 BIP-39 words in a row: a crypto wallet recovery phrase.
        case recoveryPhrase
        /// "-----BEGIN ... PRIVATE KEY-----" and friends.
        case privateKey
        /// Credential/config files: certificates with keys, VPN profiles, password databases.
        case credentialFile
    }

    public var kind: Kind
    public var detail: String

    /// Unencrypted password exports go to review (you should delete them after importing);
    /// everything else is kept, in Secure.
    public var belongsInReview: Bool { kind == .unencryptedPasswordExport }
}

public enum SensitiveDetector {
    public static func check(_ facts: FileFacts) -> SensitiveFinding? {
        if let finding = byExtension(facts) { return finding }
        guard let text = facts.text, !text.isEmpty else { return nil }

        if let key = privateKey(in: text) {
            return SensitiveFinding(kind: .privateKey, detail: key)
        }
        if facts.kind == .csv, let columns = passwordExportColumns(in: text) {
            return SensitiveFinding(kind: .unencryptedPasswordExport,
                                    detail: "password manager export (columns: \(columns))")
        }
        if facts.fileExtension == "json", isPasswordJSON(text) {
            return SensitiveFinding(kind: .unencryptedPasswordExport, detail: "unencrypted password manager JSON export")
        }
        if let run = longestRecoveryPhraseRun(in: text), run >= 12 {
            return SensitiveFinding(kind: .recoveryPhrase, detail: "\(run) BIP-39 words in a row")
        }
        if facts.fileExtension == "conf", text.contains("[Interface]"), text.contains("PrivateKey") {
            return SensitiveFinding(kind: .credentialFile, detail: "WireGuard config with a private key")
        }
        return nil
    }

    // MARK: - Checks

    private static func byExtension(_ facts: FileFacts) -> SensitiveFinding? {
        switch facts.fileExtension {
        case "1pux", "1pif":
            SensitiveFinding(kind: .unencryptedPasswordExport, detail: "1Password export (.\(facts.fileExtension), not encrypted)")
        case "kdbx", "keychain-db":
            SensitiveFinding(kind: .credentialFile, detail: "encrypted password database (.\(facts.fileExtension))")
        case "p12", "pfx", "ppk":
            SensitiveFinding(kind: .credentialFile, detail: "certificate or key bundle (.\(facts.fileExtension))")
        case "ovpn", "mobileconfig":
            SensitiveFinding(kind: .credentialFile, detail: "VPN/configuration profile (.\(facts.fileExtension))")
        default:
            nil
        }
    }

    /// "-----BEGIN OPENSSH PRIVATE KEY-----", "-----BEGIN RSA PRIVATE KEY-----",
    /// "-----BEGIN PGP PRIVATE KEY BLOCK-----". Public keys and certificates don't count.
    static func privateKey(in text: String) -> String? {
        guard let range = text.range(of: #"-----BEGIN ([A-Z0-9 ]*)PRIVATE KEY( BLOCK)?-----"#,
                                     options: .regularExpression) else { return nil }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Header columns of a password manager CSV (Chrome, Safari/Passwords, Firefox,
    /// Bitwarden, 1Password, LastPass...), or nil if it isn't one.
    static func passwordExportColumns(in text: String) -> String? {
        guard let header = text.split(whereSeparator: \.isNewline).first else { return nil }
        let columns = header.split(separator: text.contains("\t") && !header.contains(",") ? "\t" : ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" \u{FEFF}")).lowercased() }
        let passwordColumns: Set<String> = ["password", "login_password", "pass", "passwd", "passwort"]
        let contextColumns: Set<String> = ["url", "login_uri", "username", "login_username", "name",
                                           "title", "website", "email", "hostname", "origin_url", "account"]
        guard columns.contains(where: passwordColumns.contains),
              columns.contains(where: contextColumns.contains) else { return nil }
        return columns.joined(separator: ",")
    }

    private static func isPasswordJSON(_ text: String) -> Bool {
        // Bitwarden's unencrypted export: {"encrypted": false, ... "login": {"password": ...}}
        let compact = text.replacingOccurrences(of: " ", with: "")
        return compact.contains("\"encrypted\":false") && compact.contains("\"password\"")
    }

    /// The longest run of consecutive words that are all on the BIP-39 list.
    /// Numbering ("1. abandon 2. ability") and punctuation are ignored. Ordinary prose
    /// almost never manages 12 in a row: "the", "and", "of", "is" aren't BIP-39 words.
    static func longestRecoveryPhraseRun(in text: String) -> Int? {
        let words = text.lowercased()
            .split { !$0.isLetter }
            .map(String.init)
        var best = 0, current = 0
        for word in words {
            if BIP39.words.contains(word) {
                current += 1
                best = max(best, current)
            } else {
                current = 0
            }
        }
        return best > 0 ? best : nil
    }
}

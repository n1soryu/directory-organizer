import Foundation

/// A sensitive file and what kind it is. Found by fixed checks only, never by the model.
public struct SensitiveFinding: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
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
        if let finding = facts.sensitive { return finding }
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
        // A photographed phrase read with one word wrong: 11+ of 13 words in a row. Measured:
        // ordinary prose reaches at most 9; a 12-word phrase with one misread word, 11.
        if densestRecoveryPhraseWindow(in: text, width: 13) >= 11 {
            return SensitiveFinding(kind: .recoveryPhrase, detail: "11 or more BIP-39 words among 13 (one may be misread)")
        }
        if facts.fileExtension == "conf", text.contains("[Interface]"), text.contains("PrivateKey") {
            return SensitiveFinding(kind: .credentialFile, detail: "WireGuard config with a private key")
        }
        if let what = credentials(in: text, name: facts.name) {
            return SensitiveFinding(kind: .credentialFile, detail: what)
        }
        return nil
    }

    /// Developer credential files, the kind found in downloaded projects and backups: what
    /// matters is a secret value inside, not just the name.
    static func credentials(in text: String, name: String) -> String? {
        let lower = name.lowercased()
        let content = text.lowercased()
        if content.range(of: #"aws_secret_access_key\s*=\s*\S"#, options: .regularExpression) != nil {
            return "AWS credentials (secret access key)"
        }
        if lower == ".git-credentials", text.range(of: #"https?://[^\s:/]+:[^\s@]+@"#, options: .regularExpression) != nil {
            return "Git credentials (passwords or tokens in URLs)"
        }
        if [".netrc", "_netrc", ".pgpass"].contains(lower), content.contains("password") || lower == ".pgpass" {
            return "\(name) with passwords"
        }
        if [".npmrc", ".pypirc", ".yarnrc.yml"].contains(lower),
           content.range(of: #"(_authtoken|password|npmauthtoken)\s*[=:]\s*\S"#, options: .regularExpression) != nil {
            return "\(name) with a token or password"
        }
        // .env, .env.local, .env.production (but not .env.example / .env.sample / .env.template).
        if lower == ".env" || (lower.hasPrefix(".env.") && !["example", "sample", "template", "dist"].contains { lower.hasSuffix($0) }),
           content.range(of: ##"(?m)^\s*(export\s+)?[a-z0-9_]*(secret|token|password|passwd|api_?key|private_?key)[a-z0-9_]*\s*=\s*['"]?[^\s'"#]"##,
                         options: .regularExpression) != nil {
            return "\(name) with secrets (keys, tokens or passwords)"
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
        // PEM and OpenSSH ("-----BEGIN … PRIVATE KEY-----"), any case; and RFC 4716 / PuTTY
        // ("---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----").
        guard let range = text.range(of: #"(?i)-{4,5} ?BEGIN ([A-Z0-9 ]*)PRIVATE KEY( BLOCK)? ?-{4,5}"#,
                                     options: .regularExpression) else { return nil }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "- "))
    }

    /// Header columns of a password manager CSV (Chrome, Safari/Passwords, Firefox,
    /// Bitwarden, 1Password, LastPass...), or nil if it isn't one.
    static func passwordExportColumns(in text: String) -> String? {
        // The header is usually the first line, but Excel adds "sep=," and some exports a title.
        for line in text.split(whereSeparator: \.isNewline).prefix(5) {
            if let columns = passwordColumns(inHeader: line) { return columns }
        }
        return nil
    }

    private static func passwordColumns(inHeader header: Substring) -> String? {
        let columns = header.split(separator: header.contains("\t") && !header.contains(",") ? "\t" : ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" \u{FEFF}")).lowercased() }
        let passwordColumns: Set<String> = ["password", "login_password", "pass", "passwd", "passwort", "pwd", "secret",
                                            "contraseña", "mot de passe"]
        let contextColumns: Set<String> = ["url", "login_uri", "username", "login_username", "name",
                                           "title", "website", "email", "hostname", "origin_url", "account"]
        guard columns.contains(where: passwordColumns.contains),
              columns.contains(where: contextColumns.contains) else { return nil }
        return columns.joined(separator: ",")
    }

    private static func isPasswordJSON(_ text: String) -> Bool {
        // Bitwarden's unencrypted export: {"encrypted": false, ... "login": {"password": ...}}
        let compact = text.filter { !$0.isWhitespace }
        return compact.contains("\"encrypted\":false") && compact.contains("\"password\"")
    }

    /// The longest run of consecutive words that are all on the BIP-39 list.
    /// Numbering ("1. abandon 2. ability") and punctuation are ignored. Ordinary prose
    /// almost never manages 12 in a row: "the", "and", "of", "is" aren't BIP-39 words.
    /// The most BIP-39 words among any `width` consecutive words.
    static func densestRecoveryPhraseWindow(in text: String, width: Int) -> Int {
        let hits = text.lowercased().split { !$0.isLetter }.map { BIP39.words.contains(String($0)) ? 1 : 0 }
        guard hits.count >= width else { return hits.reduce(0, +) }
        var count = hits.prefix(width).reduce(0, +), best = count
        for index in width..<hits.count {
            count += hits[index] - hits[index - width]
            best = max(best, count)
        }
        return best
    }

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

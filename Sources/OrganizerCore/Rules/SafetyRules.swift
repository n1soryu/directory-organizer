import Foundation

/// Password exports, recovery phrases, private keys and credential files.
/// Always alerts you, whatever the destination.
struct SensitiveFileRule: Rule {
    let name = "sensitive file"

    func evaluate(_ facts: FileFacts, config: OrganizerConfig) -> Decision? {
        // A folder with something sensitive inside stays whole and waits in review: never
        // unpacked, never filed by the model.
        if let found = facts.folder?.sensitive, !found.isEmpty {
            return Decision(
                destination: config.reviewFolder,
                confidence: 1,
                reason: "Folder contains \(found.count) sensitive file\(found.count == 1 ? "" : "s"): \(found.prefix(3).joined(separator: "; "))",
                source: .safety(name),
                alerts: found.map { Alert(.sensitive, "Inside \(facts.name): \($0)") }
            )
        }
        guard let finding = SensitiveDetector.check(facts) else { return nil }

        let label: String = switch finding.kind {
        case .unencryptedPasswordExport: "Password Export"
        case .recoveryPhrase: "Recovery Phrase"
        case .privateKey: "Private Key"
        case .credentialFile: "Credentials"
        }
        // "IMG_5012.jpg" holding a recovery phrase becomes "2026-10-13 Recovery Phrase.jpg".
        let newName = facts.nameIsUnclear ? "\(FileNames.day(facts.downloadDate)) \(label)" : nil

        if finding.belongsInReview {
            return Decision(
                destination: config.reviewFolder,
                newBaseName: newName,
                confidence: 1,
                reason: "Unencrypted \(finding.detail). Import it into your password manager, then delete it.",
                source: .safety(name),
                alerts: [Alert(.sensitive, "Passwords in plain text: \(finding.detail)")]
            )
        }
        return Decision(
            destination: config.secure,
            newBaseName: newName,
            tags: [.secure],
            confidence: 1,
            reason: "\(label): \(finding.detail)",
            source: .safety(name),
            alerts: [Alert(.sensitive, "\(label) found: \(finding.detail)")]
        )
    }
}

/// Installers, disk images and firmware: install or flash, then delete. Always reviewed.
struct InstallerRule: Rule {
    let name = "installer"

    func evaluate(_ facts: FileFacts, config: OrganizerConfig) -> Decision? {
        let what: String
        switch facts.kind {
        case .installer: what = "Installer"
        case .diskImage: what = "Disk image"
        case .firmware: what = "Firmware image"
        default: return nil
        }
        return Decision(
            destination: config.reviewFolder,
            confidence: 1,
            reason: "\(what) (.\(facts.fileExtension)): install it, then delete it",
            source: .rule(name)
        )
    }
}

/// Zipped (or unzipped) code projects. Never unpacked into ~/Developer automatically:
/// that could overwrite your work. They wait in review for you.
struct CodeProjectRule: Rule {
    let name = "code project"

    private static let markers: Set<String> = [
        "Package.swift", ".git", "package.json", "pyproject.toml", "requirements.txt", "setup.py",
        "Cargo.toml", "go.mod", "CMakeLists.txt", "Makefile", "pom.xml", "build.gradle", "Gemfile",
    ]

    func evaluate(_ facts: FileFacts, config: OrganizerConfig) -> Decision? {
        guard facts.kind == .archive || facts.kind == .folder, let entries = facts.archiveEntries else { return nil }
        // Look at the top two levels: "Package.swift" or "ig-follow-audit-main/Package.swift".
        let found = entries.lazy.compactMap { path -> String? in
            let parts = path.split(separator: "/").map(String.init)
            return parts.prefix(2).first { Self.markers.contains($0) || $0.hasSuffix(".xcodeproj") }
        }.first
        guard let marker = found else { return nil }
        return Decision(
            destination: config.reviewFolder,
            confidence: 1,
            reason: "Code project (contains \(marker)): unpack it into ~/Developer yourself",
            source: .rule(name)
        )
    }
}

/// An empty folder (often what's left after unpacking one). The app never deletes, so it
/// waits in review for you to throw away.
struct EmptyFolderRule: Rule {
    let name = "empty folder"

    func evaluate(_ facts: FileFacts, config: OrganizerConfig) -> Decision? {
        guard facts.isDirectory, facts.folder?.isEmpty == true else { return nil }
        return Decision(destination: config.reviewFolder, confidence: 1,
                        reason: "Empty folder: nothing to keep", source: .rule(name))
    }
}

import Foundation

/// Turns a folder of downloads into a plan: facts -> rules -> classifier -> checks.
/// Read-only: it looks at the destination folders but never changes anything.
public struct Planner: Sendable {
    public var config: OrganizerConfig
    /// Destinations are resolved against this folder: TestData/Home while testing.
    public var homeRoot: URL
    public var extractor = FactExtractor()
    public var rules = RulesEngine.standard
    public var classifier: any FileClassifier = StubClassifier()

    /// Downloads still in progress (Chrome, Safari, Firefox, Opera): never touched.
    public static let incompleteExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]

    public init(config: OrganizerConfig = OrganizerConfig(), homeRoot: URL) {
        self.config = config
        self.homeRoot = homeRoot.standardizedFileURL
    }

    public func plan(folder: URL) async throws -> Plan {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.addedToDirectoryDateKey], options: [.skipsHiddenFiles])

        var skipped: [SkippedItem] = []
        var facts: [FileFacts] = []
        for url in urls {
            if Self.incompleteExtensions.contains(url.pathExtension.lowercased()) {
                skipped.append(SkippedItem(name: url.lastPathComponent, reason: "download still in progress"))
                continue
            }
            facts.append(await extractor.facts(for: url))
        }
        // Oldest download first, so the first copy of a duplicate counts as the original.
        facts.sort { a, b in
            a.downloadDate != b.downloadDate
                ? a.downloadDate < b.downloadDate
                : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        var hashes = HashCache()
        let copies = duplicatesWithinBatch(facts, &hashes)
        var reserved = Set<String>()
        var actions: [ProposedAction] = []

        for item in facts {
            let decision: Decision
            if let original = copies[item.url] {
                decision = Decision(
                    destination: config.reviewFolder,
                    confidence: 1,
                    reason: "Duplicate of \(original.lastPathComponent) (identical content)",
                    source: .safety("duplicate"),
                    alerts: [Alert(.duplicate, "Identical to \(original.lastPathComponent), also in this folder")]
                )
            } else {
                decision = await decide(item)
            }
            actions.append(resolve(item, decision, &hashes, &reserved))
        }

        return Plan(createdAt: Date(), inputFolder: folder, homeRoot: homeRoot, actions: actions, skipped: skipped)
    }

    /// Rules first; the classifier only for files no rule could place. Every answer is checked.
    public func decide(_ facts: FileFacts) async -> Decision {
        if let decision = rules.decide(facts, config: config) {
            return checked(decision)
        }
        let suggestion = try? await classifier.suggest(for: facts, config: config)
        guard let suggestion else {
            return Decision(destination: config.reviewFolder, confidence: 0,
                            reason: "No rule matched and there's no model yet (Milestone 3)",
                            source: .classifier(classifier.name))
        }
        guard suggestion.confidence >= config.confidenceThreshold else {
            return Decision(destination: config.reviewFolder, confidence: suggestion.confidence,
                            reason: "Model unsure (\(Int(suggestion.confidence * 100))%): \(suggestion.reason)",
                            source: .classifier(classifier.name))
        }
        // Only tags on the allowlist survive; anything else the model invents is dropped.
        let allowedTags = [Tag.nsu, .fsae, .personal, .secure]
        let tags = suggestion.tags.compactMap { name in allowedTags.first { $0.name.lowercased() == name.lowercased() } }
        return checked(Decision(destination: suggestion.destination, newBaseName: suggestion.newBaseName, tags: tags,
                                confidence: suggestion.confidence, reason: suggestion.reason,
                                source: .classifier(classifier.name)))
    }

    /// Sends a decision with an invalid destination to review instead, with an alert.
    private func checked(_ decision: Decision) -> Decision {
        guard let problem = DestinationValidator.problem(with: decision.destination, config: config) else {
            return decision
        }
        var safe = decision
        safe.destination = config.reviewFolder
        safe.tags = []
        safe.reason = "Rejected \(decision.destination): \(problem)"
        safe.alerts.append(Alert(.rejected, "Proposed destination rejected: \(problem)"))
        return safe
    }

    // MARK: - Resolving names, duplicates and clashes

    private func resolve(_ facts: FileFacts, _ decision: Decision,
                         _ hashes: inout HashCache, _ reserved: inout Set<String>) -> ProposedAction {
        var decision = decision
        var base = FileNames.sanitize(decision.newBaseName ?? facts.baseName)
        if base.isEmpty { base = facts.baseName }

        // Same content already at the destination: a true duplicate. Tell you, park it in review.
        if !facts.isDirectory, decision.destination != config.reviewFolder,
           let existing = identicalFile(to: facts, in: decision.destination, &hashes) {
            decision = Decision(
                destination: config.reviewFolder,
                confidence: 1,
                reason: "Duplicate of \(decision.destination)/\(existing) (identical content)",
                source: .safety("duplicate"),
                alerts: decision.alerts + [Alert(.duplicate, "Identical to \(decision.destination)/\(existing)")]
            )
            base = facts.baseName
        }

        var newFolders: [String] = []
        var path = homeRoot
        for part in decision.destination.split(separator: "/") {
            path.append(path: String(part), directoryHint: .isDirectory)
            if !FileManager.default.fileExists(atPath: path.path) {
                newFolders.append(String(path.path.dropFirst(homeRoot.path.count + 1)))
            }
        }
        if newFolders.count > config.maxNewFolders {
            decision.alerts.append(Alert(.rejected, "Would create \(newFolders.count) new folders for \(decision.destination)"))
            decision.destination = config.reviewFolder
            decision.reason = "Too many new folders: \(decision.reason)"
            decision.tags = []
            newFolders = []
        }

        // A different file with the same name: never overwrite, add the date instead.
        var name = FileNames.join(base, facts.fileExtension)
        if isTaken(name, in: decision.destination, reserved) {
            let alternative = FileNames.clashAlternatives(base, facts.fileExtension, date: facts.downloadDate)
                .first { !isTaken($0, in: decision.destination, reserved) } ?? FileNames.join("\(base) \(UUID().uuidString.prefix(8))", facts.fileExtension)
            decision.alerts.append(Alert(.nameClash, "\(decision.destination) already has a different \(name); saving as \(alternative)"))
            name = alternative
        }
        reserved.insert(key(name, decision.destination))

        return ProposedAction(
            source: facts.url,
            originalName: facts.name,
            sourceSize: facts.size,
            sourceModified: facts.modified,
            destinationFolder: decision.destination,
            finalName: name,
            tags: decision.tags,
            confidence: decision.confidence,
            reason: decision.reason,
            decidedBy: decision.source,
            alerts: decision.alerts,
            createsFolders: newFolders
        )
    }

    /// The name of a file in `folder` with exactly the same content, if there is one.
    /// Only same-size files are hashed, so this stays cheap.
    private func identicalFile(to facts: FileFacts, in folder: String, _ hashes: inout HashCache) -> String? {
        let dir = homeRoot.appending(path: folder, directoryHint: .isDirectory)
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])
        else { return nil }
        for candidate in candidates {
            let values = try? candidate.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, Int64(values?.fileSize ?? -1) == facts.size,
                  let a = hashes.hash(facts.url), let b = hashes.hash(candidate), a == b else { continue }
            return candidate.lastPathComponent
        }
        return nil
    }

    /// Files in this batch that are byte-for-byte copies of another one: copy -> original.
    /// The original is the one without a "(1)" suffix, else the earliest download.
    private func duplicatesWithinBatch(_ facts: [FileFacts], _ hashes: inout HashCache) -> [URL: URL] {
        let files = facts.filter { !$0.isDirectory && $0.size > 0 }
        var copies: [URL: URL] = [:]
        for group in Dictionary(grouping: files, by: \.size).values where group.count > 1 {
            let byHash = Dictionary(grouping: group) { hashes.hash($0.url) ?? UUID().uuidString }
            for same in byHash.values where same.count > 1 {
                let original = same.first { NameQuality.stripCopySuffix($0.baseName) == $0.baseName } ?? same[0]
                for copy in same where copy.url != original.url {
                    copies[copy.url] = original.url
                }
            }
        }
        return copies
    }

    private func isTaken(_ name: String, in folder: String, _ reserved: Set<String>) -> Bool {
        reserved.contains(key(name, folder))
            || FileManager.default.fileExists(atPath: homeRoot.appending(path: folder).appending(path: name).path)
    }

    /// APFS is case-insensitive by default: "Report.pdf" and "report.pdf" clash.
    private func key(_ name: String, _ folder: String) -> String {
        (folder + "/" + name).lowercased()
    }
}

/// Hashes each file at most once per plan.
struct HashCache {
    private var cache: [URL: String] = [:]

    mutating func hash(_ url: URL) -> String? {
        if let known = cache[url] { return known }
        guard let value = try? FileHash.sha256(url) else { return nil }
        cache[url] = value
        return value
    }
}

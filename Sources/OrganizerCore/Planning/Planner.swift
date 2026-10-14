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
    public var mode: Mode = .full
    /// If set, items that arrived in the folder before this date are left alone entirely
    /// (not read, not listed): only new downloads are organized.
    public var onlyAddedAfter: Date?

    public enum Mode: Sendable {
        /// Rules only: no text recognition, no model. Seconds, not minutes. Files that need
        /// either become `Plan.waiting` instead of actions.
        case quick
        /// Everything: OCR for images and scans, the model for leftovers and unclear names.
        case full
    }

    /// Reported after each file, so a long run can show where it is.
    public struct Progress: Sendable, Equatable {
        public var done: Int
        public var total: Int
        public var file: String
        public var step: Step

        public enum Step: String, Sendable {
            case reading = "Reading"
            case deciding = "Deciding"
        }
    }

    /// Downloads still in progress (Chrome, Safari, Firefox, Opera): never touched.
    public static let incompleteExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]

    public init(config: OrganizerConfig = OrganizerConfig(), homeRoot: URL, mode: Mode = .full) {
        self.config = config
        self.homeRoot = homeRoot.standardizedFileURL
        self.mode = mode
        extractor.recognizeText = mode == .full
    }

    /// Plans every item in `folder`. Cancelling the surrounding task stops it between files
    /// (throws `CancellationError`); planning only reads, so stopping half-way is harmless.
    public func plan(folder: URL, progress: (@Sendable (Progress) -> Void)? = nil) async throws -> Plan {
        let fm = FileManager.default
        var urls = try fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.addedToDirectoryDateKey, .creationDateKey], options: [.skipsHiddenFiles])
        if let cutoff = onlyAddedAfter {
            urls = urls.filter { Self.arrival(of: $0).map { $0 >= cutoff } ?? false }
        }

        var skipped: [SkippedItem] = []
        var facts: [FileFacts] = []
        let candidates = urls.filter { url in
            if Self.incompleteExtensions.contains(url.pathExtension.lowercased()) {
                skipped.append(SkippedItem(name: url.lastPathComponent, reason: "download still in progress"))
                return false
            }
            return true
        }
        // Reading and deciding are each half of the work.
        let total = candidates.count * 2
        for (index, url) in candidates.enumerated() {
            try Task.checkCancellation()
            progress?(Progress(done: index, total: total, file: url.lastPathComponent, step: .reading))
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
        let folders = FolderCatalog.options(homeRoot: homeRoot, config: config)
        var newFolders: [String: String] = [:]
        var actions: [ProposedAction] = []
        var waiting: [WaitingItem] = []

        for (index, item) in facts.enumerated() {
            try Task.checkCancellation()
            progress?(Progress(done: candidates.count + index, total: total, file: item.name, step: .deciding))
            let decision: Decision
            if let original = copies[item.url] {
                decision = Decision(
                    destination: config.reviewFolder,
                    confidence: 1,
                    reason: "Duplicate of \(original.lastPathComponent) (identical content)",
                    source: .safety("duplicate"),
                    alerts: [Alert(.duplicate, "Identical to \(original.lastPathComponent), also in this folder")]
                )
            } else if mode == .quick, let reason = waitReason(item) {
                waiting.append(WaitingItem(source: item.url, name: item.name, identity: FileIdentity(item), reason: reason))
                continue
            } else {
                decision = await decide(item, folders: folders, newFolders: &newFolders)
            }
            actions.append(resolve(item, decision, &hashes, &reserved))
        }
        progress?(Progress(done: total, total: total, file: "", step: .deciding))

        return Plan(createdAt: Date(), inputFolder: folder, homeRoot: homeRoot, actions: actions,
                    skipped: skipped, waiting: waiting)
    }

    /// When an item arrived in its folder: the date it was added, else when it was created.
    /// nil (unknown) counts as old, so nothing is touched by mistake.
    static func arrival(of url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        return values?.addedToDirectoryDate ?? values?.creationDate
    }

    /// Quick scans: why a file has to wait for a full run, or nil if rules can decide it now.
    func waitReason(_ facts: FileFacts) -> String? {
        // Checked before any rule: an unread image could hold a recovery phrase.
        if facts.needsDeepRead {
            return facts.kind == .image ? "needs text recognition (could contain sensitive text)" : "scanned pages need text recognition"
        }
        return rules.decide(facts, config: config) == nil ? "no rule fits; needs the model" : nil
    }

    /// Rules first; the classifier only for files no rule could place. Every answer is checked.
    public func decide(_ facts: FileFacts) async -> Decision {
        var newFolders: [String: String] = [:]
        return await decide(facts, folders: FolderCatalog.options(homeRoot: homeRoot, config: config), newFolders: &newFolders)
    }

    /// `newFolders` remembers new folders proposed earlier in this plan, so "Manual" and
    /// "Manuals" for two files become one folder.
    func decide(_ facts: FileFacts, folders: [FolderOption], newFolders: inout [String: String]) async -> Decision {
        if var decision = rules.decide(facts, config: config) {
            decision = checked(decision)
            if decision.newBaseName == nil, facts.nameIsUnclear, wantsName(decision, facts) {
                if mode == .full {
                    decision = await named(decision, facts)
                } else {
                    decision.reason += "; Organize Now can suggest a better name"
                }
            }
            return decision
        }

        guard mode == .full else {
            return toReview("No rule matched; waiting for Organize Now", confidence: 0)
        }
        let request = ClassificationRequest(
            facts: facts, folders: folders, newFolderParents: FolderCatalog.newFolderParents(for: facts.kind),
            reviewFolder: config.reviewFolder)
        let suggestion: ClassifierSuggestion
        do {
            suggestion = try await classifier.suggest(request)
        } catch {
            return toReview("No rule matched; \(error)", confidence: 0)
        }

        guard suggestion.confidence >= config.confidenceThreshold else {
            return toReview("Model unsure (\(Int(suggestion.confidence * 100))%), would have chosen \(suggestion.destination): \(suggestion.reason)",
                            confidence: suggestion.confidence)
        }

        // The folder must be one we offered, or a new folder that passes the checks.
        var destination = suggestion.destination
        if suggestion.isNewFolder {
            switch newFolder(destination, kind: facts.kind, folders: folders, newFolders: &newFolders) {
            case .success(let path): destination = path
            case .failure(let problem): return rejected(suggestion, problem.message)
            }
        } else if !folders.contains(where: { $0.path == destination }) {
            return rejected(suggestion, "\(destination) wasn't one of the folders offered")
        }

        // University folders need NSU evidence the model can't invent: the download source,
        // "North South University" in the text, or one of your course codes.
        if destination == config.university || destination.hasPrefix(config.university + "/"), !hasNSUEvidence(facts) {
            return rejected(suggestion, "no sign it's an NSU file")
        }

        // Tags come from the folder, not from the model.
        let tags = Self.tags(for: destination, folders: folders)
        let newName = facts.nameIsUnclear ? suggestion.newBaseName.flatMap(Self.validTitle) : nil
        return checked(Decision(destination: destination, newBaseName: newName, tags: tags,
                                confidence: suggestion.confidence, reason: suggestion.reason,
                                source: .classifier(classifier.name)))
    }

    /// The tags of the folder, or of the nearest listed folder above it.
    static func tags(for destination: String, folders: [FolderOption]) -> [Tag] {
        folders
            .filter { destination == $0.path || destination.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }?.tags ?? []
    }

    private func hasNSUEvidence(_ facts: FileFacts) -> Bool {
        facts.isNSU
            || !config.courses.knownCodes(in: facts.baseName + "\n" + facts.head(3_000)).isEmpty
    }

    private func toReview(_ reason: String, confidence: Double, alerts: [Alert] = []) -> Decision {
        Decision(destination: config.reviewFolder, confidence: confidence, reason: reason,
                 source: .classifier(classifier.name), alerts: alerts)
    }

    private func rejected(_ suggestion: ClassifierSuggestion, _ problem: String) -> Decision {
        toReview("Model suggestion rejected (\(problem)): \(suggestion.reason)", confidence: suggestion.confidence,
                 alerts: [Alert(.rejected, "Model suggested \(suggestion.destination); rejected: \(problem)")])
    }

    // MARK: - New folders proposed by the model

    struct FolderProblem: Error { var message: String }

    /// Checks a proposed new folder ("Documents/Manuals") and reuses an existing or already
    /// proposed folder with nearly the same name. At most 2 new levels below the parent.
    func newFolder(_ path: String, kind: FileKind, folders: [FolderOption],
                   newFolders: inout [String: String]) -> Result<String, FolderProblem> {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let parent = parts.first, FolderCatalog.newFolderParents(for: kind).contains(parent) else {
            return .failure(FolderProblem(message: "a \(kind.rawValue) file can't get a new folder under \(parts.first ?? "")"))
        }
        let names = Array(parts.dropFirst())
        guard (1...2).contains(names.count) else {
            return .failure(FolderProblem(message: "a new folder may add 1 or 2 levels, not \(names.count)"))
        }
        for name in names {
            guard !name.isEmpty, name == FileNames.sanitize(name), name.count <= 40,
                  name.contains(where: \.isLetter) else {
                return .failure(FolderProblem(message: "\"\(name)\" isn't a usable folder name"))
            }
        }

        // Reuse: compare loosely with folders that exist and folders proposed earlier.
        let key = ([parent] + names.map(FolderCatalog.looseKey)).joined(separator: "/")
        if let earlier = newFolders[key] { return .success(earlier) }
        if let existing = folders.first(where: { option in
            let p = option.path.split(separator: "/").map(String.init)
            return p.count == names.count + 1 && p[0] == parent
                && zip(p.dropFirst(), names).allSatisfy { FolderCatalog.looseKey($0) == FolderCatalog.looseKey($1) }
        }) {
            return .success(existing.path)
        }
        newFolders[key] = path
        return .success(path)
    }

    // MARK: - Names suggested by the model

    /// Worth asking the model for a name: a file being filed (not reviewed, not a safety
    /// case), not a video (rules clean those names).
    private func wantsName(_ decision: Decision, _ facts: FileFacts) -> Bool {
        if case .safety = decision.source { return false }
        return decision.destination != config.reviewFolder && facts.kind != .video && !facts.isDirectory
    }

    private func named(_ decision: Decision, _ facts: FileFacts) async -> Decision {
        var decision = decision
        do {
            let suggestion = try await classifier.suggestName(for: facts)
            guard suggestion.confidence >= config.confidenceThreshold, var title = Self.validTitle(suggestion.title) else {
                decision.reason += "; model couldn't name it confidently"
                return decision
            }
            if facts.kind == .image {
                // Images: "2026-10-12 Router wireless settings page", dated by when it was taken.
                title = "\(FileNames.day(facts.image?.dateTaken ?? facts.downloadDate)) \(title)"
            } else if let code = decision.destination.split(separator: "/").last.map(String.init),
                      config.courses.contains(code), !title.uppercased().contains(code) {
                title = "\(code) \(title)"
            }
            decision.newBaseName = title
            decision.reason += "; name suggested by the model"
        } catch {
            decision.reason += "; \(error)"
        }
        return decision
    }

    /// A model-suggested name, cleaned up, or nil if it's no good.
    static func validTitle(_ raw: String) -> String? {
        var title = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'`.\n"))
        // Models sometimes add an extension anyway.
        title = title.replacingOccurrences(of: #"\.[A-Za-z0-9]{2,5}$"#, with: "", options: .regularExpression)
        title = FileNames.sanitize(title)
        let words = title.split(separator: " ").count
        guard (1...12).contains(words), title.filter(\.isLetter).count >= 3, !NameQuality.isUnclear(title) else { return nil }
        return title
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
            createsFolders: newFolders,
            facts: facts
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

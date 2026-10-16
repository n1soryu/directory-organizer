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
    /// A folder changed less than this long ago is left until it's quiet: it may still be
    /// being unzipped or copied.
    public var settleTime: TimeInterval = 30
    /// How many folder levels the model may unpack, and the most files a folder may hold to
    /// be unpacked at all. Bigger folders stay together.
    public var maxUnpackDepth = 2
    public var maxUnpackItems = 200
    /// What's known about your folders from earlier runs (purposes above all). Refreshed by
    /// every plan and returned in `Plan.profiles`, for the caller to keep.
    public var profiles: [FolderProfile] = []
    /// Model moves you undid, newest first: shown to the model so it doesn't repeat them.
    public var corrections: [Correction] = []

    public enum Mode: Sendable {
        /// Rules only: no text recognition, no model. Seconds, not minutes. Files that need
        /// either become `Plan.waiting` instead of actions.
        case quick
        /// Everything: OCR for images and scans, the model for leftovers and unclear names.
        case full
    }

    /// Reported after each file, so a long run can show where it is. `done` and `total` count
    /// within the step; `fraction` is the whole run's, and only ever grows.
    public struct Progress: Sendable, Equatable {
        public var done: Int
        public var total: Int
        public var file: String
        public var step: Step

        /// 0...1 for the whole run: each step has its own stretch of the bar.
        public var fraction: Double {
            let (start, width): (Double, Double) = switch step {
            case .reading: (0, 0.35)
            case .learning: (0.35, 0.1)
            case .grouping: (0.45, 0.2)
            case .deciding: (0.65, 0.35)
            }
            return start + width * (total > 0 ? min(Double(done) / Double(total), 1) : 1)
        }

        public enum Step: String, Sendable {
            case learning = "Learning your folders"
            case grouping = "Finding similar files"
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
        var unpacked: [URL] = []
        let candidates = urls.filter { url in
            if Self.incompleteExtensions.contains(url.pathExtension.lowercased()) {
                skipped.append(SkippedItem(name: url.lastPathComponent, reason: "download still in progress"))
                return false
            }
            return true
        }
        for (index, url) in candidates.enumerated() {
            try Task.checkCancellation()
            progress?(Progress(done: index, total: candidates.count, file: url.lastPathComponent, step: .reading))
            facts.append(await extractor.facts(for: url))
        }
        // Folders still being written are left until they've been quiet for a while.
        let now = Date()
        facts.removeAll { item in
            guard item.isDirectory, let changed = item.folder?.newestChange,
                  now.timeIntervalSince(changed) < settleTime else { return false }
            skipped.append(SkippedItem(name: item.name, reason: "folder still changing (being unzipped or copied?)",
                                       retryAfter: max(1, settleTime - now.timeIntervalSince(changed))))
            return true
        }
        // Organize Now: the model decides, folder by folder, to keep it together or unpack it.
        if mode == .full {
            facts = try await unpacking(facts, depth: 0, into: &unpacked)
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
        let learned = try await learnedProfiles(progress: progress)
        let folders = FolderCatalog.options(profiles: learned, config: config)
        var newFolders: [String: String] = [:]
        var actions: [ProposedAction] = []
        var waiting: [WaitingItem] = []
        // Organize Now: the model says what each leftover is; similar ones are placed together.
        let grouped = mode == .full
            ? try await groupDecisions(facts, copies: copies, folders: folders, newFolders: &newFolders, progress: progress)
            : [:]
        var decided: [(item: FileFacts, decision: Decision)] = []

        for (index, item) in facts.enumerated() {
            try Task.checkCancellation()
            progress?(Progress(done: index, total: facts.count, file: item.name, step: .deciding))
            var decision: Decision
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
            } else if let together = grouped[item.url] {
                decision = together
            } else {
                decision = await decide(item, folders: folders, newFolders: &newFolders)
            }
            decided.append((item, decision))
        }
        // New folders the model made for a group of similar files; no other may be created.
        let groupFolders = Set(grouped.values.filter(isNewByModel).map(\.destination))
        for (item, var decision) in requiringGroupsForNewFolders(decided, groupFolders: groupFolders) {
            let parent = item.url.deletingLastPathComponent()
            if parent.standardizedFileURL.path != folder.standardizedFileURL.path {
                decision.reason = "From \(parent.lastPathComponent)/: \(decision.reason)"
            }
            actions.append(resolve(item, decision, &hashes, &reserved))
        }
        progress?(Progress(done: facts.count, total: facts.count, file: "", step: .deciding))

        var plan = Plan(createdAt: Date(), inputFolder: folder, homeRoot: homeRoot, actions: actions,
                        skipped: skipped, waiting: waiting)
        plan.unpacked = unpacked
        plan.profiles = learned
        return plan
    }

    /// A new folder needs at least this many files of the same kind; the model may not make a
    /// folder for one file. (A one-off goes to an existing folder, or to review.)
    public var minimumNewFolderFiles = 2

    /// Leftover files (no rule, not a duplicate, readable) are described by the model and
    /// grouped by code; each group of 2+ is placed in one go. Files of groups the model says
    /// aren't alike, and files alike with nothing else, aren't in the result: they're placed
    /// one by one as before.
    func groupDecisions(_ facts: [FileFacts], copies: [URL: URL], folders: [FolderOption],
                        newFolders: inout [String: String],
                        progress: (@Sendable (Progress) -> Void)?) async throws -> [URL: Decision] {
        let leftovers = facts.filter {
            copies[$0.url] == nil && !$0.needsDeepRead && rules.decide($0, config: config) == nil
        }
        guard leftovers.count >= 2 else { return [:] }

        var described: [(facts: FileFacts, description: FileDescription)] = []
        for (step, item) in leftovers.enumerated() {
            try Task.checkCancellation()
            progress?(Progress(done: step, total: leftovers.count, file: item.name, step: .grouping))
            if let description = try? await classifier.describe(item) {
                described.append((item, description))
            }
        }

        var result: [URL: Decision] = [:]
        for group in Grouper.groups(described.map(\.description)) where group.count >= minimumNewFolderFiles {
            try Task.checkCancellation()
            let members = group.map { described[$0].facts }
            // The category most members share names the group; on a tie the more general
            // (shorter) one, then alphabetical, so the same files always give the same name.
            let categories = group.map { described[$0].description.category }
            let counts = Dictionary(grouping: categories, by: { $0 }).mapValues(\.count)
            let category = counts.keys.sorted { a, b in
                counts[a]! != counts[b]! ? counts[a]! > counts[b]! : a.count != b.count ? a.count < b.count : a < b
            }[0]
            let offered = FolderCatalog.relevant(folders, toGroup: members, category: category, config: config)
            var request = GroupRequest(members: members, category: category, folders: offered,
                                       newFolderParents: commonParents(members), reviewFolder: config.reviewFolder)
            request.corrections = members.flatMap { relevantCorrections(for: $0, offered: offered) }
                .reduce(into: [Correction]()) { if !$0.contains($1) { $0.append($1) } }
                .prefix(3).map(\.sentence)
            guard let answer = try? await classifier.placeGroup(request), answer.belongTogether else { continue }

            let shared = accept(answer.suggestion, kind: members[0].kind, inside: members[0].folder,
                                nsuEvidence: members.allSatisfy(hasNSUEvidence), nameUnclear: false,
                                offered: offered, folders: folders, newFolders: &newFolders)
            let names = members.prefix(3).map(\.name).joined(separator: ", ") + (members.count > 3 ? "…" : "")
            for member in members {
                var decision = shared
                decision.reason = "One of \(members.count) similar files (\(category): \(names)). \(decision.reason)"
                if member.nameIsUnclear, wantsName(decision, member) {
                    decision = await named(decision, member)
                }
                result[member.url] = decision
            }
        }
        return result
    }

    /// Where a new folder may go for all of `members` (where they agree; Documents otherwise).
    private func commonParents(_ members: [FileFacts]) -> [String] {
        let each = members.map { Set(FolderCatalog.newFolderParents(for: $0)) }
        let common = each.dropFirst().reduce(each.first ?? []) { $0.intersection($1) }
        return common.isEmpty ? ["Documents"] : common.sorted()
    }

    /// A folder the model wants to create (one that doesn't exist yet).
    func isNewByModel(_ decision: Decision) -> Bool {
        guard case .classifier = decision.source else { return false }
        return !FileManager.default.fileExists(atPath: homeRoot.appending(path: decision.destination).path)
    }

    /// New folders come only from groups of similar files. A file placed on its own may join a
    /// folder a group created, but a new folder of its own goes to review instead, even when
    /// another lone file happens to pick the same name (that's chance, not a pattern).
    func requiringGroupsForNewFolders(_ decided: [(item: FileFacts, decision: Decision)],
                                      groupFolders: Set<String>) -> [(item: FileFacts, decision: Decision)] {
        decided.map { entry in
            guard isNewByModel(entry.decision), !groupFolders.contains(entry.decision.destination) else { return entry }
            var decision = entry.decision
            decision.reason = "No group of similar files for the new folder \(decision.destination); a new folder needs \(minimumNewFolderFiles)+ similar files. Model: \(decision.reason)"
            decision.destination = config.reviewFolder
            decision.tags = []
            decision.newBaseName = nil
            return (entry.item, decision)
        }
    }

    /// Your folders' profiles, up to date. Organize Now also has the model write the purpose of
    /// every folder that has none yet, or whose contents changed a lot since it was written.
    func learnedProfiles(progress: (@Sendable (Progress) -> Void)?) async throws -> [FolderProfile] {
        var list = FolderProfiler.profiles(homeRoot: homeRoot, config: config, cached: profiles)
        guard mode == .full else { return list }
        // Only from real contents: a purpose guessed from an empty folder's name is a guess
        // ("FSAE" → "financial records") that would mislead every later decision.
        let todo = list.indices.filter { list[$0].fileCount > 0 && list[$0].needsPurpose }
        for (step, index) in todo.enumerated() {
            try Task.checkCancellation()
            progress?(Progress(done: step, total: todo.count, file: list[index].path, step: .learning))
            guard let raw = try? await classifier.describeFolder(list[index]),
                  let purpose = Self.validPurpose(raw) else { continue }
            list[index].purpose = purpose
            list[index].purposeFileCount = list[index].fileCount
        }
        return list
    }

    /// A model-written folder purpose, or nil if it's no good.
    static func validPurpose(_ raw: String) -> String? {
        let purpose = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...80).contains(purpose.count), purpose.filter(\.isLetter).count >= 3 else { return nil }
        return purpose
    }

    /// Replaces each folder the model says to unpack with what's inside it, recursively up to
    /// `maxUnpackDepth`. Folders a rule claims (code projects, sensitive contents, empty) and
    /// folders too big to check fully are never unpacked; without a model nothing is.
    func unpacking(_ items: [FileFacts], depth: Int, into unpacked: inout [URL]) async throws -> [FileFacts] {
        var result: [FileFacts] = []
        for item in items {
            try Task.checkCancellation()
            guard item.isDirectory, depth < maxUnpackDepth, let contents = item.folder, !contents.truncated,
                  contents.fileCount <= maxUnpackItems, rules.decide(item, config: config) == nil,
                  let suggestion = try? await classifier.suggestUnpack(for: item),
                  suggestion.unpack, suggestion.confidence >= config.confidenceThreshold
            else {
                result.append(item)
                continue
            }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: item.url, includingPropertiesForKeys: [.addedToDirectoryDateKey], options: [.skipsHiddenFiles])) ?? []
            var inside: [FileFacts] = []
            for child in children where !Self.incompleteExtensions.contains(child.pathExtension.lowercased()) {
                inside.append(await extractor.facts(for: child))
            }
            unpacked.append(item.url)
            result += try await unpacking(inside, depth: depth + 1, into: &unpacked)
        }
        return result
    }

    /// When an item arrived in its folder: the date it was added, else when it was created.
    /// nil (unknown) counts as old, so nothing is touched by mistake.
    static func arrival(of url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        return values?.addedToDirectoryDate ?? values?.creationDate
    }

    /// Quick scans: why a file has to wait for a full run, or nil if rules can decide it now.
    func waitReason(_ facts: FileFacts) -> String? {
        let ruled = rules.decide(facts, config: config)
        // Something sensitive already found: report it now, don't wait for the rest.
        if case .safety = ruled?.source { return nil }
        // Checked before other rules: an unread image could hold a recovery phrase.
        if facts.needsDeepRead {
            if facts.isDirectory { return "has images or scans inside that need text recognition" }
            if let why = facts.notes.last { return why.prefix(1).lowercased() + why.dropFirst() }
            return facts.kind == .image ? "needs text recognition (could contain sensitive text)" : "scanned pages need text recognition"
        }
        guard ruled == nil else { return nil }
        return facts.isDirectory ? "folder: the model decides whether to keep it together or unpack it" : "no rule fits; needs the model"
    }

    /// Rules first; the classifier only for files no rule could place. Every answer is checked.
    public func decide(_ facts: FileFacts) async -> Decision {
        var newFolders: [String: String] = [:]
        return await decide(facts, folders: FolderCatalog.options(homeRoot: homeRoot, config: config), newFolders: &newFolders)
    }

    /// `newFolders` remembers new folders proposed earlier in this plan, so "Manual" and
    /// "Manuals" for two files become one folder.
    func decide(_ facts: FileFacts, folders: [FolderOption], newFolders: inout [String: String]) async -> Decision {
        let ruled = rules.decide(facts, config: config)
        // Text recognition failed even in a full run: it couldn't be checked for sensitive
        // text, so it isn't filed anywhere but review (unless something sensitive was found).
        if mode == .full, facts.needsDeepRead {
            if let ruled, case .safety = ruled.source { return checked(ruled) }
            let why = facts.notes.last ?? "Couldn't read its text"
            return Decision(destination: config.reviewFolder, confidence: 0,
                            reason: "\(why), so it couldn't be checked for sensitive content",
                            source: .safety("unreadable"),
                            alerts: [Alert(.rejected, "\(why); check it yourself")])
        }
        if var decision = ruled {
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
        // Only the folders most likely to fit: the model's context window is small. New
        // folders are still checked against all of them below.
        let offered = FolderCatalog.relevant(folders, to: facts, config: config)
        var request = ClassificationRequest(
            facts: facts, folders: offered, newFolderParents: FolderCatalog.newFolderParents(for: facts),
            reviewFolder: config.reviewFolder)
        request.corrections = relevantCorrections(for: facts, offered: offered).map(\.sentence)
        let suggestion: ClassifierSuggestion
        do {
            suggestion = try await classifier.suggest(request)
        } catch {
            return toReview("No rule matched; \(error)", confidence: 0)
        }

        return accept(suggestion, kind: facts.kind, inside: facts.folder, nsuEvidence: hasNSUEvidence(facts),
                      nameUnclear: facts.nameIsUnclear, offered: offered, folders: folders, newFolders: &newFolders)
    }

    /// Every model answer, for one file or a group, goes through these checks.
    func accept(_ suggestion: ClassifierSuggestion, kind: FileKind, inside: FolderContents?, nsuEvidence: Bool,
                nameUnclear: Bool, offered: [FolderOption], folders: [FolderOption],
                newFolders: inout [String: String]) -> Decision {
        // A classifier is pluggable: a confidence that isn't a number in 0...1 counts as none.
        var suggestion = suggestion
        suggestion.confidence = suggestion.confidence.isFinite ? min(max(suggestion.confidence, 0), 1) : 0
        guard suggestion.confidence >= config.confidenceThreshold else {
            return toReview("Model unsure (\(Int(suggestion.confidence * 100))%), would have chosen \(suggestion.destination): \(suggestion.reason)",
                            confidence: suggestion.confidence)
        }

        // Secure is where the safety rules put keys and recovery phrases. A model guess that
        // isn't sure would hide an ordinary file there: it goes to review instead.
        if suggestion.destination == config.secure || suggestion.destination.hasPrefix(config.secure + "/"),
           suggestion.confidence < 0.9 {
            return toReview("Model suggested Secure without being sure (\(Int(suggestion.confidence * 100))%): \(suggestion.reason)",
                            confidence: suggestion.confidence)
        }

        // The folder must be one we offered, or a new folder that passes the checks.
        var destination = suggestion.destination
        if suggestion.isNewFolder {
            switch newFolder(destination, kind: kind, inside: inside, folders: folders, newFolders: &newFolders) {
            case .success(let path): destination = path
            case .failure(let problem): return rejected(suggestion, problem.message)
            }
        } else if !offered.contains(where: { $0.path == destination }) {
            return rejected(suggestion, "\(destination) wasn't one of the folders offered")
        }

        // University folders need NSU evidence the model can't invent: the download source,
        // "North South University" in the text, or one of your course codes.
        if destination == config.university || destination.hasPrefix(config.university + "/"), !nsuEvidence {
            return rejected(suggestion, "no sign it's an NSU file")
        }

        // Tags come from the folder, not from the model.
        let tags = Self.tags(for: destination, folders: folders)
        let newName = nameUnclear ? suggestion.newBaseName.flatMap(Self.validTitle) : nil
        return checked(Decision(destination: destination, newBaseName: newName, tags: tags,
                                confidence: suggestion.confidence, reason: suggestion.reason,
                                source: .classifier(classifier.name)))
    }

    /// Up to 3 of your corrections about the folders offered, the most similar files first.
    func relevantCorrections(for facts: FileFacts, offered: [FolderOption]) -> [Correction] {
        let paths = Set(offered.map(\.path))
        let words = FolderCatalog.words(facts.name)
        return corrections
            .filter { paths.contains($0.wrongFolder) }
            .enumerated()
            .sorted { a, b in
                let (x, y) = (FolderCatalog.words(a.element.fileName).intersection(words).count,
                              FolderCatalog.words(b.element.fileName).intersection(words).count)
                return x != y ? x > y : a.offset < b.offset
            }
            .prefix(3)
            .map(\.element)
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
    func newFolder(_ path: String, kind: FileKind, inside: FolderContents? = nil, folders: [FolderOption],
                   newFolders: inout [String: String]) -> Result<String, FolderProblem> {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let parent = parts.first, FolderCatalog.newFolderParents(for: kind, inside: inside).contains(parent) else {
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
                      config.courses.contains(code),
                      !title.uppercased().replacingOccurrences(of: " ", with: "").contains(code) {
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

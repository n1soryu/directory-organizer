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
    /// The vision model's cards for images (Organize Now). Without it, images go by the image rule.
    public var imageCards: (any ImageCardWriter)?
    /// The catalog of carded files (Organize Now). Without it, similar files are found by shared
    /// words, nothing is catalogued, and every leftover is carded afresh.
    public var catalog: CatalogContext?
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
            case .reading: (0, 0.25)
            case .describingImages: (0.25, 0.1)
            case .cataloguing: (0.35, 0.05)
            case .learning: (0.4, 0.05)
            case .grouping: (0.45, 0.2)
            case .deciding: (0.65, 0.35)
            }
            return start + width * (total > 0 ? min(Double(done) / Double(total), 1) : 1)
        }

        public enum Step: String, Sendable {
            case learning = "Learning your folders"
            case grouping = "Finding similar files"
            case reading = "Reading"
            case describingImages = "Describing images"
            case cataloguing = "Cataloguing earlier files"
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
        // Organize Now: the vision model looks at the images first, in a phase of its own, and is
        // released before the text model is needed again: the two never fit in memory together.
        var earlier: [EarlierFile] = []
        if mode == .full, let catalog {
            facts = reusingCards(facts, copies: copies, hashes: &hashes, catalog: catalog.catalog)
            earlier = await earlierFiles(catalog)
        }
        if mode == .full, let imageCards {
            let described = try await describingImages(facts, copies: copies, writer: imageCards,
                                                       earlier: earlier.map(\.facts), progress: progress)
            facts = described.facts
            for index in earlier.indices { earlier[index].facts = described.earlier[index] }
        }
        var catalogEntries: [CatalogEntry] = []
        if mode == .full, let catalog {
            catalogEntries += try await cataloguingEarlier(earlier, context: catalog, progress: progress)
        }
        var reserved = Set<String>()
        let learned = try await learnedProfiles(progress: progress)
        let folders = FolderCatalog.options(profiles: learned, config: config)
        var newFolders: [String: String] = [:]
        var actions: [ProposedAction] = []
        var waiting: [WaitingItem] = []
        // Organize Now: every leftover's card and embedding, to find its nearest earlier files.
        var embedded: [URL: Embedded]?
        if mode == .full, let catalog {
            embedded = try await embeddingLeftovers(facts, copies: copies, context: catalog, progress: progress)
        }
        var neighbourhood = Neighbourhood(catalog: catalog?.catalog, homeRoot: homeRoot)
        var decided: [(item: FileFacts, decision: Decision, pulled: [PulledFile])] = []
        var waitedURLs = Set<URL>()
        // Earlier files moving with a new one: they aren't decided on their own any more.
        var claimed = Set<String>()

        for (index, item) in facts.enumerated() {
            try Task.checkCancellation()
            progress?(Progress(done: index, total: facts.count, file: item.name, step: .deciding))
            if claimed.contains(item.url.path) { continue }
            if let original = copies[item.url] {
                decided.append((item, Decision(
                    destination: config.reviewFolder,
                    confidence: 1,
                    reason: "Duplicate of \(original.lastPathComponent) (identical content)",
                    source: .safety("duplicate"),
                    alerts: [Alert(.duplicate, "Identical to \(original.lastPathComponent), also in this folder")]
                ), []))
                continue
            }
            if mode == .quick, let reason = waitReason(item) {
                waiting.append(WaitingItem(source: item.url, name: item.name, identity: FileIdentity(item), reason: reason))
                continue
            }
            if let since = waitedBefore(item, &hashes) {
                // Decided before, and nothing like it then: not asked again. A similar new file
                // can still pull it out of Downloads.
                waiting.append(WaitingItem(source: item.url, name: item.name, identity: FileIdentity(item),
                                           reason: "Waiting for a match since \(FileNames.day(since))", forMatch: true))
                continue
            }
            let found = embedded?[item.url]
            let key = found == nil ? nil : hashes.hash(item.url)
            let (verdict, pulled) = await decide(item, folders: folders, neighbourhood: neighbourhood, vector: found?.vector,
                                                 key: key, newFolders: &newFolders)
            switch verdict {
            case .wait(let reason):
                waiting.append(WaitingItem(source: item.url, name: item.name, identity: FileIdentity(item), reason: reason,
                                           forMatch: true))
                waitedURLs.insert(item.url)
                if let found { neighbourhood.add(key: key, path: item.url.path, name: item.name, about: found.line,
                                                 vector: found.vector, folder: nil) }
            case .place(let decision):
                decided.append((item, decision, pulled))
                if let found, case .classifier = decision.source {
                    neighbourhood.add(key: key, path: item.url.path, name: item.name, about: found.line,
                                      vector: found.vector, folder: decision.destination)
                }
                for file in pulled {
                    claimed.insert(file.path)
                    neighbourhood.claim(file.path, into: decision.destination)
                }
            }
        }
        // A file that waited earlier in this run, then was pulled by a later one, moves after all.
        waiting.removeAll { claimed.contains($0.source.path) }
        waitedURLs = waitedURLs.filter { !claimed.contains($0.path) }

        let light = { () -> FactExtractor in var reader = extractor; reader.recognizeText = false; return reader }()
        for (item, var decision, pulled) in decided {
            let parent = item.url.deletingLastPathComponent()
            if parent.standardizedFileURL.path != folder.standardizedFileURL.path {
                decision.reason = "From \(parent.lastPathComponent)/: \(decision.reason)"
            }
            var action = resolve(item, decision, &hashes, &reserved)
            // Redirected (a duplicate already there, say): the earlier files stay where they are.
            guard !pulled.isEmpty, action.destinationFolder == decision.destination else {
                actions.append(action)
                continue
            }
            let group = UUID()
            action.groupID = group
            var members = [action]
            for file in pulled {
                // Only what's needed to move it: no text recognition.
                let earlier = await light.facts(for: URL(filePath: file.path))
                let from = file.waiting ? "waiting in Downloads" : "from \(Self.relative(file.path, to: homeRoot))"
                var move = resolve(earlier, Decision(
                    destination: decision.destination, tags: decision.tags, confidence: decision.confidence,
                    reason: "Earlier file (\(from)), moves with \(item.name): \(decision.reason)",
                    source: decision.source), &hashes, &reserved)
                // Identical content already there: nothing to move.
                guard move.destinationFolder == decision.destination else { continue }
                move.groupID = group
                move.isEarlierFile = true
                members.append(move)
            }
            actions += members
        }
        progress?(Progress(done: facts.count, total: facts.count, file: "", step: .deciding))
        if let catalog {
            catalogEntries += await runEntries(facts, actions: actions, waited: waitedURLs, embedded: embedded ?? [:],
                                               hashes: &hashes, context: catalog)
        }

        var plan = Plan(createdAt: Date(), inputFolder: folder, homeRoot: homeRoot, actions: actions,
                        skipped: skipped.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                        waiting: waiting)
        plan.unpacked = unpacked
        plan.profiles = learned
        plan.catalogEntries = catalogEntries
        return plan
    }

    /// Images only the image rule would place (not sensitive, not a duplicate, readable) get a card
    /// from the vision model. An image it can't describe keeps going by the image rule.
    /// `earlier`: images the app filed before, carded for the catalog in the same phase.
    func describingImages(_ facts: [FileFacts], copies: [URL: URL], writer: any ImageCardWriter,
                          earlier: [FileFacts] = [],
                          progress: (@Sendable (Progress) -> Void)?) async throws -> (facts: [FileFacts], earlier: [FileFacts]) {
        var facts = facts
        var earlier = earlier
        let images = facts.indices.filter { index in
            let item = facts[index]
            guard item.kind == .image, item.visionCard == nil, copies[item.url] == nil, !item.needsDeepRead,
                  case .rule(ImageRule.ruleName)? = rules.decide(item, config: config)?.source else { return false }
            return true
        }
        let earlierImages = earlier.indices.filter { earlier[$0].kind == .image && !earlier[$0].needsDeepRead }
        guard !images.isEmpty || !earlierImages.isEmpty else { return (facts, earlier) }
        let total = images.count + earlierImages.count
        for (step, index) in images.enumerated() {
            if Task.isCancelled {
                await writer.finish()
                throw CancellationError()
            }
            progress?(Progress(done: step, total: total, file: facts[index].name, step: .describingImages))
            facts[index].visionCard = try? await writer.card(for: facts[index])
        }
        for (step, index) in earlierImages.enumerated() {
            if Task.isCancelled {
                await writer.finish()
                throw CancellationError()
            }
            progress?(Progress(done: images.count + step, total: total, file: earlier[index].name, step: .describingImages))
            earlier[index].visionCard = try? await writer.card(for: earlier[index])
        }
        await writer.finish()
        return (facts, earlier)
    }

    /// A path relative to the home root, for reasons ("Documents/Bills/x.pdf").
    static func relative(_ path: String, to home: URL) -> String {
        let prefix = home.standardizedFileURL.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
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
            // Can't list it after all: it stays one item rather than vanishing from the plan.
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: item.url, includingPropertiesForKeys: [.addedToDirectoryDateKey], options: [.skipsHiddenFiles]) else {
                result.append(item)
                continue
            }
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
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey])
        return values?.addedToDirectoryDate ?? values?.creationDate ?? values?.contentModificationDate
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

    /// Rules first; the model for files no rule could place (`vector`, `key`: the file's embedding
    /// and hash, when the catalog is in use). `newFolders` remembers new folders proposed earlier in
    /// this plan, so "Manual" and "Manuals" for two files become one folder.
    func decide(_ facts: FileFacts, folders: [FolderOption], neighbourhood: Neighbourhood, vector: [Float]? = nil,
                key: String? = nil, newFolders: inout [String: String]) async -> (verdict: Verdict, pulled: [PulledFile]) {
        let ruled = rules.decide(facts, config: config)
        // Text recognition failed even in a full run: it couldn't be checked for sensitive
        // text, so it isn't filed anywhere but review (unless something sensitive was found).
        if mode == .full, facts.needsDeepRead {
            if let ruled, case .safety = ruled.source { return (.place(checked(ruled)), []) }
            let why = facts.notes.last ?? "Couldn't read its text"
            return (.place(Decision(destination: config.reviewFolder, confidence: 0,
                                    reason: "\(why), so it couldn't be checked for sensitive content",
                                    source: .safety("unreadable"),
                                    alerts: [Alert(.rejected, "\(why); check it yourself")])), [])
        }
        if var decision = ruled {
            decision = checked(decision)
            if decision.newBaseName == nil, needsName(facts), wantsName(decision, facts) {
                if mode == .full {
                    decision = await named(decision, facts)
                } else {
                    decision.reason += "; Organize Now can suggest a better name"
                }
            }
            return (.place(decision), [])
        }
        guard mode == .full else {
            return (.place(toReview("No rule matched; waiting for Organize Now", confidence: 0)), [])
        }
        return await decideLeftover(facts, vector: vector, key: key, folders: folders, neighbourhood: neighbourhood,
                                    newFolders: &newFolders)
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

    func hasNSUEvidence(_ facts: FileFacts) -> Bool {
        facts.isNSU
            || !config.courses.knownCodes(in: facts.baseName + "\n" + facts.head(3_000)).isEmpty
    }

    func toReview(_ reason: String, confidence: Double, alerts: [Alert] = []) -> Decision {
        Decision(destination: config.reviewFolder, confidence: confidence, reason: reason,
                 source: .classifier(classifier.name), alerts: alerts)
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

    /// An unclear name, or a screenshot's "Screenshot 2026-10-12 at 21.14.03" once the vision model
    /// has seen what it shows.
    func needsName(_ facts: FileFacts) -> Bool {
        facts.nameIsUnclear || (facts.isScreenshot && facts.visionCard != nil)
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
    public static func validTitle(_ raw: String) -> String? {
        var title = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'`.\n"))
        // Models sometimes add an extension anyway.
        title = title.replacingOccurrences(of: #"\.[A-Za-z0-9]{2,5}$"#, with: "", options: .regularExpression)
        // "Greenleaf_Grocers_2026-09-14" → "Greenleaf Grocers 2026-09-14".
        title = title.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        title = FileNames.sanitize(title)
        let words = title.split(separator: " ").count
        guard (1...12).contains(words), title.filter(\.isLetter).count >= 3, !NameQuality.isUnclear(title) else { return nil }
        return title
    }

    /// Sends a decision with an invalid destination to review instead, with an alert.
    func checked(_ decision: Decision) -> Decision {
        guard let problem = DestinationValidator.problem(with: decision.destination, config: config) else {
            return decision
        }
        var safe = decision
        safe.destination = config.reviewFolder
        safe.tags = []
        safe.newBaseName = nil
        safe.reason = "Rejected \(decision.destination): \(problem)"
        safe.alerts.append(Alert(.rejected, "Proposed destination rejected: \(problem)"))
        return safe
    }

    // MARK: - Resolving names, duplicates and clashes

    func resolve(_ facts: FileFacts, _ decision: Decision,
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
        // Empty files are all "identical"; that says nothing (as within a batch).
        guard facts.size > 0 else { return nil }
        for candidate in candidates where candidate.standardizedFileURL != facts.url.standardizedFileURL {
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
    /// nil inside: hashing failed, so it isn't tried again for every candidate.
    private var cache: [URL: String?] = [:]

    mutating func hash(_ url: URL) -> String? {
        if let known = cache[url] { return known }
        let value = try? FileHash.sha256(url)
        cache[url] = .some(value)
        return value
    }
}

import Foundation

/// What a file's decision came to: a place (rules, safety, review, or the model), or nothing yet.
public enum Verdict: Sendable {
    case place(Decision)
    /// It stays where it is, in Downloads, until a similar file arrives.
    case wait(reason: String)

    public var decision: Decision? {
        if case .place(let decision) = self { decision } else { nil }
    }

    public var waitReason: String? {
        if case .wait(let reason) = self { reason } else { nil }
    }
}

/// The catalog as one run sees it: the files filed or waiting before the run, plus each file
/// this run has decided so far. So the second of two manuals sees the first as an earlier file,
/// and the two can form a group in one decision.
struct Neighbourhood: Sendable {
    struct Item: Sendable {
        var key: String?
        var path: String
        var name: String
        var about: String
        var vector: [Float]
        /// Relative to the home root; nil while it waits in Downloads.
        var folder: String?
        /// This plan proposes the folder.
        var proposed: Bool
        /// Already moving with another file in this plan: shown, but can't be pulled again.
        var claimed: Bool
    }

    private(set) var items: [Item] = []

    init(catalog: Catalog?, homeRoot: URL) {
        let home = homeRoot.standardizedFileURL.path + "/"
        for item in catalog?.items ?? [] where item.isLive {
            var folder: String?
            if item.state == .filed, item.path.hasPrefix(home) {
                folder = URL(filePath: item.path).deletingLastPathComponent().path.replacingOccurrences(of: home, with: "")
            }
            items.append(Item(key: item.entry.key, path: item.path, name: URL(filePath: item.path).lastPathComponent,
                              about: item.entry.line, vector: item.vector, folder: folder, proposed: false, claimed: false))
        }
    }

    /// The `k` items most similar to `vector`, best first; never the file itself.
    func nearest(to vector: [Float], excluding key: String?, path: String, k: Int = 5) -> [Item] {
        items.filter { $0.path != path && ($0.key == nil || $0.key != key) }
            .map { ($0, Vectors.cosine(vector, $0.vector)) }
            .sorted { $0.1 > $1.1 }
            .prefix(k)
            .map(\.0)
    }

    /// A file decided in this run: waiting (`folder` nil) or proposed for `folder`.
    mutating func add(key: String?, path: String, name: String, about: String, vector: [Float], folder: String?) {
        items.removeAll { $0.path == path }
        items.append(Item(key: key, path: path, name: name, about: about, vector: vector, folder: folder,
                          proposed: folder != nil, claimed: false))
    }

    mutating func claim(_ path: String, into folder: String) {
        for index in items.indices where items[index].path == path {
            items[index].folder = folder
            items[index].proposed = true
            items[index].claimed = true
        }
    }
}

/// An earlier file the model put with a new one: where it is, what it is.
struct PulledFile: Sendable {
    var path: String
    var name: String
    var waiting: Bool
}

extension Planner {
    /// Rules first; the model only for files no rule could place. Every answer is checked.
    public func decide(_ facts: FileFacts) async -> Verdict {
        var newFolders: [String: String] = [:]
        return await decide(facts, folders: FolderCatalog.options(homeRoot: homeRoot, config: config),
                            neighbourhood: Neighbourhood(catalog: nil, homeRoot: homeRoot), newFolders: &newFolders).verdict
    }

    /// One leftover file, decided by the model with its nearest earlier files (`vector`: its
    /// embedding, if the catalog is in use). Returns the earlier files that move with it.
    func decideLeftover(_ facts: FileFacts, vector: [Float]?, key: String?, folders: [FolderOption],
                        neighbourhood: Neighbourhood, newFolders: inout [String: String]) async -> (verdict: Verdict, pulled: [PulledFile]) {
        // Folders the model may join: the most relevant ones, the candidates' folders, and the
        // folders this plan already proposes. Never review or Secure: unsure means wait, and
        // Secure is for what the safety checks find.
        let nearest = vector.map { neighbourhood.nearest(to: $0, excluding: key, path: facts.url.path) } ?? []
        var offered = FolderCatalog.relevant(folders, to: facts, config: config)
        for folder in nearest.compactMap(\.folder) + newFolders.values.sorted() where !offered.contains(where: { $0.path == folder }) {
            offered.append(folders.first { $0.path == folder } ?? FolderOption(path: folder, purpose: nil, tags: []))
        }
        offered.removeAll { isOffLimits($0.path) }

        let earlier = nearest.enumerated().map { index, item in
            EarlierCandidate(id: "E\(index + 1)", path: item.path, name: item.name, folder: item.folder,
                             isProposed: item.proposed, about: item.about)
        }
        var request = DecisionRequest(facts: facts, folders: offered, earlier: earlier,
                                      newFolderParents: FolderCatalog.newFolderParents(for: facts))
        request.corrections = relevantCorrections(for: facts, offered: offered).map(\.sentence)

        let answer: FolderDecision
        do {
            answer = try await classifier.decide(request)
        } catch let error as ClassifierError {
            if case .unavailable = error {
                return (.place(toReview("No rule matched; \(error)", confidence: 0)), [])
            }
            return (.wait(reason: "The model gave no usable answer, so it stays in Downloads (\(error))"), [])
        } catch {
            return (.wait(reason: "The model couldn't answer (\(error.localizedDescription)); it stays in Downloads"), [])
        }
        // Checked again here: the model's own check can't see the disk, NSU evidence or the plan.
        if let problem = answer.problem(in: request) {
            return (.wait(reason: "The model's answer was rejected (\(problem)); it stays in Downloads"), [])
        }
        let reason = answer.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        // A rejected answer mustn't leave its new folder behind for later files to join.
        let proposedBefore = newFolders
        func waiting(_ why: String) -> (verdict: Verdict, pulled: [PulledFile]) {
            newFolders = proposedBefore
            return (.wait(reason: why), [])
        }

        var destination: String
        switch answer.action {
        case .wait:
            return (.wait(reason: "Nothing like it yet: \(reason)"), [])
        case .join:
            destination = answer.folder ?? ""
        case .newFolder:
            switch newFolder(answer.folder ?? "", kind: facts.kind, inside: facts.folder, folders: folders, newFolders: &newFolders) {
            case .success(let path): destination = path
            case .failure(let problem):
                return waiting("The model's new folder was rejected (\(problem.message)): \(reason)")
            }
        }
        if let problem = destinationProblem(destination, facts: facts) {
            return waiting("The model chose \(destination), rejected (\(problem)): \(reason)")
        }

        // Earlier files that move too: listed, not already moving with another file, not
        // already in that folder.
        let chosen = Set(answer.moveEarlier)
        // (A file this plan already places elsewhere stays with that decision: first one wins.)
        let pulled = nearest.enumerated().compactMap { index, item -> PulledFile? in
            guard chosen.contains("E\(index + 1)"), !item.proposed, item.folder != destination else { return nil }
            return PulledFile(path: item.path, name: item.name, waiting: item.folder == nil)
        }
        let exists = FileManager.default.fileExists(atPath: homeRoot.appending(path: destination).path)
        let isNew = !exists && !proposedBefore.values.contains(destination)
        if isNew, pulled.isEmpty {
            return waiting("A new folder needs an earlier file to go with it, and none could move: \(reason)")
        }

        var name: String?
        if needsName(facts), let title = answer.newFileName.flatMap(Self.validTitle) {
            name = facts.kind == .image ? "\(FileNames.day(facts.image?.dateTaken ?? facts.downloadDate)) \(title)" : title
        }
        let with = pulled.isEmpty ? "" : " With \(pulled.count) earlier file\(pulled.count == 1 ? "" : "s"): \(pulled.map(\.name).joined(separator: ", "))."
        let label = isNew ? "New folder \(destination). " : ""
        let decision = Decision(destination: destination, newBaseName: name, tags: Self.tags(for: destination, folders: folders),
                                confidence: isNew ? 0.8 : 0.85, reason: label + reason + with,
                                source: .classifier(classifier.name))
        return (.place(decision), pulled)
    }

    /// Never a model's choice: the review folder (unsure means wait) and Secure (only for what the
    /// safety checks find).
    func isOffLimits(_ folder: String) -> Bool {
        for limit in [config.reviewFolder, config.secure] where folder == limit || folder.hasPrefix(limit + "/") {
            return true
        }
        return false
    }

    /// What rules out a model's destination, or nil.
    func destinationProblem(_ destination: String, facts: FileFacts) -> String? {
        if isOffLimits(destination) { return "not a folder the model may choose" }
        if let problem = DestinationValidator.problem(with: destination, config: config) { return problem }
        // University folders need NSU evidence the model can't invent: the download source,
        // "North South University" in the text, or one of your course codes.
        if destination == config.university || destination.hasPrefix(config.university + "/"), !hasNSUEvidence(facts) {
            return "no sign it's an NSU file"
        }
        return nil
    }
}

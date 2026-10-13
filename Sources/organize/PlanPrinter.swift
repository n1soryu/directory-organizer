import Foundation
import OrganizerCore

/// Prints a plan for humans: alerts first, then one block per destination folder.
struct PlanPrinter {
    var useColor: Bool

    func print(_ plan: Plan) {
        Swift.print(bold("Plan for \(plan.inputFolder.path)"))
        Swift.print(dim("Destinations are inside \(plan.homeRoot.path). Plan only: nothing has been moved.\n"))

        let alerts = plan.alerts
        if !alerts.isEmpty {
            Swift.print(bold("Alerts"))
            for (action, alert) in alerts {
                Swift.print("  \(icon(alert.kind)) \(action.originalName): \(alert.message)")
            }
            Swift.print("")
        }

        let groups = Dictionary(grouping: plan.actions, by: \.destinationFolder)
        for folder in groups.keys.sorted(by: sortFolders) {
            let actions = groups[folder]!.sorted { $0.originalName.localizedStandardCompare($1.originalName) == .orderedAscending }
            let isNew = actions.contains { $0.createsFolders.contains(folder) }
            Swift.print(bold("📁 \(folder)") + (isNew ? yellow("  (new folder)") : ""))
            for action in actions {
                let name = action.isRenamed
                    ? "\(action.originalName) \(dim("→")) \(cyan(action.finalName))"
                    : action.originalName
                Swift.print("   \(name)")
                var details = [String(format: "%3d%%", Int((action.confidence * 100).rounded()))]
                if !action.tags.isEmpty { details.append(action.tags.map(\.name).joined(separator: ", ")) }
                details.append(action.decidedBy.description)
                details.append(action.reason)
                Swift.print("      " + dim(details.joined(separator: " · ")))
            }
            Swift.print("")
        }

        if !plan.waiting.isEmpty {
            Swift.print(bold("Waiting for a full run (Organize Now)"))
            for item in plan.waiting { Swift.print("   \(item.name) \(dim("· " + item.reason))") }
            Swift.print("")
        }

        if !plan.skipped.isEmpty {
            Swift.print(bold("Skipped"))
            for item in plan.skipped { Swift.print("   \(item.name) \(dim("· " + item.reason))") }
            Swift.print("")
        }

        let byRules = plan.actions.filter { if case .rule = $0.decidedBy { true } else { false } }.count
        let bySafety = plan.actions.filter { if case .safety = $0.decidedBy { true } else { false } }.count
        let leftovers = plan.actions.count - byRules - bySafety
        let placedByModel = plan.actions.filter {
            if case .classifier = $0.decidedBy { $0.destinationFolder != OrganizerConfig().reviewFolder } else { false }
        }.count
        let named = plan.actions.filter { $0.reason.contains("name suggested by the model") }.count
        let toReview = plan.actions.filter { $0.destinationFolder == OrganizerConfig().reviewFolder }.count
        Swift.print(bold("\(plan.actions.count) items: ") +
            "\(byRules) placed by rules, \(bySafety) by safety checks, \(leftovers) left for the model " +
            "(\(placedByModel) placed by it); \(named) renamed by the model; " +
            "\(toReview) going to review, \(alerts.count) alert(s).")
    }

    /// One line for an action: "name → folder/new name  (reason)".
    func describe(_ action: ProposedAction) -> String {
        let alerts = action.alerts.map { icon($0.kind) }.joined()
        return "\(alerts.isEmpty ? "" : alerts + " ")\(action.originalName) \(dim("→")) \(cyan(action.destinationPath))\n   "
            + dim("\(Int((action.confidence * 100).rounded()))% · \(action.reason)")
    }

    // MARK: - Apply, undo, log

    func print(_ results: [ApplyResult], home: URL) {
        Swift.print("")
        for result in results {
            switch result.outcome {
            case .moved:
                Swift.print("\(green("✓")) \(result.action.originalName) \(dim("→")) \(show(result.destination?.path ?? "", home))")
            case .skipped(let why):
                Swift.print("\(yellow("–")) \(result.action.originalName): skipped, \(why)")
            case .failed(let why):
                Swift.print("\(red("✗")) \(result.action.originalName): \(why)")
            }
            for warning in result.warnings { Swift.print("   \(yellow("warning:")) \(warning)") }
        }
        let moved = results.filter { $0.outcome == .moved }.count
        Swift.print(bold("\n\(moved) of \(results.count) moved.") + " Undo with: organize undo --last")
    }

    func print(_ results: [UndoResult], home: URL) {
        Swift.print("")
        for result in results {
            let name = URL(filePath: result.record.movedPath).lastPathComponent
            if let to = result.restoredTo {
                Swift.print("\(green("↩")) \(name) \(dim("→")) \(show(to.path, home))")
            } else {
                Swift.print("\(red("✗")) \(name): \(result.error ?? "failed")")
            }
            for note in result.notes { Swift.print("   \(yellow("note:")) \(note)") }
        }
        let undone = results.filter { $0.restoredTo != nil }.count
        Swift.print(bold("\n\(undone) of \(results.count) put back."))
    }

    func printLog(_ records: [MoveRecord], home: URL) {
        guard !records.isEmpty else { Swift.print("No moves yet."); return }
        let batches = Dictionary(grouping: records, by: \.batchID)
        for (batch, moves) in batches.sorted(by: { $0.value[0].time > $1.value[0].time }) {
            let when = moves[0].time.formatted(date: .abbreviated, time: .shortened)
            Swift.print(bold("Batch \(batch.uuidString.prefix(8).lowercased())") + dim("  \(when) · \(moves.count) move(s)"))
            for move in moves {
                let state: String = switch move.state {
                case .moved: green("moved  ")
                case .undone: dim("undone ")
                case .failed: red("failed ")
                case .pending, .undoPending: yellow("pending")
                }
                Swift.print("  \(state) \(show(move.originalPath, home)) \(dim("→")) \(show(move.movedPath, home))")
            }
            Swift.print("")
        }
        Swift.print(dim("Undo a batch with: organize undo --batch <id>"))
    }

    /// Paths relative to the sandbox, e.g. "Downloads/x.pdf" or "Home/Documents/FSAE/x.pdf".
    private func show(_ path: String, _ home: URL) -> String {
        let base = home.deletingLastPathComponent().path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    /// Review last, everything else alphabetically.
    private func sortFolders(_ a: String, _ b: String) -> Bool {
        let review = OrganizerConfig().reviewFolder
        if (a == review) != (b == review) { return b == review }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    private func icon(_ kind: Alert.Kind) -> String {
        switch kind {
        case .sensitive: "🔐"
        case .duplicate: "♊️"
        case .nameClash: "⚠️ "
        case .unknownCourse: "❓"
        case .rejected: "⛔️"
        }
    }

    private func style(_ s: String, _ code: String) -> String { useColor ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    private func bold(_ s: String) -> String { style(s, "1") }
    private func dim(_ s: String) -> String { style(s, "2") }
    private func cyan(_ s: String) -> String { style(s, "36") }
    private func yellow(_ s: String) -> String { style(s, "33") }
    private func green(_ s: String) -> String { style(s, "32") }
    private func red(_ s: String) -> String { style(s, "31") }
}

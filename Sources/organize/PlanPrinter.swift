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

        if !plan.skipped.isEmpty {
            Swift.print(bold("Skipped"))
            for item in plan.skipped { Swift.print("   \(item.name) \(dim("· " + item.reason))") }
            Swift.print("")
        }

        let byRules = plan.actions.filter { if case .rule = $0.decidedBy { true } else { false } }.count
        let bySafety = plan.actions.filter { if case .safety = $0.decidedBy { true } else { false } }.count
        let leftovers = plan.actions.count - byRules - bySafety
        let toReview = plan.actions.filter { $0.destinationFolder == OrganizerConfig().reviewFolder }.count
        Swift.print(bold("\(plan.actions.count) items: ") +
            "\(byRules) placed by rules, \(bySafety) by safety checks, \(leftovers) left for the model; " +
            "\(toReview) going to review, \(alerts.count) alert(s).")
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
}

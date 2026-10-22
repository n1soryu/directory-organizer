import Foundation
import OrganizerCore

/// Asks which actions to carry out: all, one by one, or none.
struct Approval {
    var printer: PlanPrinter

    func ask(_ actions: [ProposedAction]) -> [ProposedAction] {
        let choice = prompt("\nApprove? [a] all \(actions.count) · [o] one by one · [c] cancel: ")
        switch choice {
        case "a": return actions
        case "o": return oneByOne(actions)
        default: return []
        }
    }

    /// A group (a new file and the earlier files the model put with it) is asked about once:
    /// all of it or none of it.
    private func oneByOne(_ actions: [ProposedAction]) -> [ProposedAction] {
        var units: [[ProposedAction]] = []
        for action in actions {
            if let group = action.groupID, let index = units.firstIndex(where: { $0.first?.groupID == group }) {
                units[index].append(action)
            } else {
                units.append([action])
            }
        }
        var approved: [ProposedAction] = []
        for (index, unit) in units.enumerated() {
            let shown = unit.map(printer.describe).joined(separator: "\n   + ")
            print("\n[\(index + 1)/\(units.count)] \(unit.count > 1 ? "Together: " : "")\(shown)")
            switch prompt("   [y] yes · [n] no · [q] stop asking (skip the rest): ") {
            case "y": approved += unit
            case "q": return approved
            default: continue
            }
        }
        return approved
    }

    /// The first letter of the answer, lowercased. End of input counts as cancel.
    private func prompt(_ text: String) -> Character {
        print(text, terminator: "")
        fflush(stdout)
        return readLine()?.trimmingCharacters(in: .whitespaces).lowercased().first ?? "c"
    }
}

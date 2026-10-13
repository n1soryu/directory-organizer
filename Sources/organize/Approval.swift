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

    private func oneByOne(_ actions: [ProposedAction]) -> [ProposedAction] {
        var approved: [ProposedAction] = []
        for (index, action) in actions.enumerated() {
            print("\n[\(index + 1)/\(actions.count)] \(printer.describe(action))")
            switch prompt("   [y] yes · [n] no · [q] stop asking (skip the rest): ") {
            case "y": approved.append(action)
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

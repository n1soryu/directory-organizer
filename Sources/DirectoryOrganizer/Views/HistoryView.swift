import OrganizerCore
import SwiftUI

/// Every move and undo from the log, grouped by batch. Anything still in place can be undone.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var showUndone = true

    var body: some View {
        let records = model.records.filter { showUndone || $0.state != .undone }
        let batches = Dictionary(grouping: records, by: \.batchID)
            .sorted { ($0.value.map(\.time).min() ?? .distantPast) > ($1.value.map(\.time).min() ?? .distantPast) }
        Page {
            SectionTitle(title: "History", subtitle: "Every move, grouped by when you approved it. Anything still in place can be put back exactly as it was.")
            if batches.isEmpty {
                Card {
                    ContentUnavailableView("No moves yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("Approved moves appear here, and every one can be undone."))
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            ForEach(batches, id: \.key) { batchID, moves in
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        BatchHeader(batchID: batchID, moves: moves)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(Color.primary.opacity(0.03))
                        ForEach(moves.sorted { $0.time > $1.time }, id: \.moveID) { move in
                            Divider().padding(.leading, 16)
                            HistoryRow(move: move).padding(.horizontal, 16).padding(.vertical, 6)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
        }
        .toolbar {
            ToolbarItem {
                Toggle("Show undone", isOn: $showUndone)
            }
            ToolbarItem {
                Button("Move Log", systemImage: "doc.text") { model.reveal(model.journal.url) }
                    .help("Show the move log (moves.jsonl) in Finder")
            }
        }
    }
}

private struct BatchHeader: View {
    @Environment(AppModel.self) private var model
    let batchID: UUID
    let moves: [MoveRecord]

    var body: some View {
        let moved = moves.filter { $0.state == .moved }.count
        let when = moves.map(\.time).min() ?? Date()
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(when.short).font(.headline)
                Text("Batch \(batchID.uuidString.prefix(8).lowercased()) · \(moves.count) file\(moves.count == 1 ? "" : "s") · \(moved) still in place")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.undoBatch(batchID) } label: { Label("Undo batch", systemImage: "arrow.uturn.backward") }
                .buttonStyle(SoftButtonStyle(tint: .orange))
                .disabled(moved == 0 || model.isApplying)
        }
        .padding(.vertical, 4)
    }
}

private struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let move: MoveRecord

    var body: some View {
        let current = URL(filePath: move.state == .undone ? (move.restoredPath ?? move.originalPath) : move.movedPath)
        HStack(alignment: .top, spacing: 10) {
            LaneIcon(lane: Lane.of(model.homeRelative(move.movedPath)), size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StateBadge(state: move.state)
                    Text(URL(filePath: move.originalPath).lastPathComponent).fontWeight(.medium)
                }
                Text("\(model.display(move.originalPath)) → \(model.display(move.movedPath))")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let restored = move.restoredPath, move.state == .undone {
                    Text("Put back at \(model.display(restored))").font(.caption).foregroundStyle(.secondary)
                }
                if let reason = move.reason { Text(reason).font(.caption).foregroundStyle(.tertiary) }
                if !move.tagsAfter.isEmpty, move.state == .moved {
                    TagsView(tags: move.tagsAfter.map(FinderTags.decode))
                }
            }
            Spacer()
            Text(move.time.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            Button("Undo", systemImage: "arrow.uturn.backward") { model.undo([move]) }
                .labelStyle(.iconOnly)
                .disabled(move.state != .moved || model.isApplying)
                .help("Put it back exactly as it was")
            Button("Show in Finder", systemImage: "folder") { model.reveal(current) }
                .labelStyle(.iconOnly)
        }
        .padding(.vertical, 3)
    }
}

private struct StateBadge: View {
    let state: MoveRecord.State

    var body: some View {
        let (text, color): (String, Color) = switch state {
        case .moved: ("Moved", .green)
        case .undone: ("Undone", .secondary)
        case .failed: ("Failed", .red)
        case .pending, .undoPending: ("Interrupted", .orange)
        }
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

import OrganizerCore
import SwiftUI

/// Every alert in the current plan, one card per kind, with what it means.
struct AlertsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = Dictionary(grouping: model.pending.flatMap { action in action.alerts.map { (action, $0) } }, by: \.1.kind)
        let order: [FileAlert.Kind] = [.sensitive, .duplicate, .rejected, .nameClash, .unknownCourse]
        Page {
            SectionTitle(title: "Alerts", subtitle: "Things worth a look before you approve. Nothing here moves on its own.")
            if groups.isEmpty {
                Card {
                    ContentUnavailableView("All clear", systemImage: "checkmark.shield",
                                           description: Text("Sensitive files, duplicates, name clashes, unknown courses and rejected model suggestions show up here."))
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            ForEach(order.filter { groups[$0] != nil }, id: \.self) { kind in
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: kind.systemImage)
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(kind.color.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(kind.title) · \(groups[kind]!.count)").font(.headline)
                                Text(kind.explanation).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(kind.color.opacity(0.06))
                        ForEach(groups[kind]!, id: \.1) { action, alert in
                            Divider().padding(.leading, 16)
                            HStack(spacing: 12) {
                                FileIcon(url: action.source, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.originalName).fontWeight(.medium)
                                    Text(alert.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary)
                                        PathView(path: action.destinationFolder, font: .caption)
                                    }
                                }
                                Spacer()
                                Button("Details") {
                                    model.selection = [action.id]
                                    model.page = .pending
                                }
                                .buttonStyle(SoftButtonStyle(tint: .secondary))
                                CircleIconButton(symbol: "checkmark", color: .green, help: "Approve") { model.approve([action.id]) }
                                    .disabled(model.isApplying)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
        }
    }
}

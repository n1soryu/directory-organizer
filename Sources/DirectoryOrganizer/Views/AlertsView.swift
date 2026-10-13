import OrganizerCore
import SwiftUI

/// Every alert in the current plan, grouped by kind, with what it means.
struct AlertsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = Dictionary(grouping: model.pending.flatMap { action in action.alerts.map { (action, $0) } }, by: \.1.kind)
        let order: [FileAlert.Kind] = [.sensitive, .duplicate, .rejected, .nameClash, .unknownCourse]
        if groups.isEmpty {
            ContentUnavailableView("No alerts", systemImage: "checkmark.shield",
                                   description: Text("Sensitive files, duplicates, name clashes, unknown courses and rejected model suggestions show up here."))
        } else {
            List {
                ForEach(order.filter { groups[$0] != nil }, id: \.self) { kind in
                    Section {
                        ForEach(groups[kind]!, id: \.1) { action, alert in
                            HStack(alignment: .top, spacing: 10) {
                                FileIcon(url: action.source, size: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(action.originalName).fontWeight(.medium)
                                    Text(alert.message).foregroundStyle(.secondary).textSelection(.enabled)
                                    Text("→ \(action.destinationPath)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Show") {
                                    model.selection = [action.id]
                                    model.page = .pending
                                }
                                Button("Approve") { model.approve([action.id]) }
                                    .disabled(model.isApplying)
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("\(kind.title) (\(groups[kind]!.count))", systemImage: kind.systemImage)
                                .foregroundStyle(kind.color).font(.headline)
                            Text(kind.explanation).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

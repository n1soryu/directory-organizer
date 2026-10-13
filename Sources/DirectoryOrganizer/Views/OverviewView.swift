import OrganizerCore
import SwiftUI

/// Everything at a glance: counts, what needs attention, the last scan and recent activity.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: columns, spacing: 12) {
                    StatCard(title: "Pending approval", value: "\(model.pending.count)", systemImage: "tray.full",
                             detail: breakdown, action: { model.page = .pending })
                    StatCard(title: "Alerts", value: "\(model.alertActions.count)", systemImage: "exclamationmark.triangle",
                             tint: model.alertActions.isEmpty ? .secondary : .red,
                             detail: alertDetail, action: { model.page = .alerts })
                    StatCard(title: "In review folder", value: "\(model.reviewItems.count)", systemImage: "archivebox",
                             tint: .orange,
                             detail: model.reviewItems.isEmpty ? "Empty, no reminder needed" : "Next reminder \(model.nextReminder.relative)",
                             action: { model.page = .review })
                    StatCard(title: "Moved", value: "\(model.movedRecords.count)", systemImage: "checkmark.circle",
                             tint: .green, detail: "\(model.movedToday) today · all can be undone",
                             action: { model.page = .history })
                    StatCard(title: "Model", value: modelValue, systemImage: "sparkles", tint: .purple,
                             detail: modelDetail, action: { model.page = .settings })
                    StatCard(title: "Watching", value: model.isWatching ? "On" : "Paused", systemImage: "eye",
                             tint: model.isWatching ? .green : .orange, detail: model.display(model.watchedURL),
                             action: { model.page = .settings })
                }

                if !model.alertActions.isEmpty {
                    DetailSection(title: "Needs your attention") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.alertActions.prefix(6)) { action in
                                ForEach(action.alerts, id: \.self) { alert in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: alert.kind.systemImage).foregroundStyle(alert.kind.color)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(action.originalName).fontWeight(.medium)
                                            Text(alert.message).font(.callout).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            Button("Show all alerts") { model.page = .alerts }.buttonStyle(.link)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                HStack(alignment: .top, spacing: 20) {
                    DetailSection(title: "Last scan") {
                        VStack(alignment: .leading, spacing: 4) {
                            InfoRow(label: "Folder", value: model.display(model.watchedURL))
                            InfoRow(label: "Files home", value: model.display(model.homeURL))
                            InfoRow(label: "When", value: model.lastScan.map { "\($0.short) (\($0.relative))" } ?? "not yet")
                            InfoRow(label: "Took", value: model.lastScanDuration.map { String(format: "%.1f s", $0) } ?? "–")
                            InfoRow(label: "Found", value: "\(model.pending.count + model.rejected.count) files, \(model.rejected.count) rejected")
                            InfoRow(label: "Skipped", value: model.skipped.isEmpty ? "none" : model.skipped.map { "\($0.name) (\($0.reason))" }.joined(separator: ", "))
                        }
                        HStack {
                            Button("Scan Now", systemImage: "arrow.clockwise") { model.requestScan() }
                                .disabled(model.isScanning)
                            Button(model.isWatching ? "Pause Watching" : "Resume Watching",
                                   systemImage: model.isWatching ? "pause" : "play") { model.setWatching(!model.isWatching) }
                            Button("Open Folder", systemImage: "folder") { NSWorkspace.shared.open(model.watchedURL) }
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    DetailSection(title: "How files were decided") {
                        DecisionBreakdown(actions: model.pending)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                DetailSection(title: "Activity") {
                    if model.activity.isEmpty {
                        Text("Nothing yet.").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.activity.prefix(40)) { event in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: event.systemImage).foregroundStyle(event.color).frame(width: 16)
                                    Text(event.text).textSelection(.enabled)
                                    Spacer()
                                    Text(event.date.formatted(date: .omitted, time: .standard))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var breakdown: String {
        let toReview = model.pending.filter { $0.destinationFolder == OrganizerConfig().reviewFolder }.count
        let newFolders = Set(model.pending.flatMap(\.createsFolders)).count
        return "\(toReview) to review · \(newFolders) new folder\(newFolders == 1 ? "" : "s")"
    }

    private var alertDetail: String {
        let kinds = Dictionary(grouping: model.pending.flatMap(\.alerts), by: \.kind)
        return kinds.isEmpty ? "All clear" : kinds.map { "\($0.value.count) \($0.key.title.lowercased())" }.sorted().joined(separator: " · ")
    }

    private var modelValue: String {
        guard model.settings.useModel else { return "Off" }
        return model.modelUnavailableReason == nil ? "Ready" : "Unavailable"
    }

    private var modelDetail: String {
        guard model.settings.useModel else { return "Rules only" }
        if let reason = model.modelUnavailableReason { return reason }
        return "Apple on-device\(model.modelSeesImages ? " · sees images" : "")"
    }
}

/// Counts by who decided: safety checks, each rule, the model.
private struct DecisionBreakdown: View {
    let actions: [ProposedAction]

    var body: some View {
        let groups = Dictionary(grouping: actions, by: \.decidedBy.label)
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        if groups.isEmpty {
            Text("Nothing pending.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(groups, id: \.key) { label, items in
                    HStack {
                        DecidedByView(source: items[0].decidedBy)
                        Spacer()
                        Text("\(items.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

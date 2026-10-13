import OrganizerCore
import SwiftUI

/// What's in Desktop/To Delete (Review), why each item is there, and the reminder schedule.
struct ReviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.display(model.reviewURL)).font(.headline)
                    Text("Installers, firmware, duplicates, code projects, password exports and anything uncertain wait here for you. Nothing here is ever deleted by the app.")
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(3)
                    Text("Reminder every \(Int(model.settings.reviewReminderHours)) hours while it isn't empty · next \(model.nextReminder.relative)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remind Me Now", systemImage: "bell") { Task { await model.checkReviewReminder(force: true) } }
                    .disabled(model.reviewItems.isEmpty)
                Button("Open in Finder", systemImage: "folder") { NSWorkspace.shared.open(model.reviewURL) }
            }
            .padding()
            Divider()

            if model.reviewItems.isEmpty {
                ContentUnavailableView("Review folder is empty", systemImage: "archivebox",
                                       description: Text("Nothing to check."))
            } else {
                Table(model.reviewItems) {
                    TableColumn("File") { item in
                        HStack(spacing: 6) {
                            FileIcon(url: item.url)
                            Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .width(min: 180, ideal: 260)
                    TableColumn("Why it's here") { item in
                        Text(item.reason ?? "not moved here by the app")
                            .foregroundStyle(item.reason == nil ? .tertiary : .primary)
                            .lineLimit(2)
                            .help(item.reason ?? "")
                    }
                    .width(min: 200, ideal: 380)
                    TableColumn("Size") { item in
                        Text(item.size.fileSize).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(70)
                    TableColumn("Added") { item in
                        Text(item.added?.short ?? "–").foregroundStyle(.secondary)
                    }
                    .width(min: 110, ideal: 140)
                    TableColumn("") { item in
                        HStack {
                            if let record = item.record {
                                Button("Put Back", systemImage: "arrow.uturn.backward") { model.undo([record]) }
                                    .labelStyle(.iconOnly)
                                    .help("Undo: put it back where it came from")
                                    .disabled(model.isApplying)
                            }
                            Button("Show in Finder", systemImage: "folder") { model.reveal(item.url) }
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                    }
                    .width(60)
                }
            }
        }
        .onAppear { model.refreshReviewFolder() }
    }
}

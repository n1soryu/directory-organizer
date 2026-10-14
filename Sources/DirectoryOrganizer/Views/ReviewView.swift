import OrganizerCore
import SwiftUI

/// What's in Desktop/To Delete (Review), why each item is there, and the reminder schedule.
struct ReviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page {
            HStack(alignment: .center, spacing: 14) {
                LaneIcon(lane: Lane.of(OrganizerConfig().reviewFolder), size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review folder").font(.title2.weight(.bold))
                    Text("Installers, duplicates, code projects, password exports and unsure files wait here. The app never deletes anything.")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button { NSWorkspace.shared.open(model.reviewURL) } label: { Label("Open in Finder", systemImage: "folder") }
                    .buttonStyle(SoftButtonStyle())
            }

            Card {
                HStack(spacing: 12) {
                    Image(systemName: "bell.badge").foregroundStyle(.orange).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reminder every \(Int(model.settings.reviewReminderHours)) hours while it isn't empty").font(.callout.weight(.medium))
                        Text(model.reviewItems.isEmpty ? "Empty, so no reminders." : "Next reminder \(model.nextReminder.relative)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remind me now") { Task { await model.checkReviewReminder(force: true) } }
                        .buttonStyle(SoftButtonStyle(tint: .orange))
                        .disabled(model.reviewItems.isEmpty)
                }
            }

            if model.reviewItems.isEmpty {
                Card {
                    ContentUnavailableView("Nothing to review", systemImage: "archivebox", description: Text("The review folder is empty."))
                        .frame(maxWidth: .infinity, minHeight: 220)
                }
            } else {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.reviewItems.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().padding(.leading, 60) }
                            HStack(spacing: 12) {
                                FileIcon(url: item.url, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.url.lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                                    Text(item.reason ?? "not moved here by the app")
                                        .font(.caption).foregroundStyle(item.reason == nil ? .tertiary : .secondary).lineLimit(2)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(item.size.fileSize).font(.caption.monospacedDigit())
                                    Text(item.added?.relative ?? "").font(.caption2).foregroundStyle(.tertiary)
                                }
                                if let record = item.record {
                                    Button { model.undo([record]) } label: { Label("Put back", systemImage: "arrow.uturn.backward") }
                                        .buttonStyle(SoftButtonStyle(tint: .orange))
                                        .help("Undo: put it back where it came from")
                                        .disabled(model.isApplying)
                                }
                                Button { model.reveal(item.url) } label: { Image(systemName: "folder") }
                                    .buttonStyle(SoftButtonStyle(tint: .secondary))
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                        }
                    }
                }
            }
        }
        .onAppear { model.refreshReviewFolder() }
    }
}

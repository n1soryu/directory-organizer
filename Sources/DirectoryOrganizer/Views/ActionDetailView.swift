import OrganizerCore
import SwiftUI

/// Everything about one proposed move: preview, where it goes and why, alerts, and every
/// fact read from the file (the same facts the rules and the model saw).
struct ActionDetailView: View {
    @Environment(AppModel.self) private var model
    let action: ProposedAction
    let isRejected: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ThumbnailView(url: action.source)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(action.originalName).font(.title3.weight(.semibold)).textSelection(.enabled)
                    if action.isRenamed {
                        Label(action.finalName, systemImage: "arrow.turn.down.right")
                            .foregroundStyle(.blue).textSelection(.enabled)
                    }
                }

                buttons

                DetailSection(title: "Plan") {
                    InfoRow(label: "Goes to", value: action.destinationFolder)
                    InfoRow(label: "Full path", value: model.display(model.homeURL.appending(path: action.destinationPath).path))
                    if !action.createsFolders.isEmpty {
                        InfoRow(label: "New folders", value: action.createsFolders.joined(separator: "\n"))
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text("Tags").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        if action.tags.isEmpty { Text("none").foregroundStyle(.tertiary) } else { TagsView(tags: action.tags) }
                    }
                    .font(.callout)
                    HStack(alignment: .firstTextBaseline) {
                        Text("Confidence").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        ConfidenceView(value: action.confidence)
                    }
                    .font(.callout)
                    HStack(alignment: .firstTextBaseline) {
                        Text("Decided by").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        DecidedByView(source: action.decidedBy)
                    }
                    .font(.callout)
                    InfoRow(label: "Why", value: action.reason)
                }

                if !action.alerts.isEmpty {
                    DetailSection(title: "Alerts") {
                        ForEach(action.alerts, id: \.self) { alert in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(alert.kind.title, systemImage: alert.kind.systemImage)
                                    .foregroundStyle(alert.kind.color).fontWeight(.medium)
                                Text(alert.message).textSelection(.enabled)
                                Text(alert.kind.explanation).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(alert.kind.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                if let facts = action.facts {
                    FactsSection(facts: facts)
                }
            }
            .padding()
        }
    }

    private var buttons: some View {
        HStack {
            if isRejected {
                Button("Put Back in Plan") { model.reconsider([action.id]) }
            } else {
                Button("Approve", systemImage: "checkmark") { model.approve([action.id]) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isApplying)
                Button("Reject", systemImage: "xmark") { model.reject([action.id]) }
            }
            Spacer()
            Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(action.source) }
                .labelStyle(.iconOnly).help("Open the file")
            Button("Show in Finder", systemImage: "folder") { model.reveal(action.source) }
                .labelStyle(.iconOnly).help("Show in Finder")
        }
    }
}

/// The facts read from a file, without any model.
struct FactsSection: View {
    let facts: FileFacts

    var body: some View {
        DetailSection(title: "What was read from the file") {
            InfoRow(label: "Type", value: "\(facts.kind.rawValue)\(facts.fileExtension.isEmpty ? "" : " (.\(facts.fileExtension))")")
            InfoRow(label: "Size", value: facts.size.fileSize)
            InfoRow(label: "Downloaded", value: facts.downloadDate.short)
            if let created = facts.created { InfoRow(label: "Created", value: created.short) }
            if let modified = facts.modified { InfoRow(label: "Modified", value: modified.short) }
            InfoRow(label: "Name", value: facts.nameIsUnclear ? "unclear (says little about the file)" : "clear")
            if facts.whereFroms.isEmpty {
                InfoRow(label: "Source", value: "not recorded")
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Source").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(facts.whereFroms, id: \.self) { source in
                            if let url = URL(string: source), url.scheme?.hasPrefix("http") == true {
                                Link(source, destination: url).lineLimit(2)
                            } else {
                                Text(source).lineLimit(2)
                            }
                        }
                    }
                }
                .font(.callout)
            }
            if let title = facts.documentTitle { InfoRow(label: "Title", value: title) }
            if let pages = facts.pageCount { InfoRow(label: "Pages", value: "\(pages)") }
            if let duration = facts.media?.duration {
                InfoRow(label: "Length", value: Duration.seconds(duration).formatted(.time(pattern: .hourMinuteSecond)))
            }
            if let title = facts.media?.title { InfoRow(label: "Media title", value: title) }
            if let image = facts.image {
                if let w = image.width, let h = image.height { InfoRow(label: "Dimensions", value: "\(w) × \(h)") }
                if let taken = image.dateTaken { InfoRow(label: "Taken", value: taken.short) }
                if let camera = image.cameraModel { InfoRow(label: "Camera", value: camera) }
            }
            if facts.isScreenshot { InfoRow(label: "Screenshot", value: "yes") }
            if let entries = facts.archiveEntries, !entries.isEmpty {
                InfoRow(label: "Contains", value: entries.prefix(12).joined(separator: "\n") + (entries.count > 12 ? "\n… \(entries.count - 12) more" : ""))
            }
            ForEach(facts.notes, id: \.self) { InfoRow(label: "Note", value: $0) }

            if let text = facts.text, !text.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(textLabel).font(.callout).foregroundStyle(.secondary)
                    ScrollView {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 220)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(.top, 4)
            }
        }
    }

    private var textLabel: String {
        switch facts.textSource {
        case .imageOCR: "Text recognized in the image (OCR)"
        case .pdfOCR: "Text recognized in the scanned pages (OCR)"
        case .pdfText: "Text from the PDF"
        case .office: "Text from the document"
        default: "Beginning of the file"
        }
    }
}

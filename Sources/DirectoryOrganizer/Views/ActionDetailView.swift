import OrganizerCore
import SwiftUI

/// Everything about one proposed move: preview, a clear from → to, why, alerts, and every
/// fact read from the file (the same facts the rules and the model saw).
struct ActionDetailView: View {
    @Environment(AppModel.self) private var model
    let action: ProposedAction
    let isRejected: Bool

    var body: some View {
        let lane = Lane.of(action.destinationFolder)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ThumbnailView(url: action.source)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))

                // From → To
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        FileIcon(url: action.source, size: 24)
                        Text(action.originalName).font(.headline).textSelection(.enabled).lineLimit(2)
                    }
                    Image(systemName: "arrow.down")
                        .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .padding(.leading, 7)
                    HStack(alignment: .top, spacing: 10) {
                        LaneIcon(lane: lane, size: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            PathView(path: action.destinationFolder)
                            Text(action.finalName)
                                .font(.callout.weight(action.isRenamed ? .semibold : .regular))
                                .foregroundStyle(action.isRenamed ? .blue : .secondary)
                                .textSelection(.enabled)
                            if !action.createsFolders.isEmpty {
                                Chip(text: "Creates " + action.createsFolders.map { $0.split(separator: "/").last.map(String.init) ?? $0 }.joined(separator: ", "),
                                     symbol: "folder.badge.plus", color: .orange)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(lane.color.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))

                HStack(spacing: 10) {
                    ConfidenceRing(value: action.confidence, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        DecidedByView(source: action.decidedBy)
                        Text(action.reason).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !action.tags.isEmpty {
                    HStack { Text("Tags").foregroundStyle(.secondary); TagsView(tags: action.tags) }.font(.callout)
                }

                buttons

                ForEach(action.alerts, id: \.self) { alert in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: alert.kind.systemImage)
                            .foregroundStyle(alert.kind.color)
                            .frame(width: 28, height: 28)
                            .background(alert.kind.color.opacity(0.14), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(alert.kind.title).fontWeight(.semibold)
                            Text(alert.message).font(.callout).textSelection(.enabled)
                            Text(alert.kind.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(alert.kind.color.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
                }

                if let facts = action.facts {
                    FactsSection(facts: facts)
                }
            }
            .padding(18)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if isRejected {
                Button("Put back in plan") { model.reconsider([action.id]) }.buttonStyle(SoftButtonStyle())
            } else {
                Button { model.approve([action.id]) } label: { Label("Approve", systemImage: "checkmark") }
                    .buttonStyle(GradientButtonStyle())
                    .disabled(model.isApplying)
                Button { model.reject([action.id]) } label: { Label("Reject", systemImage: "xmark") }
                    .buttonStyle(SoftButtonStyle(tint: .red))
            }
            Spacer()
            Button { NSWorkspace.shared.open(action.source) } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(SoftButtonStyle(tint: .secondary)).help("Open the file")
            Button { model.reveal(action.source) } label: { Image(systemName: "folder") }
                .buttonStyle(SoftButtonStyle(tint: .secondary)).help("Show in Finder")
        }
    }
}

/// The facts read from a file, without any model.
struct FactsSection: View {
    let facts: FileFacts

    var body: some View {
        DetailSection(title: "What was read from the file") {
            Divider()
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
                    .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
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

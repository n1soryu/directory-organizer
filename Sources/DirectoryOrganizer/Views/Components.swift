import AppKit
import OrganizerCore
import QuickLookThumbnailing
import SwiftUI

/// SwiftUI's `@State` property wrapper. In the macOS 27 SDK, `@State` also names a macro whose
/// plugin ships only with Xcode, so with just the Command Line Tools the plain name fails to build.
/// The alias always means the property wrapper.
typealias ViewState<Value> = SwiftUI.State<Value>

/// The organizer's alert (not SwiftUI's `Alert`).
typealias FileAlert = OrganizerCore.Alert

extension TagColor {
    var color: Color {
        switch self {
        case .none: .secondary
        case .gray: .gray
        case .green: .green
        case .purple: .purple
        case .blue: .blue
        case .yellow: .yellow
        case .red: .red
        case .orange: .orange
        }
    }
}

/// Finder-style tags: colored dot and name.
struct TagsView: View {
    let tags: [Tag]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 3) {
                    Circle().fill(tag.color.color).frame(width: 8, height: 8)
                    Text(tag.name).font(.caption)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tag.color.color.opacity(0.15), in: Capsule())
            }
        }
    }
}

/// A small bar plus percentage. Green when confident, orange when borderline, red when low.
struct ConfidenceView: View {
    let value: Double

    var color: Color { value >= 0.9 ? .green : value >= 0.75 ? .orange : .red }

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: geo.size.width * value)
                }
            }
            .frame(width: 44, height: 5)
            Text("\(Int((value * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

extension DecisionSource {
    var label: String {
        switch self {
        case .safety(let name): "Safety · \(name)"
        case .rule(let name): "Rule · \(name)"
        case .classifier(let name): name == "none" ? "No rule, no model" : "Model · \(name)"
        }
    }

    var systemImage: String {
        switch self {
        case .safety: "shield.lefthalf.filled"
        case .rule: "list.bullet.rectangle"
        case .classifier: "sparkles"
        }
    }

    var color: Color {
        switch self {
        case .safety: .red
        case .rule: .blue
        case .classifier: .purple
        }
    }
}

struct DecidedByView: View {
    let source: DecisionSource

    var body: some View {
        Label(source.label, systemImage: source.systemImage)
            .font(.caption)
            .foregroundStyle(source.color)
            .lineLimit(1)
    }
}

extension FileAlert.Kind {
    var title: String {
        switch self {
        case .sensitive: "Sensitive file"
        case .duplicate: "Duplicate"
        case .nameClash: "Name clash"
        case .unknownCourse: "Unknown course"
        case .rejected: "Suggestion rejected"
        }
    }

    var systemImage: String {
        switch self {
        case .sensitive: "lock.shield.fill"
        case .duplicate: "plus.square.on.square"
        case .nameClash: "textformat.alt"
        case .unknownCourse: "questionmark.folder"
        case .rejected: "hand.raised.fill"
        }
    }

    var color: Color {
        switch self {
        case .sensitive: .red
        case .duplicate: .orange
        case .nameClash: .yellow
        case .unknownCourse: .blue
        case .rejected: .purple
        }
    }

    /// What this alert means, in plain words.
    var explanation: String {
        switch self {
        case .sensitive: "Passwords, a recovery phrase, a private key or credentials. Plain-text password exports go to review so you can delete them after importing; everything else goes to Secure."
        case .duplicate: "Byte-for-byte identical to another file (same SHA-256). The copy goes to review; nothing is deleted."
        case .nameClash: "A different file with the same name is already there. Nothing is overwritten: this one gets the date added to its name."
        case .unknownCourse: "Looks like a course code that isn't in your course list, so no course folder is created."
        case .rejected: "A suggestion broke a safety rule (folder not allowed, not offered, or no NSU evidence), so the file goes to review."
        }
    }
}

struct AlertIcons: View {
    let alerts: [FileAlert]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Set(alerts.map(\.kind))).sorted { $0.rawValue < $1.rawValue }, id: \.self) { kind in
                Image(systemName: kind.systemImage)
                    .foregroundStyle(kind.color)
                    .help(kind.title)
            }
        }
    }
}

/// The Finder icon for a file (or its type, if it has moved).
struct FileIcon: View {
    let url: URL
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: size, height: size)
    }

    private var icon: NSImage {
        if FileManager.default.fileExists(atPath: url.path) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .init(filenameExtension: url.pathExtension) ?? .data)
    }
}

/// A Quick Look preview image of a file, generated by macOS.
struct ThumbnailView: View {
    let url: URL
    @ViewState private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                FileIcon(url: url, size: 96)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 220)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 440, height: 440),
                                                       scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}

/// A number with a label, for the overview.
struct StatCard: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = .accentColor
    var detail: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(detail ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

/// A titled box for detail sections.
struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Label    value" rows for detail views.
struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(monospaced ? .body.monospaced() : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

extension Date {
    var relative: String { formatted(.relative(presentation: .named)) }
    var short: String { formatted(date: .abbreviated, time: .shortened) }
}

extension Int64 {
    var fileSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

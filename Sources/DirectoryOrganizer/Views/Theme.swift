import AppKit
import OrganizerCore
import SwiftUI

/// The app's look: rounded cards on the window background, one gradient for the main
/// action, and a color + symbol per destination ("lane") used everywhere.
enum Theme {
    static let radius: CGFloat = 16
    static let smallRadius: CGFloat = 10
    static let pagePadding: CGFloat = 24

    static let gradient = LinearGradient(
        colors: [Color(red: 0.33, green: 0.45, blue: 1.0), Color(red: 0.62, green: 0.33, blue: 0.98)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let card = Color(nsColor: .controlBackgroundColor)
    static let page = Color(nsColor: .windowBackgroundColor)
}

/// Where a file is headed, as a color and a symbol.
struct Lane: Hashable {
    let name: String
    let symbol: String
    let color: Color

    static func of(_ folder: String) -> Lane {
        let review = OrganizerConfig().reviewFolder
        if folder == review || folder.hasPrefix(review + "/") { return Lane(name: "Review", symbol: "archivebox.fill", color: .gray) }
        let table: [(String, Lane)] = [
            ("Documents/Secure", Lane(name: "Secure", symbol: "lock.fill", color: .red)),
            ("Documents/Essays", Lane(name: "Essays", symbol: "text.quote", color: .purple)),
            ("Documents", Lane(name: "Documents", symbol: "doc.text.fill", color: .teal)),
            ("Movies", Lane(name: "Movies", symbol: "film.fill", color: .orange)),
            ("Pictures", Lane(name: "Pictures", symbol: "photo.fill", color: .pink)),
            ("Music", Lane(name: "Music", symbol: "music.note", color: .indigo)),
            ("Developer", Lane(name: "Developer", symbol: "chevron.left.forwardslash.chevron.right", color: .mint)),
        ]
        return table.first { folder == $0.0 || folder.hasPrefix($0.0 + "/") }?.1
            ?? Lane(name: "Other", symbol: "folder.fill", color: .secondary)
    }

    /// Lanes in a stable display order.
    static let order = ["Secure", "Essays", "Documents", "Movies", "Pictures", "Music", "Developer", "Other", "Review"]
}

// MARK: - Building blocks

/// A rounded card on the page background.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(.separator.opacity(0.5)))
            .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
    }
}

/// The lane's symbol in a colored rounded square.
struct LaneIcon: View {
    let lane: Lane
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: lane.symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(lane.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

/// "Documents › Bills › Water" with the last part emphasized.
struct PathView: View {
    let path: String
    var font: Font = .callout

    var body: some View {
        let parts = path.split(separator: "/").map(String.init)
        HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Image(systemName: "chevron.compact.right").font(.caption2).foregroundStyle(.tertiary)
                }
                Text(part)
                    .fontWeight(index == parts.count - 1 ? .semibold : .regular)
                    .foregroundStyle(index == parts.count - 1 ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .font(font)
    }
}

/// A circular confidence gauge.
struct ConfidenceRing: View {
    let value: Double
    var size: CGFloat = 30

    var color: Color { value >= 0.9 ? .green : value >= 0.75 ? .orange : .red }

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 3)
            Circle().trim(from: 0, to: value)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((value * 100).rounded()))")
                .font(.system(size: size * 0.32, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
        .help("Confidence \(Int((value * 100).rounded()))%")
    }
}

/// A small capsule label.
struct Chip: View {
    let text: String
    var symbol: String? = nil
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// The main call to action: gradient capsule.
struct GradientButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .headline : .callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 20 : 14)
            .padding(.vertical, large ? 11 : 7)
            .background(Theme.gradient, in: Capsule())
            .shadow(color: Color(red: 0.45, green: 0.38, blue: 1).opacity(isEnabled ? 0.35 : 0), radius: 8, y: 3)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary actions: a tinted capsule.
struct SoftButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tint.opacity(configuration.isPressed ? 0.22 : 0.12), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Round icon buttons for approve / reject on a row.
struct CircleIconButton: View {
    let symbol: String
    let color: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(color.opacity(0.13), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Page scaffold: scrollable, padded, on the window background.
struct Page<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .padding(Theme.pagePadding)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.page)
    }
}

/// A section title inside a page.
struct SectionTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

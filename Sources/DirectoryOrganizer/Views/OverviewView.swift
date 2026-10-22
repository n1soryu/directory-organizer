import OrganizerCore
import SwiftUI

/// The home page: a hero with the main action, four numbers, where files are headed,
/// what needs attention, and what just happened.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page {
            Hero()

            HStack(spacing: 14) {
                MetricTile(value: model.pending.count, label: "Ready to file", symbol: "tray.full.fill", color: .blue) { model.page = .pending }
                MetricTile(value: model.waiting.count, label: "Need Organize Now", symbol: "wand.and.sparkles", color: .purple) { model.page = .pending }
                MetricTile(value: model.alertActions.count, label: "Alerts", symbol: "exclamationmark.triangle.fill", color: .red) { model.page = .alerts }
                MetricTile(value: model.reviewItems.count, label: "In review", symbol: "archivebox.fill", color: .orange) { model.page = .review }
            }

            LaneDistribution(actions: model.pending)

            HStack(alignment: .top, spacing: 14) {
                AttentionCard()
                ActivityCard()
            }

            Card {
                HStack(spacing: 24) {
                    StatusItem(symbol: "eye", title: model.isWatching ? "Watching" : "Paused",
                               detail: "Quick scans of \(model.display(model.watchedURL))")
                    StatusItem(symbol: "arrow.clockwise", title: "Last quick scan",
                               detail: model.lastScan.map { "\($0.relative) · \(String(format: "%.1f", model.lastScanDuration ?? 0)) s" } ?? "not yet")
                    StatusItem(symbol: "wand.and.sparkles", title: "Last Organize Now",
                               detail: model.lastFullRun.map { "\($0.date.relative) · \($0.cancelled ? "cancelled" : "\($0.files) files")" } ?? "not yet")
                    StatusItem(symbol: "sparkles", title: modelTitle, detail: modelDetail)
                }
            }
        }
    }

    private var modelTitle: String {
        guard model.settings.useModel else { return "Model off" }
        return model.modelUnavailableReason == nil ? "Model ready" : "Model unavailable"
    }

    private var modelDetail: String {
        guard model.settings.useModel else { return "rules only" }
        return model.modelUnavailableReason ?? "on-device · \(ModelSpec.language.displayName)"
    }
}

/// The big gradient header: one sentence about the state, and the two main actions.
private struct Hero: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting).font(.system(size: 28, weight: .bold, design: .rounded))
                Text(summary).font(.title3).opacity(0.9)
                if let run = model.organizing {
                    HStack(spacing: 10) {
                        ProgressView(value: run.fraction).tint(.white).frame(maxWidth: 260)
                        Text("\(Int(run.fraction * 100))% · \(run.progress?.file ?? "starting…")")
                            .font(.callout.monospacedDigit()).lineLimit(1)
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 10) {
                if model.organizing != nil {
                    Button("Cancel") { model.cancelOrganize() }
                        .buttonStyle(HeroButtonStyle(filled: false))
                } else {
                    Button { model.organizeNow() } label: {
                        Label("Organize Now", systemImage: "wand.and.sparkles")
                    }
                    .buttonStyle(HeroButtonStyle(filled: true))
                    .disabled(model.isApplying)
                }
                Button("Approve all \(model.pending.count)") { model.approveAll() }
                    .buttonStyle(HeroButtonStyle(filled: false))
                    .disabled(model.pending.isEmpty || model.isApplying)
            }
        }
        .foregroundStyle(.white)
        .padding(26)
        .background {
            ZStack {
                Theme.gradient
                // Soft light blobs for depth.
                Circle().fill(.white.opacity(0.12)).frame(width: 260).offset(x: 320, y: -90).blur(radius: 10)
                Circle().fill(.white.opacity(0.08)).frame(width: 180).offset(x: -380, y: 80).blur(radius: 8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .shadow(color: Color(red: 0.4, green: 0.35, blue: 1).opacity(0.3), radius: 18, y: 8)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
    }

    private var summary: String {
        if model.organizing != nil { return "Reading and sorting your downloads…" }
        var parts: [String] = []
        if !model.pending.isEmpty { parts.append("\(model.pending.count) ready to file") }
        if !model.waiting.isEmpty { parts.append("\(model.waiting.count) waiting for Organize Now") }
        if !model.alertActions.isEmpty { parts.append("\(model.alertActions.count) need a look") }
        return parts.isEmpty ? "Your downloads are all sorted." : parts.joined(separator: " · ")
    }
}

private struct HeroButtonStyle: ButtonStyle {
    let filled: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(filled ? Color(red: 0.35, green: 0.3, blue: 0.9) : .white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minWidth: 150)
            .background(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.18)), in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
    }
}

private struct MetricTile: View {
    let value: Int
    let label: String
    let symbol: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Card(padding: 16) {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(color)
                        .frame(width: 34, height: 34)
                        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(value)").font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                        Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One colored bar split by destination, with a legend: where the ready files are going.
struct LaneDistribution: View {
    let actions: [ProposedAction]

    var body: some View {
        let counts = Dictionary(grouping: actions, by: { Lane.of($0.destinationFolder) }).mapValues(\.count)
        let lanes = counts.keys.sorted { (Lane.order.firstIndex(of: $0.name) ?? 99) < (Lane.order.firstIndex(of: $1.name) ?? 99) }
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Where your files are headed",
                             subtitle: actions.isEmpty ? "Nothing ready to file right now." : "\(actions.count) files ready, by destination")
                if !actions.isEmpty {
                    GeometryReader { geo in
                        HStack(spacing: 3) {
                            ForEach(lanes, id: \.self) { lane in
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(lane.color.gradient)
                                    .frame(width: max(8, (geo.size.width - CGFloat(lanes.count - 1) * 3) * CGFloat(counts[lane]!) / CGFloat(actions.count)))
                            }
                        }
                    }
                    .frame(height: 14)

                    FlowLayout(spacing: 8) {
                        ForEach(lanes, id: \.self) { lane in
                            HStack(spacing: 6) {
                                LaneIcon(lane: lane, size: 20)
                                Text(lane.name).font(.callout)
                                Text("\(counts[lane]!)").font(.callout.weight(.semibold)).monospacedDigit()
                            }
                            .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
                            .background(lane.color.opacity(0.08), in: Capsule())
                        }
                    }
                }
            }
        }
    }
}

private struct AttentionCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Needs your attention")
                if model.alertActions.isEmpty {
                    Label("All clear", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    ForEach(model.alertActions.prefix(5)) { action in
                        let alert = action.alerts[0]
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: alert.kind.systemImage)
                                .foregroundStyle(alert.kind.color)
                                .frame(width: 26, height: 26)
                                .background(alert.kind.color.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                Text(action.originalName).fontWeight(.medium).lineLimit(1)
                                Text(alert.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    Button("See all alerts") { model.page = .alerts }.buttonStyle(SoftButtonStyle(tint: .red))
                }
            }
        }
    }
}

private struct ActivityCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Activity")
                if model.activity.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.activity.prefix(8)) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle().fill(event.color == .secondary ? Color.gray : event.color)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.text).font(.callout).lineLimit(2)
                                    Text(event.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct StatusItem: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

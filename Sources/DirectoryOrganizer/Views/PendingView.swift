import AppKit
import OrganizerCore
import SwiftUI

/// Every proposed move, grouped into one card per destination ("lane"). Click a file for
/// all its details; ⌘-click to select several. Approve one, a whole group, or everything.
struct PendingView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var filter: Filter = .all
    @ViewState private var search = ""
    @ViewState private var showRejected = false
    @ViewState private var showInspector = true

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case attention = "Needs a look"
        case model = "By the model"
        case rules = "By rules"
        case review = "To review"
        var id: Self { self }
    }

    var body: some View {
        let groups = grouped
        Page {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { item in
                    FilterChip(title: item.rawValue, isOn: filter == item && !showRejected) {
                        filter = item
                        showRejected = false
                    }
                }
                FilterChip(title: "Rejected \(model.rejected.count)", isOn: showRejected) { showRejected.toggle() }
                Spacer()
                if !showRejected {
                    Button("Approve all \(model.pending.count)") { model.approveAll() }
                        .buttonStyle(GradientButtonStyle())
                        .disabled(model.pending.isEmpty || model.isApplying)
                }
            }

            if !model.waiting.isEmpty && !showRejected {
                WaitingCard()
            }

            if groups.isEmpty {
                emptyState
            } else {
                ForEach(groups, id: \.folder) { group in
                    LaneCard(folder: group.folder, actions: group.actions, isRejected: showRejected)
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search files, folders, reasons")
        .toolbar {
            ToolbarItem {
                Button("Details", systemImage: "sidebar.trailing") { showInspector.toggle() }
                    .help("Show or hide the details panel")
            }
        }
        .inspector(isPresented: $showInspector) {
            inspector.inspectorColumnWidth(min: 320, ideal: 380, max: 520)
        }
    }

    private var source: [ProposedAction] { showRejected ? model.rejected : model.pending }

    /// Filtered actions grouped by destination folder, in lane order, alerts first inside each.
    private var grouped: [(folder: String, actions: [ProposedAction])] {
        let review = OrganizerConfig().reviewFolder
        var rows = source
        if !showRejected {
            switch filter {
            case .all: break
            case .attention: rows = rows.filter { !$0.alerts.isEmpty || $0.confidence < 0.9 }
            case .model: rows = rows.filter { if case .classifier = $0.decidedBy { true } else { $0.reason.contains("by the model") } }
            case .rules: rows = rows.filter { if case .rule = $0.decidedBy { true } else { false } }
            case .review: rows = rows.filter { $0.destinationFolder == review }
            }
        }
        if !search.isEmpty {
            rows = rows.filter {
                [$0.originalName, $0.finalName, $0.destinationFolder, $0.reason].contains { $0.localizedCaseInsensitiveContains(search) }
            }
        }
        return Dictionary(grouping: rows, by: \.destinationFolder)
            .map { folder, actions in
                (folder, actions.sorted { ($0.alerts.isEmpty ? 1 : 0, $0.originalName) < ($1.alerts.isEmpty ? 1 : 0, $1.originalName) })
            }
            .sorted {
                let a = Lane.order.firstIndex(of: Lane.of($0.0).name) ?? 99
                let b = Lane.order.firstIndex(of: Lane.of($1.0).name) ?? 99
                return a != b ? a < b : $0.0 < $1.0
            }
            .map { (folder: $0.0, actions: $0.1) }
    }

    @ViewBuilder private var inspector: some View {
        let selected = source.filter { model.selection.contains($0.id) }
        if selected.count == 1, let action = selected.first {
            ActionDetailView(action: action, isRejected: showRejected)
        } else if selected.count > 1 {
            MultiSelectionView(actions: selected, isRejected: showRejected)
        } else {
            ContentUnavailableView("Select a file", systemImage: "hand.point.up.left",
                                   description: Text("See a preview, where it goes and why, and everything read from it."))
        }
    }

    @ViewBuilder private var emptyState: some View {
        Card {
            Group {
                if model.isScanning {
                    ContentUnavailableView { Label("Scanning…", systemImage: "magnifyingglass") }
                } else if showRejected {
                    ContentUnavailableView("No rejected files", systemImage: "hand.raised",
                                           description: Text("Files you reject stay where they are and show up here."))
                } else if !search.isEmpty || filter != .all {
                    ContentUnavailableView.search
                } else {
                    ContentUnavailableView("All caught up", systemImage: "checkmark.circle",
                                           description: Text("New files in \(model.display(model.watchedURL)) appear here within seconds."))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        }
    }
}

private struct FilterChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOn ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.card), in: Capsule())
                .overlay(Capsule().strokeBorder(.separator.opacity(isOn ? 0 : 0.6)))
        }
        .buttonStyle(.plain)
    }
}

/// Files the quick scan couldn't decide, with the button that decides them.
private struct WaitingCard: View {
    @Environment(AppModel.self) private var model
    @ViewState private var expanded = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.sparkles")
                        .font(.title3).foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.waiting.count) file\(model.waiting.count == 1 ? "" : "s") waiting for Organize Now")
                            .font(.headline)
                        Text("Images and scans need text recognition; the rest need the model.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(expanded ? "Hide" : "Show") { withAnimation(.snappy) { expanded.toggle() } }
                        .buttonStyle(SoftButtonStyle(tint: .purple))
                    OrganizeNowControl(compact: true)
                        .frame(minWidth: model.organizing == nil ? nil : 240)
                }
                if expanded {
                    WaitingList(limit: 30)
                        .padding(.leading, 50)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

/// One destination: header with the lane, path, tags and a group approve, then its files.
private struct LaneCard: View {
    @Environment(AppModel.self) private var model
    let folder: String
    let actions: [ProposedAction]
    let isRejected: Bool

    var body: some View {
        let lane = Lane.of(folder)
        let creates = actions.flatMap(\.createsFolders).contains(folder)
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    LaneIcon(lane: lane, size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            if folder == OrganizerConfig().reviewFolder {
                                Text("Review folder").font(.headline)
                            } else {
                                PathView(path: folder, font: .headline)
                            }
                            if creates { Chip(text: "New folder", symbol: "plus", color: .orange) }
                        }
                        Text("\(actions.count) file\(actions.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let tags = actions.first?.tags, !tags.isEmpty { TagsView(tags: tags) }
                    if !isRejected {
                        Button("Approve \(actions.count)") { model.approve(Set(actions.map(\.id))) }
                            .buttonStyle(SoftButtonStyle(tint: lane.color == .secondary ? .accentColor : lane.color))
                            .disabled(model.isApplying)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(lane.color.opacity(0.06))

                ForEach(actions) { action in
                    Divider().padding(.leading, 16)
                    FileRow(action: action, isRejected: isRejected)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

private struct FileRow: View {
    @Environment(AppModel.self) private var model
    let action: ProposedAction
    let isRejected: Bool
    @ViewState private var hovering = false

    var body: some View {
        let selected = model.selection.contains(action.id)
        HStack(spacing: 12) {
            FileIcon(url: action.source, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.originalName).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                if action.isRenamed {
                    Label(action.finalName, systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(.blue).lineLimit(1).truncationMode(.middle)
                }
                Text(action.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !action.alerts.isEmpty { AlertIcons(alerts: action.alerts) }
            Image(systemName: action.decidedBy.systemImage)
                .foregroundStyle(action.decidedBy.color.opacity(0.8))
                .help(action.decidedBy.label)
            ConfidenceRing(value: action.confidence)
            if isRejected {
                Button("Put back") { model.reconsider([action.id]) }.buttonStyle(SoftButtonStyle())
            } else {
                CircleIconButton(symbol: "checkmark", color: .green, help: "Approve") { model.approve([action.id]) }
                    .disabled(model.isApplying)
                CircleIconButton(symbol: "xmark", color: .red, help: "Reject: leave it where it is") { model.reject([action.id]) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(selected ? Color.accentColor.opacity(0.12) : hovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                if selected { model.selection.remove(action.id) } else { model.selection.insert(action.id) }
            } else {
                model.selection = [action.id]
            }
        }
        .contextMenu {
            if isRejected {
                Button("Put Back in Plan") { model.reconsider([action.id]) }
            } else {
                Button("Approve") { model.approve([action.id]) }
                Button("Reject (leave in place)") { model.reject([action.id]) }
            }
            Divider()
            Button("Open") { NSWorkspace.shared.open(action.source) }
            Button("Show in Finder") { model.reveal(action.source) }
        }
    }
}

/// Several files selected: where they go, and bulk actions.
private struct MultiSelectionView: View {
    @Environment(AppModel.self) private var model
    let actions: [ProposedAction]
    let isRejected: Bool

    var body: some View {
        let ids = Set(actions.map(\.id))
        let byFolder = Dictionary(grouping: actions, by: \.destinationFolder).sorted { $0.key < $1.key }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(actions.count) files selected").font(.title2.weight(.bold))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(byFolder, id: \.key) { folder, items in
                        HStack(spacing: 10) {
                            LaneIcon(lane: Lane.of(folder), size: 22)
                            PathView(path: folder, font: .callout)
                            Spacer()
                            Text("\(items.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                if isRejected {
                    Button("Put back in plan") { model.reconsider(ids) }.buttonStyle(SoftButtonStyle())
                } else {
                    HStack {
                        Button("Approve \(actions.count)") { model.approve(ids) }
                            .buttonStyle(GradientButtonStyle())
                            .disabled(model.isApplying)
                        Button("Reject \(actions.count)") { model.reject(ids) }
                            .buttonStyle(SoftButtonStyle(tint: .red))
                    }
                }
                Button("Clear selection") { model.selection = [] }.buttonStyle(.link)
            }
            .padding(20)
        }
    }
}

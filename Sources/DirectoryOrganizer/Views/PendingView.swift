import OrganizerCore
import SwiftUI

/// Every proposed move in a table. Select rows to see full details, approve or reject them.
struct PendingView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var filter: Filter = .all
    @ViewState private var search = ""
    @ViewState private var showRejected = false
    @ViewState private var showInspector = true

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case attention = "Needs attention"
        case model = "Model"
        case rules = "Rules"
        case review = "To review"
        var id: Self { self }
    }

    var body: some View {
        @Bindable var model = model
        let rows = filtered
        VStack(spacing: 0) {
            Table(rows, selection: $model.selection) {
                TableColumn("") { action in
                    StatusCell(action: action)
                }
                .width(28)
                TableColumn("File") { action in
                    HStack(spacing: 6) {
                        FileIcon(url: action.source)
                        Text(action.originalName).lineLimit(1).truncationMode(.middle)
                    }
                }
                .width(min: 140, ideal: 200)
                TableColumn("Goes to") { action in
                    DestinationCell(action: action)
                }
                .width(min: 140, ideal: 210)
                TableColumn("New name") { action in
                    Text(action.isRenamed ? action.finalName : "–")
                        .foregroundStyle(action.isRenamed ? .primary : .tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .width(min: 90, ideal: 170)
                TableColumn("Tags") { action in
                    TagsView(tags: action.tags)
                }
                .width(min: 70, ideal: 90)
                TableColumn("Confidence") { action in
                    ConfidenceView(value: action.confidence)
                }
                .width(90)
                TableColumn("Decided by") { action in
                    DecidedByView(source: action.decidedBy)
                }
                .width(min: 100, ideal: 130)
            }
            .contextMenu(forSelectionType: ProposedAction.ID.self) { ids in
                if showRejected {
                    Button("Put Back in Plan") { model.reconsider(ids) }
                } else {
                    Button("Approve") { model.approve(ids) }
                    Button("Reject (leave in place)") { model.reject(ids) }
                }
                Divider()
                Button("Show in Finder") {
                    for id in ids { model.reveal(URL(filePath: id)) }
                }
            }
            .overlay {
                if rows.isEmpty { emptyState }
            }

            bottomBar
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search files, folders, reasons")
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .disabled(showRejected)
            }
            ToolbarItem {
                Toggle(isOn: $showRejected) {
                    Label("Rejected (\(model.rejected.count))", systemImage: "hand.raised")
                }
                .help("Files you rejected: they stay where they are")
            }
            ToolbarItem {
                Button("Scan", systemImage: "arrow.clockwise") { model.requestScan() }
                    .disabled(model.isScanning)
            }
            ToolbarItem {
                Button("Details", systemImage: "sidebar.trailing") { showInspector.toggle() }
            }
        }
        .inspector(isPresented: $showInspector) {
            inspector
                .inspectorColumnWidth(min: 320, ideal: 400, max: 560)
        }
    }

    private var source: [ProposedAction] { showRejected ? model.rejected : model.pending }

    private var filtered: [ProposedAction] {
        let review = OrganizerConfig().reviewFolder
        var rows = source
        if !showRejected {
            switch filter {
            case .all: break
            case .attention: rows = rows.filter { !$0.alerts.isEmpty || $0.confidence < 0.9 }
            case .model: rows = rows.filter { if case .classifier = $0.decidedBy { true } else { $0.reason.contains("model") } }
            case .rules: rows = rows.filter { if case .rule = $0.decidedBy { true } else { false } }
            case .review: rows = rows.filter { $0.destinationFolder == review }
            }
        }
        if !search.isEmpty {
            rows = rows.filter {
                [$0.originalName, $0.finalName, $0.destinationFolder, $0.reason].contains { $0.localizedCaseInsensitiveContains(search) }
            }
        }
        // Alerts first, then by destination.
        return rows.sorted {
            ($0.alerts.isEmpty ? 1 : 0, $0.destinationFolder, $0.originalName) < ($1.alerts.isEmpty ? 1 : 0, $1.destinationFolder, $1.originalName)
        }
    }

    @ViewBuilder private var inspector: some View {
        let selected = source.filter { model.selection.contains($0.id) }
        if selected.count == 1, let action = selected.first {
            ActionDetailView(action: action, isRejected: showRejected)
        } else if selected.count > 1 {
            MultiSelectionView(actions: selected, isRejected: showRejected)
        } else {
            ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass",
                                   description: Text("See everything read from it and why it goes where it goes."))
        }
    }

    private var emptyState: some View {
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
                                       description: Text("New files in \(model.display(model.watchedURL)) will appear here."))
            }
        }
    }

    private var bottomBar: some View {
        let selected = model.selection.intersection(Set(source.map(\.id)))
        return HStack(spacing: 10) {
            Text(summary).font(.callout).foregroundStyle(.secondary)
            Spacer()
            if showRejected {
                Button("Put Back in Plan") { model.reconsider(selected) }
                    .disabled(selected.isEmpty)
            } else {
                Button("Reject Selected") { model.reject(selected) }
                    .disabled(selected.isEmpty)
                Button("Approve Selected (\(selected.count))") { model.approve(selected) }
                    .disabled(selected.isEmpty || model.isApplying)
                Button("Approve All (\(model.pending.count))") { model.approveAll() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.pending.isEmpty || model.isApplying)
            }
        }
        .padding(10)
        .background(.bar)
    }

    private var summary: String {
        let shown = filtered.count
        let newFolders = Set(source.flatMap(\.createsFolders)).count
        return "\(shown) of \(source.count) shown · \(newFolders) new folder\(newFolders == 1 ? "" : "s") would be created"
    }
}

private struct StatusCell: View {
    let action: ProposedAction

    var body: some View {
        if !action.alerts.isEmpty {
            AlertIcons(alerts: action.alerts)
        } else if action.destinationFolder == OrganizerConfig().reviewFolder {
            Image(systemName: "archivebox").foregroundStyle(.orange).help("Goes to the review folder")
        } else {
            Image(systemName: "checkmark.circle").foregroundStyle(.green.opacity(0.7))
        }
    }
}

private struct DestinationCell: View {
    let action: ProposedAction

    var body: some View {
        HStack(spacing: 4) {
            if action.destinationFolder == OrganizerConfig().reviewFolder {
                Label("Review folder", systemImage: "archivebox").foregroundStyle(.orange)
            } else {
                Text(action.destinationFolder).lineLimit(1).truncationMode(.middle)
                    .help(action.destinationFolder)
            }
            if !action.createsFolders.isEmpty {
                Text("NEW")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 4)
                    .background(.yellow.opacity(0.3), in: RoundedRectangle(cornerRadius: 3))
                    .help("Creates: " + action.createsFolders.joined(separator: ", "))
            }
        }
    }
}

/// Several rows selected: a summary and bulk actions.
private struct MultiSelectionView: View {
    @Environment(AppModel.self) private var model
    let actions: [ProposedAction]
    let isRejected: Bool

    var body: some View {
        let ids = Set(actions.map(\.id))
        let byFolder = Dictionary(grouping: actions, by: \.destinationFolder).sorted { $0.key < $1.key }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(actions.count) files selected").font(.title3.weight(.semibold))
                DetailSection(title: "Destinations") {
                    ForEach(byFolder, id: \.key) { folder, items in
                        HStack {
                            Image(systemName: "folder")
                            Text(folder).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text("\(items.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                if isRejected {
                    Button("Put Back in Plan") { model.reconsider(ids) }
                } else {
                    HStack {
                        Button("Approve \(actions.count)") { model.approve(ids) }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isApplying)
                        Button("Reject \(actions.count)") { model.reject(ids) }
                    }
                }
            }
            .padding()
        }
    }
}

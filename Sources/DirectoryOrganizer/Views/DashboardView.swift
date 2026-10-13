import AppKit
import OrganizerCore
import SwiftUI

/// The main window: a sidebar of pages, each with the full detail.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.page) {
                Section {
                    row(.overview)
                    row(.pending, count: model.pending.count)
                    row(.alerts, count: model.alertActions.count, tint: .red)
                }
                Section("Files") {
                    row(.history, count: model.movedRecords.count, tint: .secondary)
                    row(.review, count: model.reviewItems.count, tint: .orange)
                    row(.folders)
                }
                Section {
                    row(.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { StatusFooter().padding(10) }
        } detail: {
            VStack(spacing: 0) {
                if let banner = model.banner {
                    BannerView(event: banner) { model.banner = nil }
                }
                page
            }
            .navigationTitle(model.page.title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    OrganizeNowControl(compact: true)
                        .frame(minWidth: model.organizing == nil ? nil : 260)
                }
            }
        }
        .onAppear {
            model.openDashboardAction = { [openWindow] in openWindow(id: "dashboard") }
            // A Dock icon while the dashboard is open; menu bar only once it's closed.
            NSApp.setActivationPolicy(.regular)
        }
        .onDisappear {
            if Notifier.isBundled { NSApp.setActivationPolicy(.accessory) }
        }
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .overview: OverviewView()
        case .pending: PendingView()
        case .alerts: AlertsView()
        case .history: HistoryView()
        case .review: ReviewView()
        case .folders: FoldersView()
        case .settings: SettingsView()
        }
    }

    private func row(_ page: AppModel.Page, count: Int = 0, tint: Color = .accentColor) -> some View {
        Label(page.title, systemImage: page.systemImage)
            .badge(count > 0 ? Text("\(count)").foregroundStyle(tint) : nil)
            .tag(page)
    }
}

/// Watching / scanning / model status, at the bottom of the sidebar.
struct StatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let run = model.organizing {
                    ProgressView().controlSize(.small)
                    Text("Organizing… \(Int(run.fraction * 100))%")
                } else if model.isScanning || model.isApplying {
                    ProgressView().controlSize(.small)
                    Text(model.isApplying ? "Moving files…" : "Scanning…")
                } else {
                    Circle().fill(model.isWatching ? .green : .orange).frame(width: 8, height: 8)
                    Text(model.isWatching ? "Watching" : "Paused")
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(model.modelUnavailableReason == nil && model.settings.useModel ? .purple : .secondary)
                Text(model.settings.useModel ? (model.modelUnavailableReason == nil ? "Apple model ready" : "Model unavailable") : "Model off")
            }
            if let last = model.lastScan {
                Text("Last scan \(last.relative)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BannerView: View {
    let event: ActivityEvent
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: event.systemImage).foregroundStyle(event.color)
            Text(event.text).textSelection(.enabled)
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(event.color.opacity(0.12))
    }
}

// MARK: - Menu bar

/// The icon in the menu bar: a tray, with the number of files waiting.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.pending.count
        HStack(spacing: 3) {
            if let run = model.organizing {
                Image(systemName: "wand.and.sparkles")
                Text("\(Int(run.fraction * 100))%")
            } else {
                Image(systemName: model.alertActions.isEmpty ? (count > 0 ? "tray.full" : "tray") : "tray.full.fill")
                if count > 0 { Text("\(count)") }
            }
        }
    }
}

/// The compact view under the menu-bar icon.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Directory Organizer").font(.headline)
                Spacer()
                StatusPill()
            }

            OrganizeNowControl()
            if let last = model.lastFullRun, model.organizing == nil {
                Text("Last run \(last.date.relative): \(last.text)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }

            HStack(spacing: 8) {
                MiniStat(value: model.pending.count, label: "Pending", tint: .accentColor) { show(.pending) }
                MiniStat(value: model.waiting.count, label: "Waiting", tint: .purple) { show(.pending) }
                MiniStat(value: model.alertActions.count, label: "Alerts", tint: .red) { show(.alerts) }
                MiniStat(value: model.reviewItems.count, label: "In review", tint: .orange) { show(.review) }
            }

            if !model.alertActions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.alertActions.prefix(3)) { action in
                        HStack(spacing: 6) {
                            AlertIcons(alerts: action.alerts)
                            Text(action.originalName).lineLimit(1).truncationMode(.middle)
                        }
                        .font(.callout)
                    }
                }
            }

            if model.pending.isEmpty {
                Text(model.isScanning ? "Scanning \(model.display(model.watchedURL))…"
                     : model.waiting.isEmpty ? "Nothing waiting. New downloads appear here."
                     : "Nothing ready yet: press Organize Now for the files that need a full read.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.pending.prefix(6)) { action in
                        MenuBarRow(action: action)
                        Divider()
                    }
                }
                if model.pending.count > 6 {
                    Text("and \(model.pending.count - 6) more…").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Approve All (\(model.pending.count))") { model.approveAll() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.pending.isEmpty || model.isApplying)
                Button("Scan", systemImage: "arrow.clockwise") { model.requestScan() }
                    .disabled(model.isScanning)
                Spacer()
                Button(model.isWatching ? "Pause" : "Resume", systemImage: model.isWatching ? "pause" : "play") {
                    model.setWatching(!model.isWatching)
                }
                .labelStyle(.iconOnly)
                .help(model.isWatching ? "Pause watching" : "Resume watching")
            }

            Divider()
            HStack {
                Button("Open Dashboard") { show(model.page) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 400)
        .onAppear { model.openDashboardAction = { [openWindow] in openWindow(id: "dashboard") } }
    }

    private func show(_ page: AppModel.Page) {
        model.page = page
        openWindow(id: "dashboard")
        NSApp.activate()
    }
}

struct StatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            if model.isScanning || model.isApplying {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(model.isWatching ? .green : .orange).frame(width: 7, height: 7)
            }
            Text(model.isApplying ? "Moving" : model.isScanning ? "Scanning" : model.isWatching ? "Watching" : "Paused")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }
}

private struct MiniStat: View {
    let value: Int
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text("\(value)").font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(value > 0 ? tint : .secondary)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct MenuBarRow: View {
    @Environment(AppModel.self) private var model
    let action: ProposedAction

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(url: action.source, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.originalName).lineLimit(1).truncationMode(.middle)
                Text("→ \(action.destinationFolder)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            if !action.alerts.isEmpty { AlertIcons(alerts: action.alerts) }
            Button("Approve", systemImage: "checkmark") { model.approve([action.id]) }
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.green)
                .disabled(model.isApplying)
            Button("Reject", systemImage: "xmark") { model.reject([action.id]) }
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.red)
        }
        .font(.callout)
        .padding(.vertical, 5)
    }
}

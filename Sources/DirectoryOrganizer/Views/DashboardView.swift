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
            .safeAreaInset(edge: .top) {
                HStack(spacing: 10) {
                    AppMark(size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Directory").font(.headline)
                        Text("Organizer").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AppMark(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Directory Organizer").font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                StatusPill()
            }

            OrganizeNowControl()

            HStack(spacing: 8) {
                MiniStat(value: model.pending.count, label: "Ready", symbol: "tray.full.fill", tint: .blue) { show(.pending) }
                MiniStat(value: model.waiting.count, label: "Waiting", symbol: "wand.and.sparkles", tint: .purple) { show(.pending) }
                MiniStat(value: model.alertActions.count, label: "Alerts", symbol: "exclamationmark.triangle.fill", tint: .red) { show(.alerts) }
                MiniStat(value: model.reviewItems.count, label: "Review", symbol: "archivebox.fill", tint: .orange) { show(.review) }
            }

            if model.pending.isEmpty {
                Text(model.isScanning ? "Scanning \(model.display(model.watchedURL))…"
                     : model.waiting.isEmpty ? "All sorted. New downloads appear here."
                     : "Nothing ready yet: Organize Now reads the waiting files.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Ready to file").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Approve all \(model.pending.count)") { model.approveAll() }
                            .buttonStyle(SoftButtonStyle())
                            .disabled(model.isApplying)
                    }
                    VStack(spacing: 2) {
                        ForEach(model.pending.sorted { !$0.alerts.isEmpty && $1.alerts.isEmpty }.prefix(5)) { action in
                            MenuBarRow(action: action)
                        }
                    }
                    if model.pending.count > 5 {
                        Button("and \(model.pending.count - 5) more in the dashboard") { show(.pending) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }

            HStack {
                Button { show(model.page) } label: { Label("Dashboard", systemImage: "macwindow") }
                    .buttonStyle(SoftButtonStyle(tint: .primary))
                Spacer()
                Menu {
                    Button("Quick Scan") { model.requestScan() }
                    Button(model.isWatching ? "Pause Watching" : "Resume Watching") { model.setWatching(!model.isWatching) }
                    Divider()
                    Button("Settings…") { show(.settings) }
                    Button("Quit Directory Organizer") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { model.openDashboardAction = { [openWindow] in openWindow(id: "dashboard") } }
    }

    private var subtitle: String {
        if let last = model.lastFullRun, model.organizing == nil {
            return "Last Organize Now \(last.date.relative)"
        }
        return model.lastScan.map { "Checked \($0.relative)" } ?? "Starting…"
    }

    private func show(_ page: AppModel.Page) {
        model.page = page
        openWindow(id: "dashboard")
        NSApp.activate()
    }
}

/// The app's mark: the icon's tray-and-sparkle on the gradient.
struct AppMark: View {
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: "tray.and.arrow.down.fill")
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
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
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.caption).foregroundStyle(value > 0 ? tint : .secondary)
                Text("\(value)").font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(value > 0 ? .primary : .secondary)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(value > 0 ? tint.opacity(0.09) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct MenuBarRow: View {
    @Environment(AppModel.self) private var model
    let action: ProposedAction

    var body: some View {
        let lane = Lane.of(action.destinationFolder)
        HStack(spacing: 10) {
            LaneIcon(lane: lane, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.isRenamed ? action.finalName : action.originalName)
                    .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(action.destinationFolder.split(separator: "/").last.map(String.init) ?? action.destinationFolder)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !action.alerts.isEmpty { AlertIcons(alerts: action.alerts) }
            CircleIconButton(symbol: "checkmark", color: .green, help: "Approve") { model.approve([action.id]) }
                .disabled(model.isApplying)
            CircleIconButton(symbol: "xmark", color: .red, help: "Reject") { model.reject([action.id]) }
        }
        .padding(.vertical, 4)
    }
}

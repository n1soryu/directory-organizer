import AppKit
import OrganizerCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Real-folder access is only checked when you ask: checking is what makes macOS ask you.
    @ViewState private var access: [String: FolderAccess.Status] = [:]
    @ViewState private var confirmReal = false
    @ViewState private var confirmSandbox = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                if let since = model.settings.realUseSince {
                    LabeledContent("Mode") {
                        Label("Your real folders", systemImage: "house").foregroundStyle(.green)
                    }
                    Text("Only files downloaded since \(since.formatted(date: .abbreviated, time: .shortened)) are organized; what was already in Downloads stays put. Nothing moves until you approve it, and every move can be undone in History.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Switch Back to the Sandbox…") { confirmSandbox = true }
                } else {
                    LabeledContent("Mode") {
                        Label("Sandbox (TestData)", systemImage: "testtube.2").foregroundStyle(.orange)
                    }
                    Text("The app works inside the test folders. Your real Downloads, Documents, Desktop, Pictures, Movies and Music are locked until you switch to them.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Switch to My Real Folders…") { confirmReal = true }
                        .buttonStyle(.borderedProminent)
                }
                folderRow("Watched folder", path: model.settings.watchedFolder) { model.setFolders(watched: $0) }
                folderRow("Home folder", path: model.settings.homeRoot) { model.setFolders(home: $0) }
                LabeledContent("Move log") {
                    Button(model.display(model.journal.url.path)) { model.reveal(model.journal.url) }.buttonStyle(.link)
                }
                LabeledContent("Settings file") {
                    Button(model.display(AppModel.settingsURL.path)) { model.reveal(AppModel.settingsURL) }.buttonStyle(.link)
                }
                if !model.isRealUseOn {
                    Button("Reset to the Sandbox Folders") {
                        let defaults = AppSettings()
                        model.setFolders(watched: URL(filePath: defaults.watchedFolder), home: URL(filePath: defaults.homeRoot))
                    }
                }
            } header: {
                Text("Folders")
            }
            .confirmationDialog("Switch to your real folders?", isPresented: $confirmReal) {
                Button("Switch to My Real Folders") { model.switchToRealFolders() }
            } message: {
                Text("The app will watch ~/Downloads and file into Documents, Pictures, Movies, Music, Developer and \"Desktop/To Delete (Review)\" in your home folder.\n\nOnly files downloaded from now on are touched. Nothing moves until you approve it, auto-filing is turned off, and every move can be undone. macOS will ask for permission to read your Downloads.")
            }
            .confirmationDialog("Switch back to the sandbox?", isPresented: $confirmSandbox) {
                Button("Switch to the Sandbox") { model.switchToSandbox() }
            } message: {
                Text("Files already moved stay where they are. To put them back, undo them in History first.")
            }

            Section("Watching") {
                Toggle("Watch for new downloads", isOn: Binding(get: { model.settings.watching }, set: { model.setWatching($0) }))
                Text("Uses FSEvents, the macOS file-change feed. A burst of changes (a download being written) causes one scan, a few seconds after it settles.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use the model for files no rule can place", isOn: $model.settings.useModel)
                LabeledContent("Status") {
                    if let reason = model.modelUnavailableReason {
                        Label(reason, systemImage: "xmark.circle").foregroundStyle(.orange).lineLimit(2)
                    } else {
                        Label("Ready", systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                }
                ForEach(ModelSpec.all) { spec in
                    LabeledContent {
                        modelStatusLabel(model.localModels.status[spec.id] ?? .notDownloaded)
                    } label: {
                        Text(spec.displayName)
                        Text(spec.downloadBytes.fileSize).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if model.localModels.isDownloading {
                        Button("Cancel Download") { model.cancelModelDownload() }
                    } else if !model.localModels.allReady {
                        Button("Download Models (\(model.localModels.missingBytes.fileSize))") { model.downloadModels() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Show in Finder", systemImage: "folder") { model.reveal(model.localModels.store.directory) }
                        .disabled(!FileManager.default.fileExists(atPath: model.localModels.store.directory.path))
                }
                LabeledContent("Catalog") {
                    HStack {
                        Text("\(model.catalogCounts.filed) filed · \(model.catalogCounts.waiting) waiting")
                        Button("Show in Finder", systemImage: "folder") { model.reveal(model.catalogStore.url) }
                            .labelStyle(.iconOnly)
                            .disabled(!FileManager.default.fileExists(atPath: model.catalogStore.url.path))
                    }
                }
                if let free = model.localModels.freeBytes, !model.localModels.allReady {
                    Text("\(free.fileSize) free on this Mac; the download needs \(model.localModels.missingBytes.fileSize) plus 1 GB to spare.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("On-device models (MLX)")
            } footer: {
                Text("Downloaded once from Hugging Face, then everything runs on this Mac; no file ever leaves it. If a download is interrupted, the files that already finished are kept. The model only suggests: every answer is checked, anything unsure goes to review, and without the models files no rule can place go to review. Organize Now loads one model at a time (at most about 6 GB of memory): the vision model for images first, then Qwen3 for the rest, and releases them when it's done. Without the vision model, images go to Downloaded Images as before. The catalog keeps a short description and an embedding of each file the models looked at (never sensitive files), so similar files are found by meaning and nothing is described twice.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(AutoApplyPolicy.categories) { category in
                    Toggle(isOn: Binding(
                        get: { model.settings.autoApply.enabled.contains(category.id) },
                        set: { on in
                            if on { model.settings.autoApply.enabled.insert(category.id) }
                            else { model.settings.autoApply.enabled.remove(category.id) }
                        }
                    )) {
                        VStack(alignment: .leading) {
                            Text(category.title)
                            Text(category.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Auto-apply (without asking)")
            } footer: {
                Text("Off by default. Only rule decisions with 90%+ confidence and no alerts are applied automatically. Model decisions, sensitive files and duplicates always wait for you. Everything can be undone in History.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notifications") {
                LabeledContent("Permission", value: model.notificationStatus.description)
                if model.notificationStatus == .notDetermined || model.notificationStatus == .denied {
                    HStack {
                        Button("Ask for Permission") { model.requestNotificationPermission() }
                        Button("Open Notification Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                }
                Toggle("Notify me about new files", isOn: $model.settings.notifyNewFiles)
                Picker("Review folder reminder", selection: $model.settings.reviewReminderHours) {
                    Text("Every 4 hours").tag(4.0)
                    Text("Every 8 hours").tag(8.0)
                    Text("Every 12 hours").tag(12.0)
                    Text("Every 24 hours").tag(24.0)
                }
                LabeledContent("Next reminder", value: model.reviewItems.isEmpty ? "when something lands in review" : model.nextReminder.short)
                Text("Sensitive files are always reported right away, whatever these settings say.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(["Downloads", "Documents", "Desktop", "Pictures", "Movies", "Music"], id: \.self) { name in
                    LabeledContent(name) { accessLabel(access[name]) }
                }
                HStack {
                    Button("Check Access") { checkAccess() }
                    Button("Open Privacy & Security") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!)
                    }
                }
            } header: {
                Text("Access to your real folders")
            } footer: {
                Text("With real folders on, the app needs to read Downloads and write to your other folders. macOS asks once per protected folder (Downloads, Documents, Desktop) the first time it's read; \"Check Access\" triggers those questions now. Alternatively, grant Full Disk Access in Privacy & Security. You can withdraw either there at any time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // The CLI may have downloaded them meanwhile.
            model.localModels.refresh()
            model.refreshModelStatus()
        }
        .scrollContentBackground(.hidden)
        .background(Theme.page)
    }

    private func folderRow(_ label: String, path: String, set: @escaping (URL) -> Void) -> some View {
        LabeledContent(label) {
            HStack {
                Text(model.display(path)).lineLimit(1).truncationMode(.head)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = URL(filePath: path)
                    if panel.runModal() == .OK, let url = panel.url { set(url) }
                }
                Button("Show", systemImage: "folder") { NSWorkspace.shared.open(URL(filePath: path)) }
                    .labelStyle(.iconOnly)
            }
        }
    }

    @ViewBuilder private func modelStatusLabel(_ status: LocalModels.Status) -> some View {
        switch status {
        case .notDownloaded: Text("not downloaded").foregroundStyle(.secondary)
        case .downloading(let fraction):
            HStack {
                ProgressView(value: fraction).frame(width: 120)
                Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
            }
        case .ready: Label("Ready", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "xmark.circle").foregroundStyle(.red).lineLimit(2)
        }
    }

    @ViewBuilder private func accessLabel(_ status: FolderAccess.Status?) -> some View {
        switch status {
        case nil: Text("not checked").foregroundStyle(.secondary)
        case .granted: Label("Allowed", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .denied: Label("Not allowed", systemImage: "xmark.circle").foregroundStyle(.red)
        case .missing: Text("doesn't exist").foregroundStyle(.secondary)
        }
    }

    private func checkAccess() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in ["Downloads", "Documents", "Desktop", "Pictures", "Movies", "Music"] {
            access[name] = FolderAccess.status(of: home.appending(path: name))
        }
    }
}

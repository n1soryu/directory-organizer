import AppKit
import OrganizerCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Real-folder access is only checked when you ask: checking is what makes macOS ask you.
    @ViewState private var access: [String: FolderAccess.Status] = [:]

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("Mode") {
                    Label("Sandbox (TestData)", systemImage: "testtube.2").foregroundStyle(.orange)
                }
                Text("The app only works inside the test folders for now. Your real Downloads, Documents, Desktop, Pictures, Movies and Music are locked, and the app refuses them even if chosen below.")
                    .font(.caption).foregroundStyle(.secondary)
                folderRow("Watched folder", path: model.settings.watchedFolder) { model.setFolders(watched: $0) }
                folderRow("Home folder", path: model.settings.homeRoot) { model.setFolders(home: $0) }
                LabeledContent("Move log") {
                    Button(model.display(model.journal.url.path)) { model.reveal(model.journal.url) }.buttonStyle(.link)
                }
                LabeledContent("Settings file") {
                    Button(model.display(AppSettings.defaultURL.path)) { model.reveal(AppSettings.defaultURL) }.buttonStyle(.link)
                }
                Button("Reset to the Sandbox Folders") {
                    let defaults = AppSettings()
                    model.setFolders(watched: URL(filePath: defaults.watchedFolder), home: URL(filePath: defaults.homeRoot))
                }
            } header: {
                Text("Folders")
            }

            Section("Watching") {
                Toggle("Watch for new downloads", isOn: Binding(get: { model.settings.watching }, set: { model.setWatching($0) }))
                Text("Uses FSEvents, the macOS file-change feed. A burst of changes (a download being written) causes one scan, a few seconds after it settles.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Apple's on-device model") {
                Toggle("Use the model for files no rule can place", isOn: $model.settings.useModel)
                LabeledContent("Status") {
                    if let reason = model.modelUnavailableReason {
                        Label(reason, systemImage: "xmark.circle").foregroundStyle(.orange)
                    } else {
                        Label("Available\(model.modelSeesImages ? ", can look at images" : "")", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                }
                HStack {
                    Button("Check Again") { model.refreshModelStatus() }
                    Button("Open Apple Intelligence Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                    }
                }
                Text("Runs entirely on this Mac. It only suggests; every answer is checked, and anything unsure goes to review. Turn it off to use rules only.")
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
                Text("Access to your real folders (for later)")
            } footer: {
                Text("Not used yet. When real use is switched on, the app needs to read Downloads and write to your other folders. macOS asks once per protected folder (Downloads, Documents, Desktop) the first time it's read; \"Check Access\" triggers those questions now. Alternatively, grant Full Disk Access in Privacy & Security. You can withdraw either there at any time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

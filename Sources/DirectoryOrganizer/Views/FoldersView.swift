import OrganizerCore
import SwiftUI

/// The folders the app knows: your core folders (with what they're for and their tags),
/// existing folders it may choose, and folders it has created.
struct FoldersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let created = createdFolders
        VStack(alignment: .leading, spacing: 0) {
            Text("These are the only folders files can go to. The model chooses from this list or proposes a new category folder, which you approve. Tags come from the folder.")
                .font(.callout).foregroundStyle(.secondary)
                .padding()
            Table(model.folderOptions.map(FolderRow.init)) {
                TableColumn("Folder") { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.exists ? "folder.fill" : "folder.badge.plus")
                            .foregroundStyle(row.exists ? Color.accentColor : .orange)
                        Text(row.option.path)
                        if created.contains(row.option.path) {
                            Text("created by app").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .width(min: 220, ideal: 320)
                TableColumn("Used for") { row in
                    Text(row.option.purpose ?? "existing folder").foregroundStyle(row.option.purpose == nil ? .tertiary : .primary)
                }
                .width(min: 180, ideal: 340)
                TableColumn("Tags") { row in TagsView(tags: row.option.tags) }
                    .width(min: 60, ideal: 90)
                TableColumn("Items") { row in
                    Text(row.exists ? "\(row.count)" : "not yet").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(60)
                TableColumn("") { row in
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.open(model.homeURL.appending(path: row.option.path))
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(!row.exists)
                }
                .width(30)
            }
        }
    }

    /// Folders created by moves that are still in place.
    private var createdFolders: Set<String> {
        let home = model.homeURL.path + "/"
        return Set(model.records.filter { $0.state == .moved }.flatMap(\.createdFolders)
            .map { $0.hasPrefix(home) ? String($0.dropFirst(home.count)) : $0 })
    }
}

private struct FolderRow: Identifiable {
    let option: FolderOption
    let exists: Bool
    let count: Int
    var id: String { option.path }

    @MainActor init(_ option: FolderOption) {
        self.option = option
        let url = AppModel.shared.homeURL.appending(path: option.path)
        let items = try? FileManager.default.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }
        exists = items != nil
        count = items?.count ?? 0
    }
}

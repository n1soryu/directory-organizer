import OrganizerCore
import SwiftUI

/// The folders files can go to, as cards: what each is for, its tags, how full it is,
/// and which ones the app created.
struct FoldersView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 14)]

    var body: some View {
        let created = createdFolders
        Page {
            SectionTitle(title: "Folders",
                         subtitle: "The only places files can go. The model picks from these or proposes a new category folder, which you approve. Tags come from the folder.")
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(model.folderOptions.map(FolderRow.init)) { row in
                    let lane = Lane.of(row.option.path)
                    Card(padding: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                LaneIcon(lane: lane, size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.option.path.split(separator: "/").last.map(String.init) ?? row.option.path)
                                        .font(.headline).lineLimit(1)
                                    Text(row.option.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                }
                                Spacer()
                                Button { NSWorkspace.shared.open(model.homeURL.appending(path: row.option.path)) } label: {
                                    Image(systemName: "arrow.up.forward")
                                }
                                .buttonStyle(SoftButtonStyle(tint: .secondary))
                                .disabled(!row.exists)
                                .help("Show in Finder")
                            }
                            Text(row.option.purpose ?? "Existing folder")
                                .font(.callout).foregroundStyle(row.option.purpose == nil ? .tertiary : .secondary)
                                .lineLimit(2, reservesSpace: true)
                            HStack(spacing: 6) {
                                Chip(text: row.exists ? "\(row.count) item\(row.count == 1 ? "" : "s")" : "not created yet",
                                     color: row.exists ? lane.color : .orange)
                                if created.contains(row.option.path) { Chip(text: "made by the app", symbol: "sparkles", color: .purple) }
                                Spacer()
                                TagsView(tags: row.option.tags)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Folders created by moves that are still in place.
    private var createdFolders: Set<String> {
        Set(model.records.filter { $0.state == .moved }.flatMap(\.createdFolders).map(model.homeRelative))
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

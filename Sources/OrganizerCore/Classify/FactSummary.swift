import Foundation

/// A compact plain-text description of a file for the model. The model never opens the file
/// itself; it sees this summary (and, for images, the picture).
public enum FactSummary {
    public static func describe(_ facts: FileFacts, textLimit: Int) -> String {
        var lines = ["File name: \(facts.name)"]
        lines.append("Type: \(facts.kind.rawValue)\(facts.fileExtension.isEmpty ? "" : " (.\(facts.fileExtension))"), \(size(facts.size))")
        if facts.nameIsUnclear { lines.append("The file name is unclear and says little about the content.") }
        lines.append("Downloaded: \(FileNames.day(facts.downloadDate))")
        if let source = facts.whereFroms.first {
            lines.append("Downloaded from: \(source.prefix(160))")
        }
        if let title = facts.documentTitle { lines.append("Document title: \(title.prefix(120))") }
        if let pages = facts.pageCount { lines.append("Pages: \(pages)") }
        if let duration = facts.media?.duration { lines.append("Length: \(Int(duration / 60)) min") }
        if let image = facts.image {
            if let w = image.width, let h = image.height { lines.append("Image size: \(w)×\(h)") }
            if let taken = image.dateTaken { lines.append("Photo taken: \(FileNames.day(taken))") }
            if let camera = image.cameraModel { lines.append("Camera: \(camera)") }
        }
        if facts.isScreenshot { lines.append("This is a screenshot.") }
        if let contents = facts.folder {
            lines.append("Folder with \(contents.fileCount) file\(contents.fileCount == 1 ? "" : "s") in \(contents.folderCount) subfolder\(contents.folderCount == 1 ? "" : "s")\(contents.truncated ? " (or more)" : "")")
            let kinds = contents.kinds.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }
            if !kinds.isEmpty { lines.append("File types: \(kinds.joined(separator: ", "))") }
            if !contents.sample.isEmpty { lines.append("Inside: \(contents.sample.prefix(25).joined(separator: ", "))") }
        } else if let entries = facts.archiveEntries, !entries.isEmpty {
            lines.append("Contains: \(entries.prefix(15).joined(separator: ", "))")
        }
        if let text = facts.text, !text.isEmpty, textLimit > 0 {
            let label = switch facts.textSource {
            case .imageOCR: "Text read from the image"
            case .pdfOCR: "Text read from the scanned pages"
            default: "Beginning of the text"
            }
            let excerpt = String(text.prefix(textLimit))
            lines.append("\(label):\n\"\"\"\n\(excerpt)\(text.count > textLimit ? "\n[…]" : "")\n\"\"\"")
        }
        return lines.joined(separator: "\n")
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

import Foundation

/// Gathers `FileFacts` for one file. No model involved: just metadata, PDFKit,
/// the Office XML, and Vision OCR for images and scanned PDFs.
public struct FactExtractor: Sendable {
    /// Characters of text to keep for a normal file.
    public var textLimit = 4_000
    /// Files with unclear names are read more deeply, since the content is all we have.
    public var deepTextLimit = 8_000
    /// Plain-text files bigger than this aren't read (logs, data dumps).
    public var maxPlainTextBytes = 512 * 1024
    /// Text recognition (OCR) for images and scanned PDFs. The slow part; off for quick scans.
    public var recognizeText = true

    public init() {}

    public func facts(for url: URL) async -> FileFacts {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .creationDateKey,
            .contentModificationDateKey, .addedToDirectoryDateKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let isDirectory = values?.isDirectory ?? false
        // A plain folder has no extension: "Dune.Part.Two.2024.1080p.WEB-DL" is all name.
        // Bundles (.app, .rtfd) do, and are recognized by it.
        let isPlainFolder = isDirectory && values?.isPackage != true
        let ext = isPlainFolder ? "" : url.pathExtension.lowercased()
        let baseName = isPlainFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent

        var facts = FileFacts(
            url: url,
            name: url.lastPathComponent,
            baseName: baseName,
            fileExtension: ext,
            kind: FileKind(fileExtension: ext, isDirectory: isDirectory),
            isDirectory: isDirectory,
            size: Int64(values?.fileSize ?? 0),
            created: values?.creationDate,
            modified: values?.contentModificationDate,
            dateAdded: values?.addedToDirectoryDate,
            whereFroms: WhereFroms.read(url),
            isScreenshot: ScreenCapture.isMarked(url),
            nameIsUnclear: NameQuality.isUnclear(baseName),
            notes: []
        )
        let limit = facts.nameIsUnclear ? deepTextLimit : textLimit

        switch facts.kind {
        case .pdf:
            await readPDF(into: &facts, limit: limit)
        case .wordDocument, .spreadsheet, .presentation:
            if ["docx", "xlsx", "pptx"].contains(ext) {
                do {
                    let office = try OfficeText.read(url, limit: limit)
                    facts.setText(office.text, source: .office)
                    facts.documentTitle = office.title
                } catch {
                    facts.notes.append("Couldn't read Office text: \(error)")
                }
            }
        case .image:
            if let meta = ImageMetadata.load(url) {
                facts.image = meta.info
                facts.isScreenshot = facts.isScreenshot || meta.looksLikeScreenshot
            }
            // OCR every image: it's how a photographed recovery phrase gets caught.
            if recognizeText {
                if let text = await TextRecognizer.text(at: url) {
                    facts.setText(text, source: .imageOCR, limit: limit)
                } else {
                    // Unread is not the same as "nothing sensitive": it stays unchecked.
                    facts.needsDeepRead = true
                    facts.notes.append("Text recognition failed")
                }
            } else {
                facts.needsDeepRead = true
            }
        case .video, .audio:
            facts.media = await MediaMetadata.load(url)
        case .archive:
            if ext == "zip" {
                facts.archiveEntries = (try? ZipArchive(url: url))?.entries.prefix(500).map(\.path)
            }
        case .folder:
            facts.archiveEntries = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.sorted()
            await readFolder(into: &facts)
        default:
            break
        }

        // Read plain text (CSV, notes, keys, files without an extension) for the safety checks.
        if facts.text == nil, !isDirectory, facts.kind.isPlainText || facts.kind == .presentation,
           facts.size <= maxPlainTextBytes, let text = Self.readPlainText(url, limit: limit) {
            facts.setText(text, source: .content)
        }
        return facts
    }

    /// Files inside a folder that get the full safety check. A folder with more is kept
    /// together and never unpacked (see `Planner`), and its contents count as unchecked.
    public static let maxFolderFilesChecked = 300

    /// A folder: what's inside, and the same safety checks as a file in Downloads gets, for
    /// every file inside. Size and modification date become the whole tree's, so a folder
    /// that changes anywhere inside counts as changed.
    private func readFolder(into facts: inout FileFacts) async {
        var (contents, files) = FolderScan.scan(facts.url)
        let base = facts.url.standardizedFileURL.path + "/"
        // Shallowest first, then by name: the same files are checked every time.
        files.sort {
            let (a, b) = ($0.pathComponents.count, $1.pathComponents.count)
            return a != b ? a < b : $0.path < $1.path
        }
        for file in files.prefix(Self.maxFolderFilesChecked) {
            let inner = await self.facts(for: file)
            let relative = String(file.standardizedFileURL.path.dropFirst(base.count))
            if let finding = SensitiveDetector.check(inner) {
                contents.sensitive.append("\(relative): \(finding.detail)")
            }
            if inner.needsDeepRead { contents.needsDeepRead = true }
        }
        if files.count > Self.maxFolderFilesChecked {
            contents.truncated = true
            facts.notes.append("Only the first \(Self.maxFolderFilesChecked) of \(files.count) files inside were checked")
        }
        facts.size = contents.totalSize
        facts.modified = contents.newestChange ?? facts.modified
        facts.needsDeepRead = contents.needsDeepRead
        facts.folder = contents
    }

    private func readPDF(into facts: inout FileFacts, limit: Int) async {
        let maxPages = facts.nameIsUnclear ? 3 : 2
        guard let pdf = PDFText.read(facts.url, maxPages: maxPages, limit: limit) else {
            facts.notes.append("Couldn't open PDF")
            return
        }
        facts.pageCount = pdf.pageCount
        facts.documentTitle = pdf.title
        facts.setText(pdf.text, source: .pdfText)

        // A scan has no text layer: render the first pages and OCR them.
        if (facts.text?.filter { !$0.isWhitespace }.count ?? 0) < 40 {
            guard recognizeText else {
                facts.needsDeepRead = true
                return
            }
            var ocr = ""
            for page in PDFText.renderPages(facts.url, maxPages: maxPages) {
                guard let text = await TextRecognizer.text(in: page) else {
                    facts.needsDeepRead = true
                    facts.notes.append("Text recognition failed")
                    return
                }
                ocr += text + "\n"
            }
            facts.setText(ocr, source: .pdfOCR, limit: limit)
        }
    }

    /// The start of a file, if it's UTF-8 text (binary files return nil).
    static func readPlainText(_ url: URL, limit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit * 4), !data.isEmpty,
              !data.contains(0) else { return nil }
        // Cutting at a byte limit can split a multi-byte character; drop the partial tail.
        for trim in 0...3 where data.count > trim {
            if let text = String(data: data.dropLast(trim), encoding: .utf8) {
                return String(text.prefix(limit))
            }
        }
        return nil
    }
}

extension FileFacts {
    mutating func setText(_ value: String, source: TextSource, limit: Int = .max) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = String(trimmed.prefix(limit))
        textSource = source
    }
}

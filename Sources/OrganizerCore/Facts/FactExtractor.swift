import Foundation

/// Gathers `FileFacts` for one file. No model involved: just metadata, PDFKit,
/// the Office XML, and Vision OCR for images and scanned PDFs.
public struct FactExtractor: Sendable {
    /// Characters of text to keep for a normal file.
    public var textLimit = 4_000
    /// Files with unclear names are read more deeply, since the content is all we have.
    public var deepTextLimit = 8_000
    /// How much of a text file is checked for secrets, whatever its size: a password export or a
    /// key past the excerpt kept for the model is still found.
    public var safetyScanBytes = 256 * 1024
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
            kind: FileKind(fileExtension: ext, isDirectory: isDirectory, isPackage: values?.isPackage ?? false),
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
            if ["rtf", "doc", "odt"].contains(ext) {
                if let text = OfficeText.readOther(url) {
                    facts.setText(String(text.prefix(limit)), source: .office)
                } else {
                    facts.needsDeepRead = true
                    facts.notes.append("Couldn't read the document's text")
                }
            } else if !["docx", "xlsx", "pptx"].contains(ext) {
                // .pages, .numbers, .key, .xls, .ppt, .ods, .odp: no reader for these (yet). Not
                // marked unreadable, or every one would wait in review forever.
                facts.notes.append("Text of .\(ext) files isn't read")
            }
            if ["docx", "xlsx", "pptx"].contains(ext) {
                do {
                    let office = try OfficeText.read(url, limit: limit)
                    facts.setText(office.text, source: .office)
                    facts.documentTitle = office.title
                } catch {
                    // Unread is not clean: it can't be checked for sensitive text.
                    facts.needsDeepRead = true
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
        let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        if facts.text == nil, !isDirectory, !isLink, facts.kind.isPlainText || facts.kind == .presentation {
            if let text = Self.readPlainText(url, maxBytes: safetyScanBytes) {
                // All of what was read is checked; the model only gets the start.
                var whole = facts
                whole.text = text
                facts.sensitive = SensitiveDetector.check(whole)
                facts.setText(String(text.prefix(limit)), source: .content)
            } else if [.csv, .text, .code].contains(facts.kind), facts.size > 0 {
                // Meant to be text but isn't readable as text: can't be checked.
                facts.needsDeepRead = true
                facts.notes.append("Couldn't read it as text")
            }
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
            let path = file.standardizedFileURL.path
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : file.lastPathComponent
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
            facts.needsDeepRead = true
            facts.notes.append("Couldn't open PDF")
            return
        }
        guard !pdf.isLocked else {
            facts.pageCount = pdf.pageCount
            facts.needsDeepRead = true
            facts.notes.append("PDF is password-protected")
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
            let pages = PDFText.renderPages(facts.url, maxPages: maxPages)
            if pages.isEmpty, pdf.pageCount > 0 {
                facts.needsDeepRead = true
                facts.notes.append("Couldn't render the pages to read them")
                return
            }
            var ocr = ""
            for page in pages {
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

    /// The start of a file as text (UTF-8, or UTF-16 by its byte-order mark or its shape), or
    /// nil for binary files.
    static func readPlainText(_ url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        let bytes = [UInt8](data.prefix(64))
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data.count % 2 == 0 ? data : data.dropLast(), encoding: .utf16)
        }
        // UTF-16 without a mark: ASCII-range text with every other byte zero.
        if bytes.count >= 8, bytes.count % 2 == 0 {
            let odd = stride(from: 1, to: bytes.count, by: 2).map { bytes[$0] }
            let even = stride(from: 0, to: bytes.count, by: 2).map { bytes[$0] }
            if odd.allSatisfy({ $0 == 0 }), even.allSatisfy({ $0 != 0 }) {
                return String(data: data.count % 2 == 0 ? data : data.dropLast(), encoding: .utf16LittleEndian)
            }
            if even.allSatisfy({ $0 == 0 }), odd.allSatisfy({ $0 != 0 }) {
                return String(data: data.count % 2 == 0 ? data : data.dropLast(), encoding: .utf16BigEndian)
            }
        }
        guard !data.contains(0) else { return nil }
        // Cutting at a byte limit can split a multi-byte character; drop the partial tail.
        for trim in 0...3 where data.count > trim {
            if let text = String(data: data.dropLast(trim), encoding: .utf8) { return text }
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

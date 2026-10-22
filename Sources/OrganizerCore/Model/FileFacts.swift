import Foundation

/// Everything we know about one downloaded file, gathered without any model.
/// Rules decide from this; in Milestone 3 the model gets a summary of it too.
public struct FileFacts: Codable, Sendable {
    public var url: URL
    public var name: String
    /// File name without the extension.
    public var baseName: String
    /// Lowercased, without the dot. Empty if there is none.
    public var fileExtension: String
    public var kind: FileKind
    public var isDirectory: Bool
    public var size: Int64

    public var created: Date?
    public var modified: Date?
    /// When the file landed in its folder: the download date for files in ~/Downloads.
    public var dateAdded: Date?

    /// Download source URLs from `kMDItemWhereFroms`: the strongest signal we have.
    public var whereFroms: [String]

    /// A text sample: document text, OCR text of an image/scan, or the start of a text file.
    public var text: String?
    public var textSource: TextSource?
    /// Title stored inside the document (PDF info dictionary, Office core properties).
    public var documentTitle: String?
    public var pageCount: Int?

    public var media: MediaInfo?
    public var image: ImageInfo?
    /// Paths inside a zip archive (first few hundred), or the names at the top of a folder
    /// (hidden ones included, like .git): used to spot code projects.
    public var archiveEntries: [String]?
    /// Folders only: what's inside, all the way down.
    public var folder: FolderContents?

    public var isScreenshot: Bool
    /// The name says nothing useful ("document (3)", "IMG_4821", a hash...).
    public var nameIsUnclear: Bool
    /// Things that went wrong while reading; shown with `organize facts`.
    public var notes: [String]
    /// Its text couldn't be read: text recognition was skipped (quick scan) or failed, or the
    /// document is locked or broken. Until it's read, nothing about it can be decided safely.
    public var needsDeepRead = false
    /// Something sensitive found while reading more of the file than `text` keeps (secrets
    /// past the excerpt the model sees).
    public var sensitive: SensitiveFinding?
    /// Images only: what the vision model saw (Organize Now's image phase). A document-like image
    /// is then filed like a document; a picture still goes to Downloaded Images, with a real name.
    public var visionCard: FileCard?

    public enum TextSource: String, Codable, Sendable {
        case content, pdfText, pdfOCR, office, imageOCR
    }

    /// The date used for dated file names: download date, falling back to creation date.
    public var downloadDate: Date {
        dateAdded ?? created ?? modified ?? Date()
    }

    /// Hosts of the download source URLs, lowercased ("rds2.northsouth.edu").
    public var sourceHosts: [String] {
        whereFroms.compactMap { URL(string: $0)?.host()?.lowercased() }
    }

    public func isFrom(domain: String) -> Bool {
        sourceHosts.contains { $0 == domain || $0.hasSuffix("." + domain) }
    }
}

public struct MediaInfo: Codable, Sendable, Equatable {
    /// Seconds.
    public var duration: Double?
    public var title: String?
}

public struct ImageInfo: Codable, Sendable, Equatable {
    public var width: Int?
    public var height: Int?
    public var dateTaken: Date?
    public var cameraModel: String?
}

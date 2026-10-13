import Foundation

/// A coarse file type, decided from the extension only (cheap and deterministic).
public enum FileKind: String, Codable, Sendable {
    case pdf
    case wordDocument
    case spreadsheet
    case presentation
    case csv
    case text
    case code
    case image
    case video
    case audio
    case archive
    case diskImage
    case installer
    case firmware
    case keyMaterial
    case folder
    case other

    public init(fileExtension ext: String, isDirectory: Bool) {
        let ext = ext.lowercased()
        if let kind = Self.byExtension[ext] {
            self = kind
        } else {
            self = isDirectory ? .folder : .other
        }
    }

    private static let byExtension: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        func add(_ kind: FileKind, _ exts: String) {
            for ext in exts.split(separator: " ") { map[String(ext)] = kind }
        }
        add(.pdf, "pdf")
        add(.wordDocument, "docx doc pages rtf odt")
        add(.spreadsheet, "xlsx xls numbers ods")
        // .key is Keynote on a Mac; a private key saved as .key is still caught by its content.
        add(.presentation, "pptx ppt key odp")
        add(.csv, "csv tsv")
        add(.text, "txt md json xml yaml yml log ini")
        // No .ts here: it's both TypeScript and an MPEG transport stream.
        add(.code, "swift py js jsx tsx c cpp h hpp m java kt rb go rs sh zsh ipynb html css sql r")
        add(.image, "jpg jpeg png heic heif gif webp tif tiff bmp dng cr2 cr3 nef arw raw")
        add(.video, "mp4 m4v mov mkv avi mpeg mpg wmv webm flv 3gp")
        add(.audio, "mp3 m4a aac wav flac aiff aif ogg opus")
        add(.archive, "zip tar gz tgz bz2 xz 7z rar")
        add(.diskImage, "dmg iso")
        add(.installer, "pkg mpkg app exe msi appimage deb rpm apk")
        add(.firmware, "bin img hex fw ipsw")
        add(.keyMaterial, "pem p12 pfx ppk kdbx ovpn mobileconfig asc gpg keychain-db 1pux")
        return map
    }()

    /// Kinds whose content is plain text worth reading for the safety checks.
    var isPlainText: Bool {
        switch self {
        case .csv, .text, .code, .keyMaterial, .other: true
        default: false
        }
    }
}

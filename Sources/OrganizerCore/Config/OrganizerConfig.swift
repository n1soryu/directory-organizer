import Foundation

/// Your folder layout and limits. All paths are relative to the home root, which is
/// `TestData/Home` while testing and only becomes the real `~` when you switch it.
public struct OrganizerConfig: Sendable {
    public var reviewFolder = "Desktop/To Delete (Review)"

    public var university = "Documents/University"
    public var records = "Documents/University/Records"
    public var fsae = "Documents/FSAE"
    public var essays = "Documents/Essays"
    public var secure = "Documents/Secure"

    public var films = "Movies/Films"
    public var tvShows = "Movies/TV Shows"
    public var clips = "Movies/Clips"
    public var downloadedImages = "Pictures/Downloaded Images"

    /// Top-level folders a file may be moved into. Anything else is redirected to review.
    public var allowedRoots = [
        "Documents", "Pictures", "Movies", "Music", "Developer", "Desktop/To Delete (Review)",
    ]

    /// Folder names that are never valid destinations or path components.
    public var forbiddenComponents: Set<String> = ["Library", "Applications", "System"]

    /// Most folders a single proposal may create (e.g. "TV Shows/Severance" is 2).
    public var maxNewFolders = 3

    /// Proposals below this confidence go to review instead (used for the model in Milestone 3).
    public var confidenceThreshold = 0.75

    public var courses = CourseCatalog.bsEconomics
    public var recordTypes = RecordType.nsuDefaults

    public init() {}
}

/// A kind of NSU record. Records are kept forever, side by side, with the download date
/// at the front of the name: "2026-10-13 Grade History.pdf", "2027-02-01 Grade History.pdf".
public struct RecordType: Sendable {
    /// Name used when the downloaded file's own name is unclear.
    public var label: String
    /// Subfolder of Records.
    public var folder: String
    /// Lowercase phrases matched against the file name and the first lines of text.
    public var keywords: [String]

    public init(_ label: String, folder: String, keywords: [String]) {
        self.label = label
        self.folder = folder
        self.keywords = keywords
    }

    public static let nsuDefaults: [RecordType] = [
        RecordType("Grade History", folder: "Grades", keywords: ["grade history", "grade report", "grade sheet", "gradesheet"]),
        RecordType("Transcript", folder: "Grades", keywords: ["transcript"]),
        RecordType("Advising Slip", folder: "Advising", keywords: ["advising"]),
        RecordType("Payment Receipt", folder: "Payments", keywords: ["payment", "money receipt", "fee receipt", "tuition", "invoice"]),
        RecordType("Admit Card", folder: "Admit Cards", keywords: ["admit card"]),
        RecordType("Course Registration", folder: "Registration", keywords: ["registration", "enrollment", "enrolment"]),
        RecordType("Certificate", folder: "Certificates", keywords: ["certificate"]),
        RecordType("Curriculum", folder: "Curriculum", keywords: ["curriculum", "degree plan"]),
        RecordType("Academic Calendar", folder: "Calendars", keywords: ["academic calendar"]),
    ]
}

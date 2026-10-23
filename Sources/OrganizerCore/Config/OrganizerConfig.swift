import Foundation

/// Your folder layout and limits. All paths are relative to the home root, which is
/// `TestData/Home` while testing and only becomes the real `~` when you switch it.
public struct OrganizerConfig: Sendable {
    public var reviewFolder = "Desktop/To Delete (Review)"

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

    public init() {}
}

import Foundation

/// Films, TV episodes and clips. Decided from the name and the length in the file header;
/// the video itself is never analysed.
struct VideoRule: Rule {
    let name = "video"

    func evaluate(_ facts: FileFacts, config: OrganizerConfig) -> Decision? {
        guard facts.kind == .video else { return nil }
        let parsed = MediaNameCleaner.parse(facts.baseName)
        let minutes = facts.media?.duration.map { Int($0 / 60) }
        let rename = parsed.displayName == facts.baseName ? nil : parsed.displayName

        if parsed.isEpisode {
            return Decision(destination: "\(config.tvShows)/\(FileNames.sanitize(parsed.title))", newBaseName: rename,
                            confidence: 0.95, reason: "TV episode (\(parsed.displayName))", source: .rule(name))
        }
        if MediaNameCleaner.hasReleaseTags(facts.baseName) || (minutes ?? 0) >= 60 {
            let why = minutes.map { $0 >= 60 ? "\($0) min long" : "release name" } ?? "release name"
            return Decision(destination: config.films, newBaseName: rename,
                            confidence: 0.9, reason: "Film (\(why))", source: .rule(name))
        }
        if let minutes, minutes < 20 {
            return Decision(destination: config.clips, confidence: 0.85,
                            reason: "Short video (\(max(minutes, 1)) min or less)", source: .rule(name))
        }
        return Decision(destination: "Movies", confidence: 0.8, reason: "Video file", source: .rule(name))
    }
}

/// Downloaded images and screenshots. (Sorting into picture subfolders waits until
/// you've planned that structure.)
struct ImageRule: Rule {
    let name = "image"

    func evaluate(_ facts: FileFacts, config: OrganizerConfig) -> Decision? {
        guard facts.kind == .image else { return nil }
        var reason = facts.isScreenshot ? "Screenshot" : "Image"
        if facts.nameIsUnclear {
            reason += " (name unclear; the model will describe it in Milestone 3)"
        }
        return Decision(destination: config.downloadedImages, confidence: 0.95, reason: reason, source: .rule(name))
    }
}

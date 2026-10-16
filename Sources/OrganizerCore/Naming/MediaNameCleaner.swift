import Foundation

/// What a film or episode file name says once the release clutter is removed.
public struct MediaName: Equatable, Sendable {
    public var title: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?

    public var isEpisode: Bool { season != nil && episode != nil }

    /// "Avengers Infinity War", "The Matrix (1999)", "Severance S01E04".
    public var displayName: String {
        if let season, let episode {
            return String(format: "%@ S%02dE%02d", title, season, episode)
        }
        if let year { return "\(title) (\(year))" }
        return title
    }
}

/// Cleans downloaded film/TV names without any model:
/// "Avengers_Infinity_War_4K_BluRay" -> "Avengers Infinity War",
/// "Severance.S01E04.1080p.WEB-DL.x265-GROUP" -> "Severance S01E04".
/// The year is only kept if it's in the name; we never guess one.
public enum MediaNameCleaner {
    /// Quality, source, codec and release words that never belong in a title.
    /// Plain English words ("max", "proper", "limited", "web") are left out on purpose:
    /// the title ends at the first token found here, so "Mad Max Fury Road" must survive.
    private static let releaseTokens: Set<String> = [
        "2160p", "1080p", "1080i", "720p", "576p", "480p", "4k", "8k", "uhd", "fhd", "hd",
        "bluray", "blu-ray", "bdrip", "brrip", "bdremux", "remux", "webrip", "web-dl", "webdl",
        "hdtv", "dvdrip", "dvdscr", "hdrip", "hdcam",
        "x264", "x265", "h264", "h265", "hevc", "xvid", "divx", "av1",
        "hdr", "hdr10", "hdr10+", "dovi", "10bit", "8bit", "12bit",
        "aac", "ac3", "eac3", "dts", "dts-hd", "truehd", "atmos", "ddp",
        "repack", "unrated", "remastered", "imax",
        "yify", "yts", "rarbg", "esub", "esubs", "amzn", "dsnp", "hmax", "atvp",
    ]

    public static func parse(_ baseName: String) -> MediaName {
        // Bracketed tags ("[YTS.MX]", "{Group}") are always clutter.
        var name = baseName.replacingOccurrences(of: #"[\[\{][^\]\}]*[\]\}]"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: "[._+]", with: " ", options: .regularExpression)
        let words = name.split(whereSeparator: \.isWhitespace).map(String.init)

        var titleWords: [String] = []
        var result = MediaName(title: "")
        let lowered = words.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "()-")) }
        for (index, lower) in lowered.enumerated() {
            let next = index + 1 < lowered.count ? lowered[index + 1] : nil
            // "S01E04", "1x04", or "S01 E04" split in two (from "Show.S01.E04").
            if let (season, episode) = episodeMarker(lower) ?? next.flatMap({ splitEpisodeMarker(lower, $0) }) {
                result.season = season
                result.episode = episode
                break
            }
            // A year ends the title when it's in parentheses, or release words (or another year)
            // follow it, and isn't the title's first word: "Dune (2024)", "Blade Runner 2049 2017
            // 1080p" (2049 is title), "2001 A Space Odyssey".
            if index > 0, let year = asYear(lower),
               words[index].hasPrefix("(")
                || next.map({ isReleaseToken($0) || asYear($0) != nil || episodeMarker($0) != nil }) ?? false {
                result.year = year
                break
            }
            if isReleaseToken(lower) { break }
            titleWords.append(words[index])
        }

        var title = titleWords.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -()"))
        if title.isEmpty { title = FileNames.humanize(baseName) }
        // All-lowercase or ALL-CAPS titles read better in title case; short words in an
        // ALL-CAPS title are likely acronyms ("CSI MIAMI" → "CSI Miami").
        if title == title.lowercased() {
            title = title.capitalized
        } else if title == title.uppercased() {
            title = title.split(separator: " ").map { $0.count <= 3 ? String($0) : $0.capitalized }.joined(separator: " ")
        }
        result.title = title
        return result
    }

    /// True if the name carries release clutter (quality, codec, source...).
    public static func hasReleaseTags(_ baseName: String) -> Bool {
        baseName.replacingOccurrences(of: "[._+\\[\\]()]", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .contains { isReleaseToken($0.lowercased()) }
    }

    private static func isReleaseToken(_ word: String) -> Bool {
        if releaseTokens.contains(word) { return true }
        // "x265-GROUP", "web-dl", "ddp5", "aac2", "dts-hd" and similar.
        let head = word.split(separator: "-").first.map(String.init) ?? word
        if releaseTokens.contains(head) && word.contains("-") { return true }
        return word.range(of: #"^(ddp?|aac|ac3|eac3|dts|truehd)\d"#, options: .regularExpression) != nil
    }

    /// A plausible release year: 1920 to next year.
    private static func asYear(_ word: String) -> Int? {
        guard word.count == 4, let year = Int(word) else { return nil }
        let thisYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        return (1920...thisYear + 1).contains(year) ? year : nil
    }

    /// "s01" followed by "e04".
    private static func splitEpisodeMarker(_ word: String, _ next: String) -> (Int, Int)? {
        guard word.count <= 3, next.count <= 4, word.first == "s", next.first == "e",
              let season = Int(word.dropFirst()), let episode = Int(next.dropFirst()) else { return nil }
        return (season, episode)
    }

    private static let episodePatterns = [#"^s(\d{1,2})e(\d{1,3})$"#, #"^(\d{1,2})x(\d{2})$"#]
        .map { try! NSRegularExpression(pattern: $0) }   // fixed patterns: compiled once

    /// "s01e04", "s1e4", "1x04".
    private static func episodeMarker(_ word: String) -> (Int, Int)? {
        for regex in episodePatterns {
            let ns = word as NSString
            if let m = regex.firstMatch(in: word, range: NSRange(location: 0, length: ns.length)),
               let s = Int(ns.substring(with: m.range(at: 1))), let e = Int(ns.substring(with: m.range(at: 2))) {
                return (s, e)
            }
        }
        return nil
    }
}

import Foundation

/// Building safe, consistent file names. Every proposed name passes through `sanitize`,
/// whether it came from a rule or (later) from the model.
public enum FileNames {
    public static let maxBaseLength = 80

    /// Removes characters that break paths or Finder, collapses spaces, caps the length.
    public static func sanitize(_ baseName: String) -> String {
        var name = baseName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .filter { !$0.isNewline && !($0.asciiValue.map { $0 < 32 || $0 == 127 } ?? false) }
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // No leading dots (hidden files) and no trailing dots or spaces.
        name = String(name.drop { $0 == "." || $0 == " " })
        while name.last == "." || name.last == " " { name.removeLast() }
        if name.count > maxBaseLength {
            name = String(name.prefix(maxBaseLength)).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// Joins a base name and the original extension. The extension never changes.
    public static func join(_ baseName: String, _ fileExtension: String) -> String {
        fileExtension.isEmpty ? baseName : baseName + "." + fileExtension
    }

    /// Turns machine names into words: "GradeHistory" -> "Grade History",
    /// "Avengers_Infinity_War" -> "Avengers Infinity War".
    public static func humanize(_ baseName: String) -> String {
        var spaced = baseName.replacingOccurrences(of: "_", with: " ")
        if !spaced.contains(" ") {
            spaced = spaced.replacingOccurrences(of: ".", with: " ")
        }
        // Split camelCase ("gradeHistory", "GradeHistory") but not acronyms ("NSU", "ECO372").
        var result = ""
        var previous: Character?
        for char in spaced {
            if let prev = previous, prev.isLowercase, char.isUppercase { result.append(" ") }
            result.append(char)
            previous = char
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "2026-10-13" in local time.
    public static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "2026-10" in local time.
    public static func month(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// True if the name already starts with a date like "2026-10-13" or "2026-10".
    public static func startsWithDate(_ baseName: String) -> Bool {
        baseName.range(of: #"^\d{4}-\d{2}(-\d{2})?\b"#, options: .regularExpression) != nil
    }

    /// Candidate names for a destination that already holds a different file with this name:
    /// "Report (2026-10-13).pdf", then "Report (2026-10-13) 2.pdf", ... If the name already
    /// carries that date, just counts: "2026-10-13 Grade History 2.pdf".
    public static func clashAlternatives(_ baseName: String, _ fileExtension: String, date: Date) -> [String] {
        let stamp = day(date)
        let dated = baseName.contains(stamp) ? baseName : "\(baseName) (\(stamp))"
        var names = dated == baseName ? [] : [join(dated, fileExtension)]
        names += (2...99).map { join("\(dated) \($0)", fileExtension) }
        return names
    }
}

import Foundation

/// Your NSU courses. A course folder is only created for codes in this list; any other
/// code goes to review so a stray "ABC123" in an invoice can't invent a course.
public struct CourseCatalog: Sendable {
    /// "ECO372" -> "Introduction to Econometrics" (title may be empty).
    public var titles: [String: String]

    public init(_ titles: [String: String]) {
        self.titles = titles
    }

    public func contains(_ code: String) -> Bool { titles[code] != nil }

    /// Course codes in `text`, normalized ("eco 101", "ECO-101", "PHY107L" -> "ECO101", "PHY107").
    /// Pass `uppercaseOnly` for file names, where "abc123" is more often noise.
    public static func codes(in text: String, uppercaseOnly: Bool = false) -> [String] {
        // NSU codes: 3 letters, optional space/dash/underscore, 3 digits, optional L for labs.
        // (NSRegularExpression because Swift's Regex has no lookbehind.)
        let regex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])([A-Za-z]{3})[ \-_]?(\d{3})L?(?![A-Za-z0-9])"#)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let letters = ns.substring(with: match.range(at: 1))
            if uppercaseOnly && letters != letters.uppercased() { return nil }
            return letters.uppercased() + ns.substring(with: match.range(at: 2))
        }
    }

    /// Known course codes in `text`, most frequent first, with how often each appears.
    public func knownCodes(in text: String) -> [(code: String, count: Int)] {
        var counts: [String: Int] = [:]
        for code in Self.codes(in: text) where contains(code) {
            counts[code, default: 0] += 1
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    /// A known course whose full title appears in `text` ("Introduction to Econometrics").
    /// Only titles of 2+ words and 12+ characters count, so "Biology I" can't match by accident.
    public func codeByTitle(in text: String) -> String? {
        let haystack = " " + Self.normalize(text) + " "
        let hits = titles.filter { _, title in
            let words = title.split(separator: " ")
            guard words.count >= 2, title.count >= 12 else { return false }
            return haystack.contains(" " + Self.normalize(title) + " ")
        }
        // Prefer the longest title when one contains another.
        return hits.max { $0.value.count < $1.value.count }?.key
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
    }
}

extension CourseCatalog {
    /// BS in Economics, curriculum effective from Spring 2019 (NSU Department of Economics): 50 courses,
    /// including the prerequisites it names (ENG102, BUS112). Alternatives the curriculum only lists as
    /// equivalents (BUS135, MAT120, BUS173, FIN258) are left out. Free electives (27 credits) aren't
    /// listed: when one turns up as an unknown code, approving it adds it here.
    public static let bsEconomics = CourseCatalog([
        // General education: languages
        "ENG102": "", "ENG103": "Intermediate Composition", "ENG105": "Advanced Composition",
        "BUS251": "Business Communication", "BEN205": "Bangla Language and Literature",
        // Humanities
        "PHI101": "Introduction to Philosophy",
        "HIS101": "Bangladesh History and Culture", "HIS102": "World Civilization",
        "HIS202": "Indo-Bangla History", "HIS203": "Islamic History", "HIS205": "World History",
        "HIS103": "Emergence of Bangladesh",
        // Social sciences
        "POL101": "Introduction to Political Science", "POL104": "Introduction to Governance",
        "PAD201": "Introduction to Public Administration", "SOC101": "Introduction to Sociology",
        "ENV203": "", "GEO205": "Introduction to Bangladesh Geography",
        "ANT101": "Introduction to Anthropology",
        // Computer and math skills, school core, math requirements
        "MIS107": "Computer Information Systems", "BUS112": "",
        "ECO101": "Introduction to Microeconomics", "ECO104": "Introduction to Macroeconomics",
        "ECO135": "Applied Mathematics for Economics I", "ECO172": "Introduction to Statistics",
        "ECO173": "Applied Statistics", "MAT125": "Introduction to Linear Algebra",
        "ECO245": "Applied Mathematics for Economics II",
        // Sciences (with lab)
        "BIO103": "Biology I", "CHE101": "Chemistry I", "ENV107": "Introduction to Environmental Science",
        "PBH101": "Introduction to Public Health", "PHY107": "Physics I", "PSY101": "Introduction to Psychology",
        // Major: required
        "ECO201": "Intermediate Microeconomic Theory I", "ECO204": "Intermediate Macroeconomic Theory I",
        "ECO301": "Intermediate Microeconomic Theory II", "ECO304": "Intermediate Macroeconomic Theory II",
        "ECO372": "Introduction to Econometrics", "ECO490": "Senior Seminar",
        // Major: electives
        "ECO317": "Money, Banking and Financial Markets", "ECO328": "International Trade Theory and Policy",
        "ECO348": "Economy of Bangladesh", "ECO354": "Environmental and Natural Resource Economics",
        "ECO406": "History of Economic Thought", "ECO414": "Public Finance", "ECO415": "Economic Development",
        "ECO441": "Labor Economics", "ECO443": "Health Economics", "ECO492": "Special Topics in Economics",
    ])
}

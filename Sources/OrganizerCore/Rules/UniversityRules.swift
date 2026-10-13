import Foundation

extension FileFacts {
    /// Downloaded from northsouth.edu (including the RDS portal), or clearly an NSU document.
    var isNSU: Bool {
        isFrom(domain: "northsouth.edu")
            || head(1_500).contains("north south university")
            || containsWords(searchableName, "nsu")
    }
}

/// Records are dated with the download date and kept side by side:
/// "2026-10-13 Grade History.pdf" now, "2027-02-01 Grade History.pdf" next semester.
private func recordDecision(_ facts: FileFacts, _ type: RecordType, evidence: String,
                            confidence: Double, config: OrganizerConfig, rule: String) -> Decision {
    var base = facts.nameIsUnclear ? type.label : FileNames.humanize(NameQuality.stripCopySuffix(facts.baseName))
    if !FileNames.startsWithDate(base) {
        base = "\(FileNames.day(facts.downloadDate)) \(base)"
    }
    return Decision(
        destination: "\(config.records)/\(type.folder)",
        newBaseName: base,
        tags: [.nsu],
        confidence: confidence,
        reason: "NSU record (\(type.label.lowercased())): \(evidence)",
        source: .rule(rule)
    )
}

/// "GradeHistory.pdf" downloaded from northsouth.edu.
struct RecordByNameRule: Rule {
    let name = "NSU record"

    func evaluate(_ facts: FileFacts, config: OrganizerConfig) -> Decision? {
        guard facts.isNSU else { return nil }
        let name = facts.searchableName
        for type in config.recordTypes {
            if let keyword = type.keywords.first(where: { containsWords(name, $0) }) {
                return recordDecision(facts, type, evidence: "\"\(keyword)\" in the file name",
                                      confidence: 0.95, config: config, rule: self.name)
            }
        }
        return nil
    }
}

/// An NSU document whose first lines say what record it is ("Grade History" heading).
/// Runs after the course rule, so course material that mentions "registration" stays a course file.
struct RecordByContentRule: Rule {
    let name = "NSU record (content)"

    func evaluate(_ facts: FileFacts, config: OrganizerConfig) -> Decision? {
        guard facts.isDocumentLike, facts.isNSU else { return nil }
        let head = facts.head(600)
        for type in config.recordTypes {
            if let keyword = type.keywords.first(where: { containsWords(head, $0) }) {
                return recordDecision(facts, type, evidence: "\"\(keyword)\" at the top of the document",
                                      confidence: 0.85, config: config, rule: name)
            }
        }
        return nil
    }
}

/// Course material: a known course code in the name, at the top of the text, or the
/// course's full title. Goes to University/<CODE>/.
struct CourseRule: Rule {
    let name = "course"

    func evaluate(_ facts: FileFacts, config: OrganizerConfig) -> Decision? {
        guard let (code, evidence, confidence) = match(facts, config.courses) else { return nil }
        let rename = facts.nameIsUnclear ? Self.courseFileName(code: code, facts: facts) : nil
        var reason = "Course \(code): \(evidence)"
        if facts.nameIsUnclear && rename == nil {
            reason += " (name unclear; the model will suggest one in Milestone 3)"
        }
        return Decision(
            destination: "\(config.university)/\(code)",
            newBaseName: rename,
            tags: [.nsu],
            confidence: confidence,
            reason: reason,
            source: .rule(name)
        )
    }

    private func match(_ facts: FileFacts, _ courses: CourseCatalog) -> (String, String, Double)? {
        // 1. In the file name: "ECO372 Lecture 05.pdf", "eco-201 outline.pdf".
        let nameCodes = Set(CourseCatalog.codes(in: facts.baseName).filter(courses.contains))
        if nameCodes.count == 1, let code = nameCodes.first {
            return (code, "course code in the file name", 0.95)
        }

        guard facts.isDocumentLike else { return nil }
        let head = facts.head(3_000)
        let known = courses.knownCodes(in: head)
        // A curriculum or course list mentions dozens of codes: not about one course.
        guard known.count <= 5 else { return nil }

        // 2. At the top of the document and the most mentioned: "ECO 201: Intermediate Micro..."
        let top = String(head.prefix(300))
        if let first = CourseCatalog.codes(in: top).first(where: courses.contains),
           let best = known.first, known.first(where: { $0.code == first })?.count == best.count {
            return (first, "\(first) at the top of the document", 0.85)
        }
        if known.count == 1, let only = known.first {
            return (only.code, "\(only.code) mentioned in the text", 0.8)
        }

        // 3. The full course title: "Introduction to Econometrics".
        if let code = courses.codeByTitle(in: facts.searchableName + "\n" + String(head.prefix(500))) {
            return (code, "course title \"\(courses.titles[code] ?? "")\"", 0.8)
        }
        return nil
    }

    /// "ECO201 Course Outline", "ECO372 Lecture 05", or the document's own title.
    static func courseFileName(code: String, facts: FileFacts) -> String? {
        let head = facts.head(800)
        func number(after word: String) -> Int? {
            guard let range = head.range(of: word + #"\s*(no\.?|#)?\s*(\d{1,2})\b"#, options: .regularExpression) else { return nil }
            return Int(head[range].filter(\.isNumber))
        }
        let kind: String? =
            if head.contains("course outline") || head.contains("syllabus") { "Course Outline" }
            else if let n = number(after: "lecture") { String(format: "Lecture %02d", n) }
            else if let n = number(after: "assignment") { String(format: "Assignment %02d", n) }
            else if let n = number(after: "problem set") { String(format: "Problem Set %02d", n) }
            else if let n = number(after: "quiz") { String(format: "Quiz %02d", n) }
            else if head.contains("midterm") || head.contains("mid-term") { "Midterm" }
            else if head.contains("final exam") { "Final Exam" }
            else { nil }
        if let kind { return "\(code) \(kind)" }
        if let title = facts.usableDocumentTitle {
            return title.uppercased().contains(code) ? title : "\(code) \(title)"
        }
        return nil
    }
}

/// A course code that looks real but isn't in your list ("MAT999 notes.pdf").
/// Sent to review so a stray code can't create a course folder.
struct UnknownCourseRule: Rule {
    let name = "unknown course"

    func evaluate(_ facts: FileFacts, config: OrganizerConfig) -> Decision? {
        let unknown = CourseCatalog.codes(in: facts.baseName, uppercaseOnly: true).filter { !config.courses.contains($0) }
        guard let code = unknown.first else { return nil }
        return Decision(
            destination: config.reviewFolder,
            confidence: 1,
            reason: "\(code) looks like a course code but isn't in your course list",
            source: .rule(name),
            alerts: [Alert(.unknownCourse, "\(code) isn't in your course list. If you're taking it, add it and this file will go to University/\(code).")]
        )
    }
}

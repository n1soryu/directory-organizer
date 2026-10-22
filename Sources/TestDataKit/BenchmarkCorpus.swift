import Foundation
import OrganizerCore

/// The benchmark's test set (~/Developer/mlx-experiment: `Sources/Bench/Data.swift` and
/// `Validate.swift`), for `organize eval`. Copied as it was, with one change for decision 3 of
/// docs/mlx-plan.md: there's no Documents/Unsorted, so the earlier files that sat there are
/// waiting in Downloads (`folder` nil). The scoring rules are unchanged. For measuring only:
/// never use any of it in a prompt (a test checks).
public enum BenchmarkCorpus {
    public struct EarlierFile: Sendable {
        public var id: String
        public var fileName: String
        /// Relative to the home root; nil: waiting in Downloads (was Documents/Unsorted).
        public var folder: String?
        public var about: String
    }

    public struct NewFile: Sendable {
        public var id: String
        public var fileName: String
    }

    public struct Scenario: Sendable {
        public var id: String
        public var newFile: String
        /// The 5 earlier files shown with the new one, in the benchmark's order.
        public var candidates: [String]
        /// Earlier files the embedder should rank in its top 3 (none: nothing matches).
        public var neighbours: [String]
    }

    public enum Mark: String, Sendable, Codable {
        case right = "✓", partly = "~", wrong = "✗"
    }

    public static let earlierFiles: [EarlierFile] = [
        .init(id: "E1", fileName: "statement_0712.txt", folder: nil, about: "Northwind Electric electricity bill, account 4471-220, July 2026, 412 kWh, amount due 2,340.50, due 2026-08-10, customer Alex Rahman"),
        .init(id: "W1", fileName: "Bill-2026-06.txt", folder: "Documents/Bills/Water", about: "Contoso Water bill, account CW-90817, June 2026, 14 m³, amount due 610.00"),
        .init(id: "W2", fileName: "Bill-2026-07.txt", folder: "Documents/Bills/Water", about: "Contoso Water bill, same account, July 2026, 16 m³, amount due 690.00"),
        .init(id: "M1", fileName: "manual_v2.txt", folder: "Documents/Manuals", about: "Kestrel AX-300 Wi-Fi router user guide: setup, LED meanings, factory reset, safety"),
        .init(id: "M2", fileName: "UM_HD12.txt", folder: "Documents/Manuals", about: "Brightline HD12 blender instruction manual: assembly, speeds, cleaning, warranty"),
        .init(id: "R1", fileName: "receipt.txt", folder: nil, about: "Harbor Grill restaurant receipt, 2026-08-02, dinner for two, itemized, total 3,180.00, paid by card"),
        .init(id: "L1", fileName: "results_0815.txt", folder: nil, about: "Lakeside Clinic blood test results for patient Alex Rahman, 2026-08-15, CBC and lipid panel values with reference ranges"),
        .init(id: "L2", fileName: "rx.txt", folder: nil, about: "Lakeside Clinic prescription for Alex Rahman, 2026-08-16, Dr. Nadia Karim, atorvastatin 10 mg"),
        .init(id: "G1", fileName: "welcome.txt", folder: nil, about: "PeakFit Gym membership welcome letter and terms, member Alex Rahman, monthly plan starting 2026-06-01"),
        .init(id: "T1", fileName: "boarding_pass.txt", folder: nil, about: "SkyBridge Airways boarding pass, Alex Rahman, flight SB 214 DAC→SIN, 2026-07-03, seat 14C, gate B7"),
        .init(id: "H1", fileName: "agreement_final.txt", folder: nil, about: "Residential lease agreement, 14 Elm Road Apt 3B, landlord Mira Holdings, tenant Alex Rahman, term 2025-10-01 to 2026-09-30, monthly rent 18,000"),
        .init(id: "H2", fileName: "rcpt_march.txt", folder: nil, about: "Rent receipt from Mira Holdings for March 2026, 14 Elm Road Apt 3B, 18,000 received"),
        .init(id: "C1", fileName: "cover_letter.txt", folder: "Documents/Career", about: "Cover letter by Alex Rahman applying for a Data Analyst role at Tailspin Analytics"),
        .init(id: "U1", fileName: "stat101_lec5.txt", folder: "Documents/University/STAT101", about: "Riverton University, STAT101 Introduction to Statistics, Lecture 5: sampling distributions"),
        .init(id: "P1", fileName: "payslip.txt", folder: nil, about: "Fabrikam Ltd payslip, employee Alex Rahman, August 2026, gross pay, deductions, net pay"),
    ]

    public static let newFiles: [NewFile] = [
        .init(id: "N1", fileName: "download.txt"),
        .init(id: "N2", fileName: "scan_0932.txt"),
        .init(id: "N3", fileName: "nw_news_oct.txt"),
        .init(id: "N4", fileName: "IMG_2231.txt"),
        .init(id: "N5", fileName: "document (4).txt"),
        .init(id: "N6", fileName: "ticket.txt"),
        .init(id: "N7", fileName: "notice.txt"),
        .init(id: "N8", fileName: "report.txt"),
        .init(id: "N9", fileName: "Lecture 6.txt"),
        .init(id: "N10", fileName: "form.txt"),
        .init(id: "N11", fileName: "grinder.txt"),
        .init(id: "N12", fileName: "payslip (1).txt"),
    ]

    /// All 27 files, earlier first, as the benchmark's Task 1 ran them.
    public static var allFiles: [(id: String, fileName: String)] {
        earlierFiles.map { ($0.id, $0.fileName) } + newFiles.map { ($0.id, $0.fileName) }
    }

    /// Task 1 keys: words a right kind contains (any), and the issuer's name.
    public static let cardKeys: [String: (kinds: [String], issuer: String)] = {
        var keys: [String: (kinds: [String], issuer: String)] = [:]
        func set(_ ids: [String], _ kinds: [String], _ issuer: String) {
            for id in ids { keys[id] = (kinds, issuer) }
        }
        set(["E1", "N1"], ["bill", "statement", "invoice"], "northwind")
        set(["W1", "W2", "N2"], ["bill", "statement", "invoice"], "contoso")
        set(["N3"], ["newsletter", "news", "bulletin", "update"], "northwind")
        set(["M1"], ["manual", "guide"], "kestrel")
        set(["M2"], ["manual", "guide", "instruction"], "brightline")
        set(["N11"], ["manual", "guide", "instruction"], "ember")
        set(["R1"], ["receipt", "bill", "invoice"], "harbor grill")
        set(["N4"], ["receipt", "bill", "invoice"], "blue fern")
        set(["L1", "N8"], ["lab", "test", "result", "report"], "lakeside")
        set(["L2"], ["prescription"], "lakeside")
        set(["G1"], ["membership", "welcome", "terms", "agreement", "contract", "letter"], "peakfit")
        set(["T1"], ["boarding", "ticket"], "skybridge")
        set(["N6"], ["boarding", "ticket"], "orbit")
        set(["H1"], ["lease", "tenancy", "rental", "agreement", "contract"], "mira")
        set(["H2"], ["receipt"], "mira")
        set(["N7"], ["notice", "letter", "renewal"], "mira")
        set(["C1"], ["cover letter", "letter"], "rahman")
        set(["N5"], ["cv", "résumé", "resume", "curriculum vitae"], "rahman")
        set(["U1", "N9"], ["lecture", "notes", "slides"], "riverton")
        set(["N10"], ["form", "application", "renewal"], "riverton")
        set(["P1", "N12"], ["payslip", "pay slip", "pay stub", "salary", "payroll"], "fabrikam")
        return keys
    }()

    public static let scenarios: [Scenario] = [
        .init(id: "S1", newFile: "N1", candidates: ["E1", "W1", "W2", "R1", "P1"], neighbours: ["E1"]),
        .init(id: "S2", newFile: "N2", candidates: ["W1", "W2", "E1", "R1", "H2"], neighbours: ["W1", "W2"]),
        .init(id: "S3", newFile: "N3", candidates: ["E1", "W1", "W2", "M1", "G1"], neighbours: []),
        .init(id: "S4", newFile: "N4", candidates: ["R1", "M2", "T1", "G1", "E1"], neighbours: ["R1"]),
        .init(id: "S5", newFile: "N5", candidates: ["C1", "P1", "U1", "G1", "H1"], neighbours: ["C1"]),
        .init(id: "S6", newFile: "N6", candidates: ["T1", "R1", "G1", "P1", "H1"], neighbours: ["T1"]),
        .init(id: "S7", newFile: "N7", candidates: ["H1", "H2", "W1", "E1", "G1"], neighbours: ["H1", "H2"]),
        // L2 is welcome but not required (the benchmark's "L1 (L2 ok)").
        .init(id: "S8", newFile: "N8", candidates: ["L1", "L2", "G1", "P1", "R1"], neighbours: ["L1"]),
        .init(id: "S9", newFile: "N9", candidates: ["U1", "C1", "M1", "L1", "P1"], neighbours: ["U1"]),
        .init(id: "S10", newFile: "N10", candidates: ["G1", "H1", "E1", "W1", "C1"], neighbours: []),
        .init(id: "S11", newFile: "N11", candidates: ["M1", "M2", "R1", "G1", "E1"], neighbours: ["M1", "M2"]),
        .init(id: "S12", newFile: "N12", candidates: ["P1", "C1", "R1", "E1", "H2"], neighbours: ["P1"]),
    ]

    public static let existingFolders = [
        "Documents/Bills",
        "Documents/Bills/Water",
        "Documents/Manuals",
        "Documents/Career",
        "Documents/University",
        "Documents/University/STAT101",
    ]

    public static func earlier(_ id: String) -> EarlierFile? { earlierFiles.first { $0.id == id } }
    public static func new(_ id: String) -> NewFile? { newFiles.first { $0.id == id } }
    public static func text(_ fileName: String) -> String { texts[fileName] ?? "" }

    // MARK: - Scoring (the benchmark's rules)

    /// Task 1: is the kind right, and is the issuer the right one?
    public static func score(_ card: FileCard?, id: String) -> (kind: Bool, issuer: Bool) {
        guard let card, let key = cardKeys[id] else { return (false, false) }
        let kind = card.kind.lowercased()
        let issuer = (card.issuer ?? "").lowercased()
        return (key.kinds.contains { kind.contains($0) }, issuer.contains(key.issuer))
    }

    /// Task 2, as the benchmark scored it. `moved`: the ids of the earlier files that move with it.
    public static func score(_ scenario: Scenario, action: FolderDecision.Action?, folder: String?, moved: Set<String>) -> Mark {
        guard let action else { return .wrong }
        let f = norm(folder ?? "")
        let tail = f.hasPrefix("documents/") ? String(f.dropFirst("documents/".count)) : f
        func has(_ words: [String]) -> Bool { words.contains { tail.contains($0) } }
        func joins(_ target: String) -> Bool { action == .join && f == norm(target) }
        let isNew = action == .newFolder

        switch scenario.id {
        case "S1":
            let words = ["electric", "power", "energy", "utilit", "northwind"]
            if isNew, f.hasPrefix("documents/bills/"), has(words), moved == ["E1"] { return .right }
            if isNew, has(words), moved == ["E1"] { return .partly }
            if joins("Documents/Bills"), moved == ["E1"] { return .partly }
            return .wrong
        case "S2": return joins("Documents/Bills/Water") && moved.isEmpty ? .right : .wrong
        case "S3", "S10": return action == .wait ? .right : .wrong
        case "S4":
            return isNew && has(["receipt", "expense", "purchase", "spending", "dining", "food"]) && moved == ["R1"] ? .right : .wrong
        case "S5": return joins("Documents/Career") && moved.isEmpty ? .right : .wrong
        case "S6":
            return isNew && has(["travel", "trip", "flight", "boarding", "airline"]) && moved == ["T1"] ? .right : .wrong
        case "S7":
            guard isNew, has(["hous", "home", "rent", "lease", "tenan", "apartment", "elm", "mira"]) else { return .wrong }
            if moved == ["H1", "H2"] { return .right }
            if moved == ["H1"] || moved == ["H2"] { return .partly }
            return .wrong
        case "S8":
            guard isNew, has(["medic", "health", "clinic", "lakeside", "lab"]) else { return .wrong }
            return moved == ["L1", "L2"] || moved == ["L1"] ? .right : .wrong
        case "S9": return joins("Documents/University/STAT101") && moved.isEmpty ? .right : .wrong
        case "S11": return joins("Documents/Manuals") && moved.isEmpty ? .right : .wrong
        case "S12":
            if isNew, has(["pay", "salary", "income", "employ", "work", "job", "fabrikam"]), moved == ["P1"] { return .right }
            if joins("Documents/Career"), moved == ["P1"] { return .partly }
            if isNew, f.hasPrefix("documents/career/"), moved == ["P1"] { return .partly }
            return .wrong
        default: return .wrong
        }
    }

    /// Lowercased, trimmed, no trailing slash (as the benchmark compared folders).
    static func norm(_ s: String) -> String {
        var s = s.trimmingCharacters(in: .whitespaces).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Embeddings: were all expected earlier files in the top 3? (nil: nothing should match)
    public static func recallHit(_ scenario: Scenario, top3: [String]) -> Bool? {
        scenario.neighbours.isEmpty ? nil : scenario.neighbours.allSatisfy(top3.contains)
    }

    // MARK: - Baseline (REPORT.md, run Q2: MLX Qwen3-8B 4bit-DWQ, thinking on; C's image evaluation)

    public enum Baseline {
        public static let cardKinds = 27
        public static let cardIssuers = 25   // 25–26/27; the CV's issuer is null, counted wrong
        public static let decisions: (right: Int, partly: Int, wrong: Int) = (10, 1, 1)
        public static let recallAt3 = 10
        /// Top-1 cosine: averaged and lowest over the 10 files with a match; N3 and N10 have none.
        public static let averageTop1: Float = 0.893
        public static let lowestTop1: Float = 0.727
        public static let noMatchTop1: [String: Float] = ["N3": 0.758, "N10": 0.703]
        /// Qwen3-VL 4B on the 18 images (C, second run).
        public static let imageKinds = 10
        public static let imageFacts = 18
        public static let imageNames = 18
        public static let imagesRightWay = 18
    }
}

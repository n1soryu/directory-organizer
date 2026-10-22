import CoreGraphics
import CoreText
import Foundation
import ImageIO
import OrganizerCore
import UniformTypeIdentifiers

/// One image of the vision evaluation, with what a good card says about it.
public struct EvalImage: Sendable {
    public var file: String
    /// What it is, for the report ("receipt photo", "screenshot"...).
    public var label: String
    /// Words a right `kind` contains (any of them).
    public var kinds: [String]
    /// The one fact that matters, and words that show the card got it (any of them,
    /// in the issuer, subject, summary or suggested name).
    public var fact: String
    public var factWords: [String]
    /// A document-like image (receipt, bill, ticket, letter, diagram, slide), rather than a picture.
    public var isDocument: Bool
}

public struct EvalScore: Sendable, Equatable {
    public var kind: Bool
    public var fact: Bool
    /// The suggested name is one the organizer would use, and isn't just the old name again.
    public var name: Bool
    /// Sent the right way: a document-like image to the folder decision, a picture to Downloaded Images.
    public var split: Bool

    public init(kind: Bool, fact: Bool, name: Bool, split: Bool) {
        self.kind = kind
        self.fact = fact
        self.name = name
        self.split = split
    }
}

/// The image set for choosing the vision model (`organize image-eval`, docs/mlx-plan.md Milestone C).
/// Documents, screenshots, a meme and diagrams are drawn here; the photos are Apple's own account
/// pictures from /Library/User Pictures, copied at build time (they're Apple's, so never committed).
/// File names say nothing about the content, as with real downloads. These images are only for
/// measuring: never use them, or anything about them, as examples in a prompt.
public enum ImageEvalSet {
    public static let userPictures = URL(filePath: "/Library/User Pictures")

    /// Builds the set into `folder`, which must not exist yet (nothing is ever replaced or deleted).
    public static func build(in folder: URL, pictures: URL = userPictures) throws -> [EvalImage] {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: folder.path])
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var set: [EvalImage] = []

        // Photographed paper: tilted, on a table, a little noisy.
        try paperPhoto(["GREENLEAF GROCERS", "12 Harbour Road", "", "Oat milk 1L        2.10", "Bananas 1kg        1.45",
                        "Sourdough loaf     3.80", "Cheddar 200g       2.95", "", "TOTAL             10.30",
                        "Card payment", "14/09/2026  18:42", "Thank you for shopping!"],
                       paper: CGSize(width: 340, height: 620), angle: 5, seed: 1, to: folder.appending(path: "IMG_2041.jpg"))
        set.append(EvalImage(file: "IMG_2041.jpg", label: "grocery receipt photo", kinds: ["receipt"],
                             fact: "the shop", factWords: ["greenleaf"], isDocument: true))

        try paperPhoto(["BLUE DOOR CAFE", "Table 4", "", "Flat white        3.20", "Croissant         2.60",
                        "Orange juice      2.90", "", "Total             8.70", "Paid - Visa", "03 Oct 2026"],
                       paper: CGSize(width: 320, height: 520), angle: -4, seed: 2, to: folder.appending(path: "IMG_2077.jpg"))
        set.append(EvalImage(file: "IMG_2077.jpg", label: "cafe receipt photo", kinds: ["receipt"],
                             fact: "the cafe", factWords: ["blue door"], isDocument: true))

        try paperPhoto(["NORTHWIND ENERGY", "Electricity bill", "", "Account 4471 9902", "Billing period: August 2026",
                        "Usage: 312 kWh", "", "Amount due: 58.40", "Due date: 15 September 2026",
                        "Pay online or by direct debit."],
                       paper: CGSize(width: 560, height: 720), angle: 3, seed: 3, to: folder.appending(path: "IMG_2102.jpg"))
        set.append(EvalImage(file: "IMG_2102.jpg", label: "electricity bill photo", kinds: ["bill", "invoice", "statement"],
                             fact: "the energy company", factWords: ["northwind"], isDocument: true))

        try paperPhoto(["SKYWAY AIRLINES", "BOARDING PASS", "", "Passenger: SAMIRA KHAN", "Flight SW 214",
                        "From: Lisbon (LIS)", "To: Amsterdam (AMS)", "Date: 21 NOV 2026", "Gate B12   Seat 17C",
                        "Boarding 07:35"],
                       paper: CGSize(width: 620, height: 420), angle: -3, seed: 4, to: folder.appending(path: "IMG_2156.jpg"))
        set.append(EvalImage(file: "IMG_2156.jpg", label: "boarding pass photo", kinds: ["boarding pass", "ticket"],
                             fact: "the airline", factWords: ["skyway"], isDocument: true))

        try paperPhoto(["Maple Street Dental Clinic", "", "Dear Mr. Okafor,", "",
                        "This is a reminder of your check-up", "appointment on 4 December 2026 at 10:15.",
                        "Please call us if you need to reschedule.", "", "Kind regards,", "Reception"],
                       paper: CGSize(width: 560, height: 700), angle: 2, seed: 5, to: folder.appending(path: "IMG_2180.jpg"))
        set.append(EvalImage(file: "IMG_2180.jpg", label: "appointment letter photo",
                             kinds: ["letter", "reminder", "appointment", "notice"],
                             fact: "the clinic", factWords: ["maple street", "dental"], isDocument: true))

        // Screenshots: a window with a title bar.
        try screenshot(title: "Messages", lines: ["Jonas: Are we still on for Saturday?", "Me: Yes! 7pm at the usual place.",
                                                  "Jonas: Great, I'll book the table.", "Me: Perfect, see you then"],
                       to: folder.appending(path: "Screenshot 2026-10-03 at 21.14.03.png"))
        set.append(EvalImage(file: "Screenshot 2026-10-03 at 21.14.03.png", label: "chat screenshot", kinds: ["screenshot"],
                             fact: "a chat", factWords: ["message", "chat", "conversation"], isDocument: false))

        try screenshot(title: "Wi-Fi", lines: ["Wi-Fi                                   On", "Known network: HomeNet-5G   Connected",
                                               "Other networks: CafeGuest, Office-2.4", "Ask to join networks          Off",
                                               "Advanced...    Details..."],
                       to: folder.appending(path: "Screenshot 2026-10-07 at 09.02.51.png"))
        set.append(EvalImage(file: "Screenshot 2026-10-07 at 09.02.51.png", label: "settings screenshot", kinds: ["screenshot"],
                             fact: "Wi-Fi settings", factWords: ["wi-fi", "wifi", "network"], isDocument: false))

        try screenshot(title: "PhotoBox", lines: ["PhotoBox quit unexpectedly.", "",
                                                  "Click Reopen to open the application again.",
                                                  "Click Report to see more details.", "", "[ Ignore ]  [ Report... ]  [ Reopen ]"],
                       to: folder.appending(path: "Screenshot 2026-10-09 at 14.40.17.png"))
        set.append(EvalImage(file: "Screenshot 2026-10-09 at 14.40.17.png", label: "error dialog screenshot",
                             kinds: ["screenshot", "error"], fact: "the app", factWords: ["photobox"], isDocument: false))

        // Diagrams and a slide.
        try flowchart(to: folder.appending(path: "image (4).png"))
        set.append(EvalImage(file: "image (4).png", label: "flowchart", kinds: ["diagram", "flowchart", "flow chart"],
                             fact: "the process", factWords: ["order", "payment"], isDocument: true))

        try barChart(to: folder.appending(path: "chart.png"))
        set.append(EvalImage(file: "chart.png", label: "bar chart", kinds: ["chart", "graph"],
                             fact: "what is measured", factWords: ["rainfall"], isDocument: true))

        try slide(to: folder.appending(path: "Untitled.png"))
        set.append(EvalImage(file: "Untitled.png", label: "presentation slide", kinds: ["slide", "presentation"],
                             fact: "the topic", factWords: ["volunteer"], isDocument: true))

        // Real photos, saved as JPEGs with camera-style names.
        let photos: [(source: String, file: String, label: String, words: [String])] = [
            ("Animals/Zebra.heic", "IMG_3310.jpg", "zebra photo", ["zebra"]),
            ("Animals/Parrot.heic", "IMG_3342.jpg", "parrot photo", ["parrot", "bird", "macaw"]),
            ("Flowers/Sunflower.heic", "IMG_3371.jpg", "sunflower photo", ["sunflower"]),
            ("Instruments/Guitar.heic", "IMG_3388.jpg", "guitar photo", ["guitar"]),
            ("Nature/Cactus.heic", "IMG_3405.jpg", "cactus photo", ["cactus", "succulent"]),
            ("Instruments/Piano.heic", "IMG_3420.jpg", "piano photo", ["piano", "keyboard", "keys"]),
        ]
        for photo in photos {
            guard let image = load(pictures.appending(path: photo.source)) else { continue }
            try Drawing.write(image, type: .jpeg, to: folder.appending(path: photo.file))
            set.append(EvalImage(file: photo.file, label: photo.label, kinds: ["photo", "picture", "image"],
                                 fact: "what it shows", factWords: photo.words, isDocument: false))
        }

        // A meme: a real photo with the classic white captions.
        if let owl = load(pictures.appending(path: "Animals/Owl.heic")) {
            try meme(owl, top: "WHEN THE BUILD PASSES", bottom: "ON THE FIRST TRY", to: folder.appending(path: "download (2).jpg"))
            set.append(EvalImage(file: "download (2).jpg", label: "meme", kinds: ["meme"],
                                 fact: "the joke", factWords: ["build"], isDocument: false))
        }
        return set
    }

    /// Scores a card: is the kind right, did it catch the key fact, is the name usable, and
    /// would the organizer send the image the right way?
    public static func score(_ card: FileCard, for image: EvalImage) -> EvalScore {
        let kind = card.kind.lowercased()
        let text = [card.issuer ?? "", card.subject, card.summary, card.suggestedName].joined(separator: " ").lowercased()
        let simple = { (name: String) in name.lowercased().filter { $0.isLetter || $0.isNumber } }
        let old = (image.file as NSString).deletingPathExtension
        let name = Planner.validTitle(card.suggestedName).map { simple($0) != simple(old) } ?? false
        return EvalScore(kind: image.kinds.contains { kind.contains($0) },
                         fact: image.factWords.contains { text.contains($0) },
                         name: name,
                         split: ImageKinds.isDocument(card.kind) == image.isDocument)
    }

    // MARK: - Drawing

    private static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// A sheet of paper with typed lines, photographed on a wooden-ish table.
    private static func paperPhoto(_ lines: [String], paper: CGSize, angle: CGFloat, seed: Int, to url: URL) throws {
        let width = 1200, height = 1000
        guard let image = Drawing.bitmap(width: width, height: height, draw: { context in
            // The table: a warm gradient.
            let colors = [CGColor(red: 0.55, green: 0.42, blue: 0.30, alpha: 1), CGColor(red: 0.40, green: 0.29, blue: 0.20, alpha: 1)]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
            }
            // The paper, scaled up to fill the photo, turned a little.
            let scale = min(Double(width) * 0.8 / paper.width, Double(height) * 0.85 / paper.height)
            let size = CGSize(width: paper.width * scale, height: paper.height * scale)
            context.saveGState()
            context.translateBy(x: Double(width) / 2, y: Double(height) / 2)
            context.rotate(by: angle * .pi / 180)
            let sheet = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
            context.setShadow(offset: CGSize(width: 6, height: -6), blur: 18, color: CGColor(gray: 0, alpha: 0.5))
            context.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1))
            context.fill(sheet)
            context.setShadow(offset: .zero, blur: 0, color: nil)
            text(lines.joined(separator: "\n"), in: sheet.insetBy(dx: size.width * 0.08, dy: size.height * 0.06),
                 context: context, font: "Courier", size: 15 * scale, color: CGColor(gray: 0.12, alpha: 1))
            context.restoreGState()
            // Sensor noise: faint specks.
            var generator = SeededGenerator(seed: UInt64(seed))
            for _ in 0..<4_000 {
                let gray = Double.random(in: 0...1, using: &generator)
                context.setFillColor(CGColor(gray: gray, alpha: 0.12))
                context.fill(CGRect(x: Double.random(in: 0..<Double(width), using: &generator),
                                    y: Double.random(in: 0..<Double(height), using: &generator), width: 2, height: 2))
            }
        }) else { throw CocoaError(.fileWriteUnknown) }
        try Drawing.write(image, type: .jpeg, to: url)
    }

    /// A macOS-style window: grey title bar with the three buttons, white content.
    private static func screenshot(title: String, lines: [String], to url: URL) throws {
        let width = 1400, height = 900
        guard let image = Drawing.bitmap(width: width, height: height, draw: { context in
            context.setFillColor(CGColor(red: 0.20, green: 0.36, blue: 0.55, alpha: 1))  // desktop
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let window = CGRect(x: 150, y: 100, width: 1100, height: 700)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(window)
            let bar = CGRect(x: window.minX, y: window.maxY - 56, width: window.width, height: 56)
            context.setFillColor(CGColor(gray: 0.91, alpha: 1))
            context.fill(bar)
            for (index, color) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
                context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
                context.fillEllipse(in: CGRect(x: bar.minX + 22 + Double(index) * 30, y: bar.midY - 9, width: 18, height: 18))
            }
            text(title, in: CGRect(x: bar.minX, y: bar.minY + 10, width: bar.width, height: 36), context: context,
                 font: "Helvetica-Bold", size: 24, color: CGColor(gray: 0.2, alpha: 1), centered: true)
            text(lines.joined(separator: "\n\n"), in: window.insetBy(dx: 50, dy: 50).offsetBy(dx: 0, dy: -20),
                 context: context, font: "Helvetica", size: 28, color: CGColor(gray: 0.1, alpha: 1))
        }) else { throw CocoaError(.fileWriteUnknown) }
        try Drawing.write(image, type: .png, to: url)
    }

    private static func flowchart(to url: URL) throws {
        let width = 1000, height = 1100
        guard let image = Drawing.bitmap(width: width, height: height, draw: { context in
            let steps = ["Customer places order", "Check stock", "Take payment", "Payment accepted?", "Ship order"]
            var previous: CGRect?
            for (index, step) in steps.enumerated() {
                let box = CGRect(x: 300, y: 920 - Double(index) * 200, width: 400, height: 110)
                context.setStrokeColor(CGColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 1))
                context.setLineWidth(4)
                if step.hasSuffix("?") {
                    let path = CGMutablePath()
                    path.addLines(between: [CGPoint(x: box.midX, y: box.maxY), CGPoint(x: box.maxX, y: box.midY),
                                            CGPoint(x: box.midX, y: box.minY), CGPoint(x: box.minX, y: box.midY)])
                    path.closeSubpath()
                    context.addPath(path)
                    context.strokePath()
                    // The "no" branch.
                    context.move(to: CGPoint(x: box.maxX, y: box.midY))
                    context.addLine(to: CGPoint(x: box.maxX + 120, y: box.midY))
                    context.strokePath()
                    text("No: notify customer", in: CGRect(x: box.maxX + 10, y: box.midY + 8, width: 200, height: 70),
                         context: context, font: "Helvetica", size: 22, color: CGColor(gray: 0.1, alpha: 1))
                } else {
                    context.stroke(box)
                }
                text(step, in: box.insetBy(dx: 30, dy: 30), context: context, font: "Helvetica", size: 26,
                     color: CGColor(gray: 0.1, alpha: 1), centered: true)
                if let previous {
                    context.move(to: CGPoint(x: previous.midX, y: previous.minY))
                    context.addLine(to: CGPoint(x: box.midX, y: box.maxY))
                    context.strokePath()
                }
                previous = box
            }
        }) else { throw CocoaError(.fileWriteUnknown) }
        try Drawing.write(image, type: .png, to: url)
    }

    private static func barChart(to url: URL) throws {
        let width = 1200, height = 800
        guard let image = Drawing.bitmap(width: width, height: height, draw: { context in
            text("Average monthly rainfall (mm)", in: CGRect(x: 0, y: 700, width: width, height: 60), context: context,
                 font: "Helvetica-Bold", size: 34, color: CGColor(gray: 0.1, alpha: 1), centered: true)
            context.setStrokeColor(CGColor(gray: 0.2, alpha: 1))
            context.setLineWidth(3)
            context.move(to: CGPoint(x: 120, y: 640))
            context.addLine(to: CGPoint(x: 120, y: 120))
            context.addLine(to: CGPoint(x: 1120, y: 120))
            context.strokePath()
            let months = [("Jan", 78), ("Feb", 61), ("Mar", 55), ("Apr", 42), ("May", 30), ("Jun", 12)]
            for (index, month) in months.enumerated() {
                let x = 180 + Double(index) * 160
                context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
                context.fill(CGRect(x: x, y: 120, width: 100, height: Double(month.1) * 6))
                text(month.0, in: CGRect(x: x, y: 70, width: 100, height: 40), context: context, font: "Helvetica",
                     size: 26, color: CGColor(gray: 0.1, alpha: 1), centered: true)
                text("\(month.1)", in: CGRect(x: x, y: 130 + Double(month.1) * 6, width: 100, height: 36), context: context,
                     font: "Helvetica", size: 24, color: CGColor(gray: 0.1, alpha: 1), centered: true)
            }
        }) else { throw CocoaError(.fileWriteUnknown) }
        try Drawing.write(image, type: .png, to: url)
    }

    private static func slide(to url: URL) throws {
        let width = 1600, height = 900
        guard let image = Drawing.bitmap(width: width, height: height, draw: { context in
            context.setFillColor(CGColor(red: 0.10, green: 0.18, blue: 0.32, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            text("Community Garden Volunteer Day", in: CGRect(x: 100, y: 640, width: 1400, height: 120), context: context,
                 font: "Helvetica-Bold", size: 64, color: CGColor(gray: 1, alpha: 1))
            text("• Saturday 8 November, 9:00 to 13:00\n• Planting, weeding and compost\n• Gloves and tools provided\n• Sign up at the front desk",
                 in: CGRect(x: 120, y: 160, width: 1300, height: 420), context: context, font: "Helvetica", size: 42,
                 color: CGColor(gray: 0.92, alpha: 1))
        }) else { throw CocoaError(.fileWriteUnknown) }
        try Drawing.write(image, type: .png, to: url)
    }

    private static func meme(_ photo: CGImage, top: String, bottom: String, to url: URL) throws {
        let width = 900, height = 900
        guard let image = Drawing.bitmap(width: width, height: height, draw: { context in
            context.draw(photo, in: CGRect(x: 0, y: 0, width: width, height: height))
            for (caption, y) in [(top, 760.0), (bottom, 40.0)] {
                text(caption, in: CGRect(x: 20, y: y, width: Double(width) - 40, height: 110), context: context,
                     font: "Impact", size: 64, color: CGColor(gray: 1, alpha: 1), centered: true, outlined: true)
            }
        }) else { throw CocoaError(.fileWriteUnknown) }
        try Drawing.write(image, type: .jpeg, to: url)
    }

    private static func text(_ string: String, in rect: CGRect, context: CGContext, font name: String, size: CGFloat,
                             color: CGColor, centered: Bool = false, outlined: Bool = false) {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        var alignment: CTTextAlignment = centered ? .center : .left
        let style = withUnsafeBytes(of: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                  value: pointer.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ]
        if outlined {
            // A negative width strokes and fills: white letters with a black edge.
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -4
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = CGColor(gray: 0, alpha: 1)
        }
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }
}

/// Repeatable randomness, so the set is the same image for image every time.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        // SplitMix64.
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

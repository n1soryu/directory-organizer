import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws fake documents and images for the sandbox.
enum Drawing {
    static let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

    /// A normal PDF with a text layer, one string per page.
    static func textPDF(pages: [String], title: String? = nil, to url: URL) throws {
        var box = letter
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        for page in pages {
            context.beginPDFPage(nil)
            drawText(page, in: letter.insetBy(dx: 60, dy: 60), context: context, fontSize: 13)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// A PDF that is only a picture of text, like a phone or printer scan: no text layer.
    static func scannedPDF(text: String, to url: URL) throws {
        let scale: CGFloat = 2
        guard let page = bitmap(width: Int(letter.width * scale), height: Int(letter.height * scale), draw: { context in
            context.scaleBy(x: scale, y: scale)
            drawText(text, in: letter.insetBy(dx: 60, dy: 60), context: context, fontSize: 16)
        }) else { throw CocoaError(.fileWriteUnknown) }

        var box = letter
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        context.draw(page, in: letter)
        context.endPDFPage()
        context.closePDF()
    }

    /// An image with text on it (screenshots, a photographed recovery phrase).
    static func textImage(_ text: String, width: Int = 1200, height: Int = 900, fontSize: CGFloat = 40,
                          type: UTType = .png, to url: URL) throws {
        guard let image = bitmap(width: width, height: height, draw: { context in
            drawText(text, in: CGRect(x: 60, y: 60, width: width - 120, height: height - 120),
                     context: context, fontSize: fontSize)
        }) else { throw CocoaError(.fileWriteUnknown) }
        try write(image, type: type, to: url)
    }

    /// A picture without text: colored shapes. `seed` makes different pictures.
    static func picture(seed: Int, type: UTType = .jpeg, to url: URL) throws {
        guard let image = bitmap(width: 800, height: 600, draw: { context in
            for i in 0..<12 {
                let hue = CGFloat((seed * 37 + i * 53) % 360) / 360
                context.setFillColor(CGColor(red: hue, green: 1 - hue, blue: CGFloat(i) / 12, alpha: 1))
                context.fillEllipse(in: CGRect(x: (seed * 13 + i * 61) % 700, y: (seed * 29 + i * 47) % 500,
                                               width: 80 + i * 10, height: 80 + i * 6))
            }
        }) else { throw CocoaError(.fileWriteUnknown) }
        try write(image, type: type, to: url)
    }

    // MARK: - Helpers

    static func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return context.makeImage()
    }

    static func drawText(_ text: String, in rect: CGRect, context: CGContext, fontSize: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }

    static func write(_ image: CGImage, type: UTType, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Builds zip-based files (Office documents, archives) by zipping a staging folder.
enum Zipper {
    static func zip(files: [String: String], to url: URL) throws {
        let staging = FileManager.default.temporaryDirectory.appending(path: "fo-zip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        for (path, contents) in files {
            let file = staging.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", "-X", url.path, "."]
        process.currentDirectoryURL = staging
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    static func docx(paragraphs: [String], title: String? = nil, to url: URL) throws {
        let body = paragraphs.map { "<w:p><w:r><w:t>\(escape($0))</w:t></w:r></w:p>" }.joined()
        var files = [
            "[Content_Types].xml": contentTypes,
            "word/document.xml": #"<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"#
                + body + "</w:body></w:document>",
        ]
        if let title {
            files["docProps/core.xml"] = #"<?xml version="1.0" encoding="UTF-8"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>"#
                + escape(title) + "</dc:title></cp:coreProperties>"
        }
        try zip(files: files, to: url)
    }

    static func pptx(slides: [[String]], to url: URL) throws {
        var files = ["[Content_Types].xml": contentTypes]
        for (index, lines) in slides.enumerated() {
            let paragraphs = lines.map { "<a:p><a:r><a:t>\(escape($0))</a:t></a:r></a:p>" }.joined()
            files["ppt/slides/slide\(index + 1).xml"] = #"<?xml version="1.0" encoding="UTF-8"?><p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody>"#
                + paragraphs + "</p:txBody></p:sp></p:spTree></p:cSld></p:sld>"
        }
        try zip(files: files, to: url)
    }

    static func xlsx(strings: [String], to url: URL) throws {
        let items = strings.map { "<si><t>\(escape($0))</t></si>" }.joined()
        try zip(files: [
            "[Content_Types].xml": contentTypes,
            "xl/sharedStrings.xml": #"<?xml version="1.0" encoding="UTF-8"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
                + items + "</sst>",
        ], to: url)
    }

    private static let contentTypes = #"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

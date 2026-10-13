import CoreGraphics
import Foundation
import PDFKit

/// Text and metadata from a PDF, via PDFKit.
enum PDFText {
    struct Result {
        var text: String
        var pageCount: Int
        var title: String?
    }

    static func read(_ url: URL, maxPages: Int, limit: Int) -> Result? {
        guard let document = PDFDocument(url: url) else { return nil }
        guard !document.isLocked else {
            return Result(text: "", pageCount: document.pageCount, title: nil)
        }
        var text = ""
        for index in 0..<min(maxPages, document.pageCount) {
            guard text.count < limit else { break }
            if let page = document.page(at: index)?.string {
                text += page + "\n"
            }
        }
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return Result(text: String(text.prefix(limit)), pageCount: document.pageCount, title: title)
    }

    /// Renders the first pages as images, for OCR of scanned PDFs (no text layer).
    static func renderPages(_ url: URL, maxPages: Int, scale: CGFloat = 2) -> [CGImage] {
        guard let document = PDFDocument(url: url), !document.isLocked else { return [] }
        return (0..<min(maxPages, document.pageCount)).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
            guard width > 0, height > 0, let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            return context.makeImage()
        }
    }
}

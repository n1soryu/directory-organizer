import Foundation

/// Text from .docx/.xlsx/.pptx. These are zip archives of XML files, so we open the
/// zip, pick the parts that hold the text and strip the XML tags.
enum OfficeText {
    struct Result {
        var text: String
        var title: String?
    }

    static func read(_ url: URL, limit: Int) throws -> Result {
        let zip = try ZipArchive(url: url)
        func part(_ path: String) -> Data? {
            zip.entries.first { $0.path == path }.flatMap { try? zip.contents(of: $0) }
        }

        let parts: [String]
        switch url.pathExtension.lowercased() {
        case "docx":
            parts = ["word/document.xml"]
        case "pptx":
            // slide1.xml, slide2.xml, ... in numeric order (not slide1, slide10, slide2).
            parts = zip.entries.map(\.path)
                .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        case "xlsx":
            parts = ["xl/sharedStrings.xml"]
        default:
            parts = []
        }

        var text = ""
        for path in parts {
            guard text.count < limit, let data = part(path) else { continue }
            text += XMLText.extract(data) + "\n"
        }

        var title: String?
        if let core = part("docProps/core.xml") {
            title = XMLText.extract(core, only: ["dc:title"]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Result(text: String(text.prefix(limit)), title: title?.isEmpty == false ? title : nil)
    }
}

/// Collects the character data of an XML document, one line per paragraph.
private final class XMLText: NSObject, XMLParserDelegate {
    private var text = ""
    private var only: Set<String>?
    private var depthInWanted = 0

    /// Elements that end a paragraph or cell (Word, PowerPoint, Excel).
    private static let lineBreaks: Set<String> = ["w:p", "a:p", "si", "w:br", "w:tab"]

    static func extract(_ data: Data, only elements: Set<String>? = nil) -> String {
        let collector = XMLText()
        collector.only = elements
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.text
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if only?.contains(name) == true { depthInWanted += 1 }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if only?.contains(name) == true { depthInWanted -= 1 }
        if only == nil && Self.lineBreaks.contains(name) && !text.hasSuffix("\n") { text += "\n" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if only == nil || depthInWanted > 0 { text += string }
    }
}

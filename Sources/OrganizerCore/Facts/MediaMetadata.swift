import AVFoundation
import Foundation
import ImageIO

enum MediaMetadata {
    /// Length and embedded title of a video or audio file. Reads the header only,
    /// never the whole file, so it's fast even for a 20 GB film.
    static func load(_ url: URL) async -> MediaInfo? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 else {
            return nil
        }
        var title: String?
        if let metadata = try? await asset.load(.commonMetadata),
           let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).first {
            title = try? await item.load(.stringValue)
        }
        return MediaInfo(duration: duration.seconds, title: title)
    }
}

enum ImageMetadata {
    struct Result {
        var info: ImageInfo
        /// macOS writes "Screenshot" into the EXIF user comment of its screenshots.
        var looksLikeScreenshot: Bool
    }

    static func load(_ url: URL) -> Result? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        var dateTaken: Date?
        if let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            // EXIF dates look like "2026:10:12 21:14:03", in the camera's local time.
            let parts = raw.split { $0 == ":" || $0 == " " }.compactMap { Int($0) }
            if parts.count == 6 {
                dateTaken = Calendar.current.date(from: DateComponents(
                    year: parts[0], month: parts[1], day: parts[2],
                    hour: parts[3], minute: parts[4], second: parts[5]))
            }
        }
        let comment = exif[kCGImagePropertyExifUserComment] as? String
        return Result(
            info: ImageInfo(
                width: props[kCGImagePropertyPixelWidth] as? Int,
                height: props[kCGImagePropertyPixelHeight] as? Int,
                dateTaken: dateTaken,
                cameraModel: tiff[kCGImagePropertyTIFFModel] as? String
            ),
            looksLikeScreenshot: comment == "Screenshot"
        )
    }
}

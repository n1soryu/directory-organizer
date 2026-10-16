import CoreGraphics
import Foundation
import Vision

/// On-device OCR with Apple's Vision framework (no network, runs on the Neural Engine).
enum TextRecognizer {
    /// The text in the image ("" if there is none), or nil if recognition failed: then
    /// nothing is known about the image, which is not the same as "no text".
    static func text(in image: CGImage) async -> String? {
        await recognize { try await $0.perform(on: image) }
    }

    static func text(at url: URL) async -> String? {
        await recognize { try await $0.perform(on: url) }
    }

    /// Tries twice: Vision can fail under load and succeed a moment later.
    private static func recognize(
        _ perform: @escaping @Sendable (RecognizeTextRequest) async throws -> [RecognizedTextObservation]
    ) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Normally well under a second; a stalled call counts as failed (nil), not as "no text".
        // Measured: the first call in a process sometimes takes ~26 s while Vision loads its
        // model, every later one well under a second. A limit near that would mark ordinary
        // images unreadable; 60 s still catches a call that never returns.
        let attempt = { [request] in try? await withTimeout(seconds: 60) { try await perform(request) } }
        var result = await attempt() ?? nil
        if result == nil {
            try? await Task.sleep(for: .milliseconds(200))
            result = await attempt() ?? nil
        }
        guard let observations = result else { return nil }
        // Lines top to bottom (Vision's y points up; centres rounded to 1% so a line's words
        // share one), then left to right. A key per observation keeps the order consistent.
        func line(_ o: RecognizedTextObservation) -> Int { Int((o.boundingBox.origin.y + o.boundingBox.height / 2) * 100) }
        return observations
            .sorted { line($0) != line($1) ? line($0) > line($1) : $0.boundingBox.origin.x < $1.boundingBox.origin.x }
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

/// Loading Vision's text model can take ~26 s the first time in a process. The app does that
/// in the background at launch, so Organize Now doesn't wait for it.
public enum TextRecognition {
    public static func warmUp() async {
        guard let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let blank = context.makeImage() else { return }
        _ = await TextRecognizer.text(in: blank)
    }
}

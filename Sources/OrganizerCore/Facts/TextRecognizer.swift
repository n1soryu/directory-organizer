import CoreGraphics
import Foundation
import Vision

/// On-device OCR with Apple's Vision framework (no network, runs on the Neural Engine).
enum TextRecognizer {
    static func text(in image: CGImage) async -> String {
        await recognize { try await $0.perform(on: image) }
    }

    static func text(at url: URL) async -> String {
        await recognize { try await $0.perform(on: url) }
    }

    private static func recognize(
        _ perform: (RecognizeTextRequest) async throws -> [RecognizedTextObservation]
    ) async -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        guard let observations = try? await perform(request) else { return "" }
        // Reading order: top to bottom (Vision's y axis points up), then left to right.
        return observations
            .sorted {
                abs($0.boundingBox.origin.y - $1.boundingBox.origin.y) > 0.01
                    ? $0.boundingBox.origin.y > $1.boundingBox.origin.y
                    : $0.boundingBox.origin.x < $1.boundingBox.origin.x
            }
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

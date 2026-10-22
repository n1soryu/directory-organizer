import Foundation
import OrganizerCore
import OrganizerMLX
import TestDataKit

/// `organize image-eval [--download]`: chooses the vision model (docs/mlx-plan.md, Milestone C).
/// Builds the image set into a new temporary folder, then has each candidate card every image,
/// one model loaded at a time. Qwen3 8B also cards the document-like images from their OCR text
/// alone, to see whether those are better left to the text model. Prints the scores, speed and memory.
func runImageEval(download: Bool, imagesOnly: Bool) async {
    let store = ModelStore()
    if imagesOnly {
        let folder = evalFolder()
        do {
            let images = try ImageEvalSet.build(in: folder)
            print("Image set: \(images.count) images in \(folder.path)")
            exit(0)
        } catch {
            fail("couldn't build the image set: \(error.localizedDescription)")
        }
    }
    let needed = ModelSpec.visionCandidates + [.language]
    let missing = store.missing(needed)
    if !missing.isEmpty {
        guard download else {
            fail("not downloaded: \(missing.map(\.displayName).joined(separator: ", ")). Run image-eval --download (~3 GB per vision model, once).")
        }
        do {
            try await ModelDownloader(store: store).downloadMissing(missing) { spec, fraction in
                ModelCheckProgress.show(spec, fraction)
            }
        } catch {
            fail("download failed: \(error.localizedDescription)")
        }
    }
    if let reason = MLXEngine.unavailableReason(store: store) { fail("the models can't run: \(reason)") }

    let folder = evalFolder()
    let images: [EvalImage]
    do {
        images = try ImageEvalSet.build(in: folder)
    } catch {
        fail("couldn't build the image set: \(error.localizedDescription)")
    }
    print("Image set: \(images.count) images in \(folder.path)")
    var facts: [String: FileFacts] = [:]
    for image in images {
        facts[image.file] = await FactExtractor().facts(for: folder.appending(path: image.file))
    }

    var columns: [EvalColumn] = []
    for spec in ModelSpec.visionCandidates {
        let engine = MLXEngine(store: store, vision: spec)
        let writer = VisionCardWriter(model: engine)
        var column = EvalColumn(title: spec.displayName)
        print("\n\(spec.displayName)")
        engine.resetPeakMemory()
        let loadStart = Date()
        do {
            try await engine.load(spec)
        } catch {
            print("  ✗ couldn't load: \(error.localizedDescription)"); continue
        }
        column.loadSeconds = Date().timeIntervalSince(loadStart)
        print("  loaded in \(String(format: "%.1f", column.loadSeconds)) s")
        for image in images {
            guard let imageFacts = facts[image.file] else { continue }
            let start = Date()
            do {
                let outcome = try await writer.ask(for: imageFacts)
                column.add(image, card: outcome.value, tries: outcome.replies.count, seconds: Date().timeIntervalSince(start))
            } catch {
                print("  ✗ \(image.file): \(error.localizedDescription)")
                column.add(image, card: nil, tries: 0, seconds: Date().timeIntervalSince(start))
            }
        }
        column.peak = engine.memory().peak
        await engine.unloadAll()
        columns.append(column)
    }

    // The text model on the OCR text of the document-like images (as for scanned PDFs).
    do {
        let engine = MLXEngine(store: store)
        let classifier = MLXClassifier(model: engine)
        var column = EvalColumn(title: "\(ModelSpec.language.displayName) (OCR text)")
        print("\n\(column.title)")
        engine.resetPeakMemory()
        let loadStart = Date()
        try await engine.load(.language)
        column.loadSeconds = Date().timeIntervalSince(loadStart)
        print("  loaded in \(String(format: "%.1f", column.loadSeconds)) s")
        for image in images where image.isDocument {
            guard let imageFacts = facts[image.file], !(imageFacts.text ?? "").isEmpty else { continue }
            let start = Date()
            let card = try? await classifier.card(for: imageFacts)
            column.add(image, card: card, tries: card == nil ? 0 : 1, seconds: Date().timeIntervalSince(start))
        }
        column.peak = engine.memory().peak
        await engine.unloadAll()
        columns.append(column)
    } catch {
        print("  ✗ \(error.localizedDescription)")
    }

    EvalColumn.printReport(columns, images: images)
    let report = folder.appending(path: "results.json")
    if let data = try? encoder().encode(columns) {
        try? data.write(to: report)
        print("\nCards and timings: \(report.path)")
    }
}

/// A new folder for each run, so nothing is ever replaced.
private func evalFolder() -> URL {
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    return FileManager.default.temporaryDirectory.appending(path: "organizer-image-eval-\(stamp)")
}

/// One model's results over the image set.
struct EvalColumn: Encodable {
    struct Row: Encodable {
        var file: String
        var card: FileCard?
        var kind: Bool
        var fact: Bool
        var name: Bool
        var split: Bool
        var tries: Int
        var seconds: Double
    }

    var title: String
    var loadSeconds: Double = 0
    var peak = 0
    var rows: [String: Row] = [:]
    /// The order images were done in: the first includes compiling the GPU kernels, so it isn't timed.
    var order: [String] = []

    mutating func add(_ image: EvalImage, card: FileCard?, tries: Int, seconds: Double) {
        let score = card.map { ImageEvalSet.score($0, for: image) } ?? EvalScore(kind: false, fact: false, name: false, split: false)
        rows[image.file] = Row(file: image.file, card: card, kind: score.kind, fact: score.fact, name: score.name, split: score.split, tries: tries, seconds: seconds)
        order.append(image.file)
        let mark = { (ok: Bool) in ok ? "✓" : "✗" }
        let line = card.map { "\($0.kind) | \($0.issuer ?? "–") | \($0.subject) | name: \($0.suggestedName)" } ?? "no valid card"
        print("  \(image.file): kind \(mark(score.kind)) fact \(mark(score.fact)) name \(mark(score.name)) split \(mark(score.split)) \(String(format: "%.1f", seconds)) s · \(line)")
    }

    static func printReport(_ columns: [EvalColumn], images: [EvalImage]) {
        let mark = { (row: Row?) -> String in
            guard let row else { return "   –   " }
            return [row.kind, row.fact, row.name, row.split].map { $0 ? "✓" : "✗" }.joined() + " \(String(format: "%4.1f", row.seconds))"
        }
        print("\nResults (kind, key fact, usable name, right way, seconds)")
        print("image".padding(toLength: 26, withPad: " ", startingAt: 0) + columns.map { $0.title.padding(toLength: 24, withPad: " ", startingAt: 0) }.joined())
        for image in images {
            print(image.label.padding(toLength: 26, withPad: " ", startingAt: 0)
                  + columns.map { mark($0.rows[image.file]).padding(toLength: 24, withPad: " ", startingAt: 0) }.joined())
        }
        print("")
        for column in columns {
            let rows = Array(column.rows.values)
            let timed = column.order.dropFirst().compactMap { column.rows[$0]?.seconds }
            let average = timed.isEmpty ? 0 : timed.reduce(0, +) / Double(timed.count)
            let documents = images.filter(\.isDocument).compactMap { column.rows[$0.file] }
            print("\(column.title): kind \(rows.filter(\.kind).count)/\(rows.count), fact \(rows.filter(\.fact).count)/\(rows.count)"
                  + " (documents: kind \(documents.filter(\.kind).count)/\(documents.count), fact \(documents.filter(\.fact).count)/\(documents.count))"
                  + ", name \(rows.filter(\.name).count)/\(rows.count), right way \(rows.filter(\.split).count)/\(rows.count)"
                  + ", valid JSON first try \(rows.filter { $0.tries == 1 }.count)/\(rows.count)"
                  + String(format: ", %.1f s per image, loaded in %.1f s, peak %.1f GB", average, column.loadSeconds, Double(column.peak) / 1e9))
        }
    }
}

import Foundation
import Vision
import UIKit

@MainActor
final class CarouselOCRService {

    /// Where downloaded images go when the embed-images setting is on.
    /// Documents directory under `CarouselImages/` so they're exportable to Obsidian.
    static func imagesDirectory() throws -> URL {
        let docs = try FileManager.default.url(for: .documentDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let dir = docs.appendingPathComponent("CarouselImages", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Process every slide. Returns the same payload with `recognizedText`,
    /// `localImagePath`, and `imageDownloadFailed` filled in.
    func process(
        _ payload: CarouselPayload,
        embedImages: Bool,
        progress: @escaping (Int, Int) -> Void
    ) async -> CarouselPayload {
        var payload = payload
        let total = payload.slides.count
        let postSlug = postSlug(for: payload.postURL)
        let dir = try? Self.imagesDirectory()

        await withTaskGroup(of: (Int, Data?).self) { group in
            var iterator = payload.slides.makeIterator()
            var completed = 0

            func enqueueNext() {
                guard let slide = iterator.next() else { return }
                let imageURL = slide.imageURL
                let index = slide.index
                group.addTask {
                    let data = try? await Self.download(imageURL)
                    return (index, data)
                }
            }
            for _ in 0..<min(4, total) { enqueueNext() }

            while let (index, data) = await group.next() {
                completed += 1
                progress(completed, total)

                guard let data, let image = UIImage(data: data) else {
                    payload.slides[index].imageDownloadFailed = true
                    enqueueNext()
                    continue
                }

                if embedImages, let dir {
                    let filename = String(format: "%@-%02d.jpg", postSlug, index)
                    let dest = dir.appendingPathComponent(filename)
                    try? data.write(to: dest)
                    payload.slides[index].localImagePath = dest
                }

                let text = await Self.runOCR(on: image)
                payload.slides[index].recognizedText = text

                enqueueNext()
            }
        }

        return payload
    }

    private static func download(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    /// Returns concatenated recognized text. Empty string if Vision found nothing.
    /// Nil if Vision errored.
    private static func runOCR(on image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let request = VNRecognizeTextRequest { req, _ in
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let cancelTask = Task.detached {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                request.cancel()
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    cont.resume(returning: nil)
                }
                cancelTask.cancel()
            }
        }
    }

    private func postSlug(for url: URL) -> String {
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        let raw = parts.last ?? "carousel"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars).replacingOccurrences(of: "--", with: "-")
    }
}

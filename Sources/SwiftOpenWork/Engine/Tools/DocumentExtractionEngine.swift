import Foundation
import PDFKit
import Vision
import AppKit

/// High-performance document extractor for macOS leveraging PDFKit and Vision.framework OCR
public final class DocumentExtractionEngine: @unchecked Sendable {
    public static let shared = DocumentExtractionEngine()

    private init() {}

    /// Extracts plain text and structure from a PDF file
    public func extractTextFromPDF(at path: String) -> (text: String, pageCount: Int, error: String?) {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        guard let document = PDFDocument(url: url) else {
            return ("", 0, "Could not open PDF at path: \(path)")
        }

        let pageCount = document.pageCount
        var fullText = ""

        for i in 0..<pageCount {
            if let page = document.page(at: i), let pageString = page.string {
                fullText += "--- [Page \(i + 1) of \(pageCount)] ---\n"
                fullText += pageString.trimmingCharacters(in: .whitespacesAndNewlines)
                fullText += "\n\n"
            }
        }

        if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Scanned PDF with no embedded text layer: fallback to OCR on rendered pages
            fullText = ocrPDFPages(document: document)
        }

        return (fullText, pageCount, nil)
    }

    /// Performs Vision OCR on image files (PNG, JPG, TIFF, WebP, receipts, screenshots)
    public func extractTextFromImage(at path: String) async -> (text: String, error: String?) {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ("", "Could not load image at path: \(path)")
        }

        return await performVisionOCR(cgImage: cgImage)
    }

    private func performVisionOCR(cgImage: CGImage) async -> (text: String, error: String?) {
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(returning: ("", error.localizedDescription))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: ("", "No text detected in image"))
                    return
                }

                var recognizedStrings: [String] = []
                for observation in observations {
                    if let topCandidate = observation.topCandidates(1).first {
                        recognizedStrings.append(topCandidate.string)
                    }
                }

                let result = recognizedStrings.joined(separator: "\n")
                continuation.resume(returning: (result, nil))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US", "fr-FR", "es-ES", "de-DE", "zh-Hans"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: ("", error.localizedDescription))
            }
        }
    }

    private func ocrPDFPages(document: PDFDocument) -> String {
        var ocrResult = ""
        let count = min(document.pageCount, 10) // Limit to first 10 pages for speed

        for i in 0..<count {
            guard let page = document.page(at: i) else { continue }
            let pageRect = page.bounds(for: .mediaBox)
            let img = NSImage(size: pageRect.size, flipped: false) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.setFillColor(NSColor.white.cgColor)
                context.fill(rect)
                page.draw(with: .mediaBox, to: context)
                return true
            }

            if let cgImage = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
                if let observations = request.results {
                    let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                    ocrResult += "--- [Page \(i + 1) (OCR)] ---\n" + lines.joined(separator: "\n") + "\n\n"
                }
            }
        }

        return ocrResult
    }
}

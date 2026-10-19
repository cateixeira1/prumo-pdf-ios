import CoreText
import Foundation
import PDFKit
import Vision

struct OCRSettings {
    var languages: [String] = ["pt-BR"]
    var maxConcurrent = 2
    /// Lado maior da imagem enviada ao OCR (3000 px ≈ 250 DPI numa folha A4).
    var renderLongSide: CGFloat = 3000
}

struct RecognizedLine: Sendable {
    let text: String
    let box: CGRect        // normalizado (0 a 1), origem no canto inferior esquerdo
    let confidence: Float
}

struct OCRPageReport: Codable, Equatable {
    var page: Int
    var confidence: Double?      // média ponderada por caracteres (0 a 1)
    var lowConfidenceShare: Double?
    var characters: Int
    var needsReview: Bool
}

struct OCRReport {
    var totalPages: Int
    var ocrPages: [Int]          // páginas que receberam texto
    var skippedPages: [Int]      // já tinham texto
    var emptyPages: [Int]        // passaram pelo OCR, mas nada foi reconhecido
    var pages: [OCRPageReport]
    var hadSignature: Bool

    var reviewPages: [Int] { pages.filter(\.needsReview).map(\.page) }
    var averageConfidence: Double? {
        let values = pages.compactMap(\.confidence)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

enum OCRError: LocalizedError {
    case nothingToDo
    var errorDescription: String? {
        "Todas as páginas já têm texto selecionável. O OCR não é necessário."
    }
}

/// OCR feito inteiramente no iPhone com o Vision, da Apple.
/// Páginas com texto digital ficam intactas. Nas páginas em imagem, a página original é
/// redesenhada sem alterações e recebe por cima uma camada de texto invisível, pesquisável e copiável.
final class OCRService {

    /// Critérios para marcar uma página como "revisar". São indicativos: a confiança é a do próprio motor.
    static let reviewMinConfidence = 0.65
    static let reviewMaxLowShare = 0.20

    func run(input: URL, output: URL, settings: OCRSettings = OCRSettings(),
             progress: @escaping (_ done: Int, _ total: Int) -> Void) async throws -> OCRReport {
        let doc = try PDFOps.open(input)
        let pageCount = doc.pageCount

        var candidates: [(index: Int, kind: PageKind)] = []
        var hadSignature = false
        for i in 0..<pageCount {
            guard let page = doc.page(at: i) else { continue }
            if page.annotations.contains(where: { $0.widgetFieldType == .signature }) { hadSignature = true }
            let kind = Analyzer.classify(page: page)
            if kind.needsOCR { candidates.append((i, kind)) }
        }
        guard !candidates.isEmpty else { throw OCRError.nothingToDo }

        progress(0, candidates.count)
        var results: [Int: [RecognizedLine]] = [:]
        let languages = settings.languages
        let longSide = settings.renderLongSide
        let maxConcurrent = max(1, settings.maxConcurrent)

        try await withThrowingTaskGroup(of: (Int, [RecognizedLine]).self) { group in
            var inFlight = 0
            var done = 0
            for candidate in candidates {
                try Task.checkCancellation()
                let index = candidate.index
                // A renderização usa o PDFKit e fica nesta tarefa; só o Vision roda em paralelo.
                guard let page = doc.page(at: index),
                      let image = PageRenderer.render(page, longSide: longSide) else {
                    results[index] = []
                    done += 1
                    progress(done, candidates.count)
                    continue
                }
                group.addTask {
                    try Task.checkCancellation()
                    return (index, try OCRService.recognize(image, languages: languages))
                }
                inFlight += 1
                if inFlight >= maxConcurrent, let r = try await group.next() {
                    results[r.0] = r.1
                    inFlight -= 1
                    done += 1
                    progress(done, candidates.count)
                }
            }
            for try await r in group {
                results[r.0] = r.1
                done += 1
                progress(done, candidates.count)
            }
        }
        try Task.checkCancellation()

        var keepAlive: [PDFDocument] = []
        var ocrPages: [Int] = []
        var emptyPages: [Int] = []
        var reports: [OCRPageReport] = []

        for candidate in candidates {
            try Task.checkCancellation()
            guard let page = doc.page(at: candidate.index) else { continue }
            var lines = results[candidate.index] ?? []
            if candidate.kind == .imageWithStamp {
                lines = lines.filter { !TextLayerWriter.overlapsExistingText($0, on: page) }
            }
            let chars = lines.reduce(0) { $0 + PDFOps.usefulCharacterCount($1.text) }
            guard chars > 0 else {
                emptyPages.append(candidate.index + 1)
                continue
            }
            guard let single = TextLayerWriter.makePage(from: page, lines: lines),
                  let newPage = single.page(at: 0)?.copy() as? PDFPage else { continue }
            keepAlive.append(single)
            doc.removePage(at: candidate.index)
            doc.insert(newPage, at: candidate.index)
            ocrPages.append(candidate.index + 1)
            reports.append(Self.pageReport(page: candidate.index + 1, lines: lines))
        }

        guard !ocrPages.isEmpty || !emptyPages.isEmpty else { throw OCRError.nothingToDo }
        try PDFOps.write(doc, to: output)
        _ = keepAlive.count

        let ocrSet = Set(candidates.map { $0.index + 1 })
        let skipped = (1...max(pageCount, 1)).filter { !ocrSet.contains($0) && $0 <= pageCount }
        return OCRReport(totalPages: pageCount, ocrPages: ocrPages, skippedPages: skipped,
                         emptyPages: emptyPages, pages: reports, hadSignature: hadSignature)
    }

    static func recognize(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            let text = top.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return RecognizedLine(text: text, box: obs.boundingBox, confidence: top.confidence)
        }
    }

    static func pageReport(page: Int, lines: [RecognizedLine]) -> OCRPageReport {
        var weighted = 0.0
        var total = 0
        var low = 0
        for line in lines {
            let n = PDFOps.usefulCharacterCount(line.text)
            weighted += Double(line.confidence) * Double(n)
            total += n
            if line.confidence <= 0.5 { low += n }
        }
        guard total > 0 else {
            return OCRPageReport(page: page, confidence: nil, lowConfidenceShare: nil, characters: 0, needsReview: true)
        }
        let avg = weighted / Double(total)
        let share = Double(low) / Double(total)
        return OCRPageReport(page: page, confidence: avg, lowConfidenceShare: share, characters: total,
                             needsReview: avg < reviewMinConfidence || share > reviewMaxLowShare)
    }
}

/// Desenha páginas de PDF em imagens, respeitando a rotação e a área visível da página.
enum PageRenderer {

    static func displaySize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let rotation = PDFOps.normalized(Int(page.rotationAngle))
        return (rotation == 90 || rotation == 270) ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Transformação do espaço da página para o retângulo de exibição (origem 0,0).
    static func displayTransform(of page: CGPDFPage) -> CGAffineTransform {
        let size = displaySize(of: page)
        return page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                        rotate: 0, preserveAspectRatio: true)
    }

    static func render(_ page: PDFPage, longSide: CGFloat, maxPixels: CGFloat = 12_000_000) -> CGImage? {
        guard let cg = page.pageRef else { return nil }
        let size = displaySize(of: cg)
        guard size.width > 1, size.height > 1 else { return nil }
        var scale = longSide / max(size.width, size.height)
        let pixels = size.width * size.height * scale * scale
        if pixels > maxPixels { scale *= sqrt(maxPixels / pixels) }
        let w = Int((size.width * scale).rounded())
        let h = Int((size.height * scale).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(displayTransform(of: cg))
        ctx.clip(to: cg.getBoxRect(.cropBox))
        ctx.drawPDFPage(cg)
        return ctx.makeImage()
    }
}

/// Monta a página com a camada de texto invisível.
enum TextLayerWriter {

    static func makePage(from page: PDFPage, lines: [RecognizedLine]) -> PDFDocument? {
        guard let cg = page.pageRef else { return nil }
        let size = PageRenderer.displaySize(of: cg)
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.saveGState()
        ctx.concatenate(PageRenderer.displayTransform(of: cg))
        ctx.clip(to: cg.getBoxRect(.cropBox))
        ctx.drawPDFPage(cg)
        ctx.restoreGState()
        drawInvisibleText(lines, in: ctx, size: size)
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)
    }

    static func drawInvisibleText(_ lines: [RecognizedLine], in ctx: CGContext, size: CGSize) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        for line in lines {
            let rect = CGRect(x: line.box.minX * size.width, y: line.box.minY * size.height,
                              width: line.box.width * size.width, height: line.box.height * size.height)
            guard rect.width > 1, rect.height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, max(1, rect.height), nil)
            let attributed = NSAttributedString(string: line.text, attributes: [fontKey: font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
            let height = ascent + descent
            guard width > 0, height > 0 else { continue }
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: rect.minX, y: rect.minY)
            ctx.scaleBy(x: rect.width / width, y: rect.height / height)
            ctx.textPosition = CGPoint(x: 0, y: descent)
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// True se o trecho reconhecido já existe como texto digital na página (ex.: rodapé do PJe).
    static func overlapsExistingText(_ line: RecognizedLine, on page: PDFPage) -> Bool {
        guard let cg = page.pageRef else { return false }
        let size = PageRenderer.displaySize(of: cg)
        let displayRect = CGRect(x: line.box.minX * size.width, y: line.box.minY * size.height,
                                 width: line.box.width * size.width, height: line.box.height * size.height)
        let pageRect = displayRect.applying(PageRenderer.displayTransform(of: cg).inverted())
        let existing = page.selection(for: pageRect)?.string ?? ""
        let existingChars = PDFOps.usefulCharacterCount(existing)
        let recognizedChars = PDFOps.usefulCharacterCount(line.text)
        return recognizedChars > 0 && Double(existingChars) >= 0.5 * Double(recognizedChars)
    }
}

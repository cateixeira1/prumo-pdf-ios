import PDFKit
import UIKit
import XCTest
@testable import PrumoPDF

/// Comprimir PDF, média e alta (versão 1.13.0). Os PDFs gerados também vão para o CI conferir com o qpdf
/// (estrutura do arquivo regravado), fora do simulador.
@MainActor
final class CompressTests: XCTestCase {
    private var base: URL!

    override func setUp() {
        base = TestPDF.tempDir()
    }

    override func tearDown() {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    private func keep(_ url: URL, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["PRUMO_COMPRESSED_OUT"], !dir.isEmpty else { return }
        let dest = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
    }

    /// Página "escaneada" a 200 dpi (A4 = 1654 × 2339 px), com grão de papel, desenhada na página inteira.
    private func scanImage() -> UIImage {
        let w = 1654, h = 2339
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt32 = 12345
        for y in 0..<h {
            for x in 0..<w {
                seed = seed &* 1_103_515_245 &+ 12_345
                let grain = Int((seed >> 16) & 0x1F)
                let ink = (y / 40) % 3 == 0 && x > 150 && x < 1500 && (x / 9) % 4 != 0
                let v = UInt8(clamping: (ink ? 40 : 235) - grain)
                let o = (y * w + x) * 4
                px[o] = v
                px[o + 1] = UInt8(clamping: Int(v) - 6)
                px[o + 2] = UInt8(clamping: Int(v) - 14)
                px[o + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(px) as CFData)!
        let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return UIImage(cgImage: cg)
    }

    private func scanPDF(_ url: URL, pages: Int) {
        let image = scanImage()
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            for _ in 0..<pages {
                ctx.beginPage()
                image.draw(in: CGRect(x: 0, y: 0, width: 595, height: 842))
            }
        }
        try? data.write(to: url)
    }

    /// Larguras das imagens do PDF (sem as máscaras).
    private func imageWidths(_ url: URL) throws -> [Int] {
        let file = try PDFFile(Data(contentsOf: url))
        var masks = Set<Int>()
        var found: [(Int, Int)] = []
        for n in 1..<file.size {
            guard case .stream(let d, _) = try file.object(n), d["Subtype"]?.nameValue == "Image" else { continue }
            if let m = d["SMask"]?.refValue { masks.insert(m.0) }
            found.append((n, d["Width"]?.intValue ?? 0))
        }
        return found.filter { !masks.contains($0.0) }.map { $0.1 }
    }

    func testScanMediumAndHigh() throws {
        let src = base.appendingPathComponent("scan.pdf")
        scanPDF(src, pages: 2)
        let m = base.appendingPathComponent("media.pdf"), h = base.appendingPathComponent("alta.pdf")
        var steps: [(Int, Int)] = []
        let med = try PDFCompressor.compress(src, to: m, level: .medium, progress: { steps.append(($0, $1)) })
        let high = try PDFCompressor.compress(src, to: h, level: .high)
        print("Tamanho: original \(med.before), média \(med.after), alta \(high.after)")
        // a página de teste tem grão aleatório forte (o pior caso para o JPEG): no CI, média −40%, alta −77%
        XCTAssertLessThan(Double(med.after), Double(med.before) * 0.75, "200 → 150 dpi e JPEG: bem menor")
        XCTAssertLessThan(Double(high.after), Double(med.before) * 0.4, "alta: bem menor")
        XCTAssertLessThan(high.after, med.after, "a alta reduz mais que a média")
        XCTAssertGreaterThanOrEqual(med.imagesChanged, 1)
        XCTAssertEqual(steps.last?.0, steps.last?.1)
        // A4 = 8,27 pol: 150 dpi ≈ 1240 px; 96 dpi ≈ 794 px
        for w in try imageWidths(m) where w > 100 { XCTAssert((1200...1280).contains(w), "média: \(w)") }
        for w in try imageWidths(h) where w > 100 { XCTAssert((760...830).contains(w), "alta: \(w)") }
        for url in [m, h] {
            let doc = try XCTUnwrap(PDFDocument(url: url), "o PDF comprimido abre")
            XCTAssertEqual(doc.pageCount, 2)
            XCTAssertNotNil(doc.page(at: 1)?.thumbnail(of: CGSize(width: 200, height: 280), for: .mediaBox))
        }
        keep(src, "scan-original.pdf")
        keep(m, "scan-media.pdf")
        keep(h, "scan-alta.pdf")
    }

    func testTextIsKept() throws {
        let src = base.appendingPathComponent("texto.pdf")
        _ = TestPDF.digital(pages: 3).write(to: src)
        let out = base.appendingPathComponent("texto-alta.pdf")
        _ = try PDFCompressor.compress(src, to: out, level: .high)
        let doc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(TestPDF.markers(doc), ["MARCADOR-A-1", "MARCADOR-A-2", "MARCADOR-A-3"],
                       "o texto continua selecionável depois de regravar o arquivo")
        keep(out, "texto-alta.pdf")
    }

    func testHighlightsAreKept() throws {
        let doc = TestPDF.digital(pages: 1)
        let page = try XCTUnwrap(doc.page(at: 0))
        let mark = PDFAnnotation(bounds: CGRect(x: 60, y: 700, width: 200, height: 20), forType: .highlight, withProperties: nil)
        mark.color = .yellow
        page.addAnnotation(mark)
        let src = base.appendingPathComponent("destaque.pdf")
        XCTAssertTrue(doc.write(to: src))
        let out = base.appendingPathComponent("destaque-media.pdf")
        _ = try PDFCompressor.compress(src, to: out, level: .medium)
        let again = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertTrue(again.page(at: 0)?.annotations.contains { $0.type == "Highlight" } == true)
        keep(out, "destaque-media.pdf")
    }

    func testLibraryCreatesCopyAndKeepsOriginal() async throws {
        let library = Library(baseDirectory: base.appendingPathComponent("lib"))
        let src = base.appendingPathComponent("Laudo.pdf")
        scanPDF(src, pages: 1)
        let item = try XCTUnwrap(library.importFiles([src]).first)
        let before = try Data(contentsOf: item.url)
        let done = try await library.compressedCopy(item, level: .high)
        let (copy, result) = try XCTUnwrap(done)
        XCTAssertEqual(copy.name, "Laudo - comprimido")
        XCTAssertEqual(copy.folder, item.folder)
        XCTAssertLessThan(result.after, result.before)
        XCTAssertEqual(try Data(contentsOf: item.url), before, "o original não muda")
        XCTAssertEqual(AppLanguages.stripSuffix("Laudo - compressed", template: "{} - comprimido"), "Laudo",
                       "cópia criada em outro idioma (ex.: no Windows em inglês)")
    }

    func testPasswordPDFIsRefused() throws {
        let library = Library(baseDirectory: base.appendingPathComponent("lib2"))
        let src = base.appendingPathComponent("Contrato.pdf")
        _ = TestPDF.digital(pages: 1).write(to: src)
        let item = try XCTUnwrap(library.importFiles([src]).first)
        let locked = try library.protect(item, password: "Sigilo2026")
        XCTAssertThrowsError(try PDFCompressor.compress(locked.url, to: base.appendingPathComponent("x.pdf"), level: .medium))
    }
}

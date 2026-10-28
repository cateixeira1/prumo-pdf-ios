import PDFKit
import UIKit
import Vision
import XCTest
@testable import PrumoPDF

/// Correção de páginas curvas com o modelo UVDoc (versão 1.5.0).
final class DewarpTests: XCTestCase {
    static let sentence = "A autora foi internada para cirurgia eletiva e apresentou febre persistente durante a noite"

    /// Página com texto sobre fundo cinza (como uma foto), em 1500 × 2000.
    static func page() -> UIImage {
        let size = CGSize(width: 1500, height: 2000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.45, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 110, y: 110, width: 1280, height: 1780))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 27), .foregroundColor: UIColor.black]
            for line in 0..<30 {
                (sentence as NSString).draw(at: CGPoint(x: 170, y: 190 + CGFloat(line) * 52), withAttributes: attrs)
            }
        }
    }

    /// Grade sintética que "curva" a imagem como uma página perto da lombada.
    static func curlGrid() -> [Float] {
        let rows = Dewarp.rows, cols = Dewarp.cols
        var g = [Float](repeating: 0, count: 2 * rows * cols)
        for i in 0..<rows {
            for j in 0..<cols {
                let u = Float(j) / Float(cols - 1), v = Float(i) / Float(rows - 1)
                let bend = 0.10 * sin(Float.pi * u) * (0.6 + 0.4 * v)
                g[i * cols + j] = (u * 2 - 1) * 1.04
                g[rows * cols + i * cols + j] = ((v - bend * (1 - u)) * 2 - 1) * 1.04
            }
        }
        return g
    }

    static func recognizedWords(_ image: UIImage) throws -> Int {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["pt-BR"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image.cgImage!, options: [:]).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        let expected = Set(sentence.lowercased().split(separator: " ").map(String.init))
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.filter { expected.contains($0) }.count
    }

    func testModelIsBundledAndPredictsGrid() throws {
        XCTAssertTrue(Dewarp.isAvailable, "o modelo UVDoc está no app")
        let grid = try Dewarp.predictGrid(Self.page().cgImage!)
        XCTAssertEqual(grid.count, 2 * 45 * 31)
        XCTAssertTrue(grid.allSatisfy { $0 > -1.3 && $0 < 1.3 })
    }

    func testCurvedPageReadsBetterAfterCorrection() throws {
        let flat = Self.page()
        let curved = UIImage(cgImage: try XCTUnwrap(Dewarp.remap(flat.cgImage!, grid: Self.curlGrid())))
        let fixed = try Dewarp.unwarp(curved)
        XCTAssertEqual(fixed.cgImage?.width, curved.cgImage?.width)
        let before = try Self.recognizedWords(curved)
        let after = try Self.recognizedWords(fixed)
        print("Curvatura: palavras reconhecidas antes \(before), depois \(after)")
        XCTAssertGreaterThanOrEqual(after, before)
        XCTAssertGreaterThan(after, 150, "a maior parte do texto é lida depois da correção")
    }

    func testDewarpPDFKeepsOtherPages() throws {
        let doc = PDFDocument()
        let digital = TestPDF.digital(pages: 1)
        doc.insert(try XCTUnwrap(digital.page(at: 0)), at: 0)
        let curved = UIImage(cgImage: try XCTUnwrap(Dewarp.remap(Self.page().cgImage!, grid: Self.curlGrid())))
        doc.insert(try XCTUnwrap(PDFPage(image: curved)), at: 1)
        let data = try Dewarp.dewarpPDF(doc, pages: [2])
        let out = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(out.pageCount, 2)
        XCTAssertEqual(out.page(at: 0)?.string, digital.page(at: 0)?.string, "a página não escolhida fica igual")
    }
}

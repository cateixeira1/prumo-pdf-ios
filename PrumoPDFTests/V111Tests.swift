import PDFKit
import UIKit
import XCTest
@testable import PrumoPDF

/// Versão 1.11.0: carimbo da assinatura sem texto espremido e numeração que não se sobrepõe.
final class V111Tests: XCTestCase {
    func testStampLayoutFitsLongUppercaseName() {
        let date = "em 02/11/2026 14:52:00"
        let innerW = PDFSigner.stampSize.width - 2 * PDFSigner.stampPadX
        let innerH = PDFSigner.stampSize.height - 2 * PDFSigner.stampPadY
        for name in ["ANA", "JOSÉ DA CONCEIÇÃO ANTÔNIO", "MARIA APARECIDA DE FÁTIMA SOUZA DOS SANTOS OLIVEIRA LIMA"] {
            let l = PDFSigner.stampLayout(name: name, dateText: date)
            for line in l.lines {
                XCTAssertLessThanOrEqual(PDFSigner.textWidth(line, size: l.size), innerW + 0.01, "\(name): \(line)")
            }
            XCTAssertLessThanOrEqual(CGFloat(l.lines.count) * l.lead, innerH + 0.01, name)
        }
        let long = PDFSigner.stampLayout(name: "MARIA APARECIDA DE FÁTIMA SOUZA DOS SANTOS OLIVEIRA LIMA", dateText: date)
        XCTAssertGreaterThanOrEqual(long.lines.count, 4, "nome longo quebra em duas linhas")
    }

    /// Duas páginas com o número já impresso embaixo, no centro, e uma sem.
    private func pdfWithPrintedNumbers() throws -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let data = renderer.pdfData { ctx in
            for n in 1...3 {
                ctx.beginPage()
                "Texto da página \(n)".draw(at: CGPoint(x: 60, y: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
                if n <= 2 {
                    "\(n)".draw(at: CGPoint(x: 296, y: 842 - 28.3 - 10), withAttributes: [.font: UIFont.systemFont(ofSize: 10)])
                }
            }
        }
        return try XCTUnwrap(PDFDocument(data: data))
    }

    func testNumberingMovesOffPrintedNumbers() throws {
        let doc = try pdfWithPrintedNumbers()
        var o = PageTools.NumberOptions()
        o.format = .n
        o.position = .bottomCenter
        let result = try PageTools.numberedResult(doc, options: o)
        XCTAssertEqual(result.report.moved, [1, 2], "o número sai do lugar nas páginas com número impresso")
        XCTAssertTrue(result.report.crowded.isEmpty)
        let numbered = try XCTUnwrap(PDFDocument(data: result.data))
        XCTAssertEqual(numbered.pageCount, 3)
        XCTAssertTrue((numbered.page(at: 2)?.string ?? "").contains("3"))
    }

    func testNumberingOnCleanPagesDoesNotMove() throws {
        let doc = TestPDF.digital(pages: 3)
        var o = PageTools.NumberOptions()
        o.position = .topRight
        let result = try PageTools.numberedResult(doc, options: o)
        XCTAssertTrue(result.report.moved.isEmpty)
    }

    func testOCRLanguageSelection() {
        XCTAssertEqual(OCRLanguage.parse("por+eng"), ["por", "eng"])
        XCTAssertEqual(OCRLanguage.parse("xxx"), ["por"])
        XCTAssertEqual(OCRLanguage.parse(nil), ["por"])
        XCTAssertEqual(OCRLanguage.join(["deu", "fra", "deu", "spa", "jpn", "fin"]), "deu+fra+spa+jpn")
        let ids = Set(OCRLanguage.all.map(\.id))
        XCTAssertTrue(["deu", "fra", "spa", "eng", "jpn", "chi_sim", "chi_tra", "nor", "swe", "dan", "fin"].allSatisfy(ids.contains))
        // O que o aparelho não reconhece (sueco aqui) não vai para o Vision.
        let supported = ["pt-BR", "en-US", "de-DE", "fr-FR", "es-ES", "ja-JP", "zh-Hans", "zh-Hant"]
        XCTAssertEqual(OCRLanguage.visionCodes(stored: "por+swe+deu+fin", supported: supported), ["pt-BR", "de-DE"])
        XCTAssertEqual(OCRLanguage.visionCodes(stored: "swe", supported: supported), ["pt-BR"], "sempre sobra algum idioma")
        XCTAssertTrue(OCRLanguage.unavailable(supported: supported).map(\.id).contains("swe"))
    }

    func testTranslationsAreBundled() throws {
        let bundle = Bundle(for: Library.self)
        for lproj in AppLanguages.all.map(\.lproj) where lproj != "pt-BR" {
            let path = try XCTUnwrap(bundle.path(forResource: lproj, ofType: "lproj"), "falta \(lproj).lproj")
            let b = try XCTUnwrap(Bundle(path: path))
            XCTAssertNotEqual(b.localizedString(forKey: "Sem OCR", value: nil, table: nil), "Sem OCR", lproj)
        }
        let en = try XCTUnwrap(Bundle(path: try XCTUnwrap(bundle.path(forResource: "en", ofType: "lproj"))))
        XCTAssertEqual(en.localizedString(forKey: "Sem OCR", value: nil, table: nil), "No OCR")
    }
}

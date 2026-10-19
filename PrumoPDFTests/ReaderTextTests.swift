import PDFKit
import XCTest
@testable import PrumoPDF

final class ReaderTextTests: XCTestCase {

    private func line(_ text: String, y: CGFloat, width: CGFloat = 400, height: CGFloat = 14) -> TextLine {
        TextLine(text: text, rect: CGRect(x: 60, y: y, width: width, height: height))
    }

    func testReflowJoinsLinesAndSplitsParagraphs() {
        let lines = [
            line("EXCELENTÍSSIMO SENHOR DOUTOR JUIZ", y: 780, width: 300),
            line("A autora vem propor a presente ação de inde-", y: 760),
            line("nização por danos materiais e morais em face", y: 744),
            line("do hospital réu.", y: 728, width: 120),
            line("Os fatos são os seguintes, conforme o prontuário", y: 690),
            line("anexado aos autos.", y: 674, width: 140),
            line("1. Primeiro pedido", y: 658, width: 150),
        ]
        let paragraphs = ReaderTextBuilder.reflow(lines)
        XCTAssertEqual(paragraphs, [
            "EXCELENTÍSSIMO SENHOR DOUTOR JUIZ",
            "A autora vem propor a presente ação de indenização por danos materiais e morais em face do hospital réu.",
            "Os fatos são os seguintes, conforme o prontuário anexado aos autos.",
            "1. Primeiro pedido",
        ])
    }

    func testReflowWithoutPositions() {
        let lines = ["Primeira linha do parágrafo", "continua aqui.", "Novo parágrafo começa."]
            .map { TextLine(text: $0, rect: .null) }
        XCTAssertEqual(ReaderTextBuilder.reflow(lines),
                       ["Primeira linha do parágrafo continua aqui.", "Novo parágrafo começa."])
    }

    func testReaderTextFromOCRResult() async throws {
        let dir = TestPDF.tempDir()
        let input = dir.appendingPathComponent("scan.pdf")
        let output = dir.appendingPathComponent("scan - OCR.pdf")
        XCTAssertTrue(TestPDF.scanned(pages: 2).write(to: input))
        _ = try await OCRService().run(input: input, output: output) { _, _ in }

        let reader = try XCTUnwrap(ReaderTextBuilder.build(url: output))
        XCTAssertEqual(reader.pages.count, 2)
        let page1 = reader.pages[0].paragraphs.map { Library.fold($0) }
        print("Modo leitor, página 1: \(reader.pages[0].paragraphs)")
        XCTAssertEqual(page1.first, "excelentissimo senhor doutor juiz de direito", "o título fica separado")
        XCTAssertTrue(page1.contains { $0.contains("acao de indenizacao por danos materiais") },
                      "as linhas da mesma frase são juntadas: \(page1)")
        XCTAssertTrue(reader.plainText.contains("— Página 2 —"))
        XCTAssertFalse(reader.isEmpty)
    }

    func testScannedPDFWithoutOCRHasNoText() {
        let reader = ReaderTextBuilder.build(TestPDF.scanned(pages: 1))
        XCTAssertTrue(reader.isEmpty)
    }
}

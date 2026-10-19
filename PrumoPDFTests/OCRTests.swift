import PDFKit
import XCTest
@testable import PrumoPDF

final class OCRTests: XCTestCase {

    private func fold(_ s: String) -> String { Library.fold(s) }

    func testScannedPagesGetSearchableText() async throws {
        let dir = TestPDF.tempDir()
        let input = dir.appendingPathComponent("scan.pdf")
        let output = dir.appendingPathComponent("scan - OCR.pdf")
        XCTAssertTrue(TestPDF.scanned(pages: 2).write(to: input))
        let inputSize = (try FileManager.default.attributesOfItem(atPath: input.path)[.size] as? Int) ?? 0

        var progressCalls = 0
        let report = try await OCRService().run(input: input, output: output) { _, _ in progressCalls += 1 }

        XCTAssertEqual(report.ocrPages, [1, 2])
        XCTAssertGreaterThan(progressCalls, 0)
        let doc = try PDFOps.open(output)
        XCTAssertEqual(doc.pageCount, 2)
        let text = fold(doc.page(at: 0)?.string ?? "")
        print("Texto reconhecido (página 1): \(text)")
        XCTAssertTrue(text.contains("excelentissimo senhor doutor"), text)
        XCTAssertTrue(text.contains("indenizacao"), text)
        XCTAssertTrue(text.contains("150.000,00"), text)
        // O tamanho do resultado deve continuar na mesma ordem de grandeza do original.
        let outputSize = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        print("Tamanho: original \(inputSize) bytes, com OCR \(outputSize) bytes")
        XCTAssertLessThan(outputSize, max(inputSize, 1) * 3)
        print("Confiança média: \(report.averageConfidence ?? -1); revisar: \(report.reviewPages)")
        // Uma busca no PDF encontra o texto (como no leitor).
        XCTAssertFalse(doc.findString("hospital", withOptions: .caseInsensitive).isEmpty)
    }

    func testDigitalPagesAreUntouched() async throws {
        let dir = TestPDF.tempDir()
        let input = dir.appendingPathComponent("misto.pdf")
        let output = dir.appendingPathComponent("misto - OCR.pdf")
        let doc = TestPDF.digital(pages: 2)
        PDFOps.insert(pages: [1], from: TestPDF.scanned(pages: 1), into: doc, at: .end)
        XCTAssertTrue(doc.write(to: input))

        let report = try await OCRService().run(input: input, output: output) { _, _ in }
        XCTAssertEqual(report.ocrPages, [3])
        XCTAssertEqual(report.skippedPages, [1, 2])
        let result = try PDFOps.open(output)
        XCTAssertEqual(TestPDF.markers(result).prefix(2), ["MARCADOR-A-1", "MARCADOR-A-2"])
        XCTAssertTrue(fold(result.page(at: 2)?.string ?? "").contains("prontuario"))
    }

    func testDigitalOnlyDocumentReportsNothingToDo() async throws {
        let dir = TestPDF.tempDir()
        let input = dir.appendingPathComponent("digital.pdf")
        XCTAssertTrue(TestPDF.digital(pages: 2).write(to: input))
        do {
            _ = try await OCRService().run(input: input, output: dir.appendingPathComponent("x.pdf")) { _, _ in }
            XCTFail("deveria informar que o OCR não é necessário")
        } catch {
            XCTAssertTrue(error is OCRError)
        }
    }

    /// Página escaneada com rodapé digital (como as do PJe): o OCR entra, mas o rodapé não é duplicado.
    func testScannedPageWithDigitalStampKeepsStampOnce() async throws {
        let dir = TestPDF.tempDir()
        let input = dir.appendingPathComponent("pje.pdf")
        let output = dir.appendingPathComponent("pje - OCR.pdf")
        let stamp = "Assinado eletronicamente por: FULANO DE TAL - Documento ID 98765432"
        let image = TestPDF.scanImage()
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595.28, height: 841.89)).pdfData { ctx in
            ctx.beginPage()
            ScanService.prepare(image)?.draw(in: CGRect(x: 0, y: 0, width: 595.28, height: 841.89))
            stamp.draw(at: CGPoint(x: 40, y: 815), withAttributes: [.font: UIFont.systemFont(ofSize: 7)])
        }
        try data.write(to: input)
        let page = try XCTUnwrap(PDFDocument(url: input)?.page(at: 0))
        XCTAssertEqual(Analyzer.classify(page: page), .imageWithStamp)

        let report = try await OCRService().run(input: input, output: output) { _, _ in }
        XCTAssertEqual(report.ocrPages, [1])
        let text = try XCTUnwrap(PDFOps.open(output).page(at: 0)?.string)
        XCTAssertTrue(fold(text).contains("indenizacao"), text)
        let occurrences = fold(text).components(separatedBy: "98765432").count - 1
        XCTAssertEqual(occurrences, 1, "o rodapé digital não pode aparecer duas vezes: \(text)")
    }

    func testCancellation() async throws {
        let dir = TestPDF.tempDir()
        let input = dir.appendingPathComponent("grande.pdf")
        XCTAssertTrue(TestPDF.scanned(pages: 6).write(to: input))
        let task = Task {
            try await OCRService().run(input: input, output: dir.appendingPathComponent("out.pdf")) { _, _ in }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("deveria ter sido cancelado")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("out.pdf").path))
    }
}

import PDFKit
import XCTest
@testable import PrumoPDF

final class PageSelectionTests: XCTestCase {
    func testParsesNumbersRangesAndEnd() throws {
        XCTAssertEqual(try PageSelection.parse("1, 3-5; 8-fim", pageCount: 10), [1, 3, 4, 5, 8, 9, 10])
        XCTAssertEqual(try PageSelection.parse(" 5 - 15 ", pageCount: 20), Array(5...15))
        XCTAssertEqual(try PageSelection.parse("fim", pageCount: 7), [7])
        XCTAssertEqual(try PageSelection.parse("2,2,2", pageCount: 3), [2])
        XCTAssertEqual(try PageSelection.parse("3–4", pageCount: 5), [3, 4]) // travessão
    }

    func testRejectsInvalidInput() {
        XCTAssertThrowsError(try PageSelection.parse("0", pageCount: 5))
        XCTAssertThrowsError(try PageSelection.parse("2-12", pageCount: 10))
        XCTAssertThrowsError(try PageSelection.parse("5-3", pageCount: 10))
        XCTAssertThrowsError(try PageSelection.parse("abc", pageCount: 10))
        XCTAssertThrowsError(try PageSelection.parse("   ", pageCount: 10))
    }

    func testFormat() {
        XCTAssertEqual(PageSelection.format([1, 2, 3, 5, 7, 8]), "1-3, 5, 7-8")
        XCTAssertEqual(PageSelection.format([4]), "4")
        XCTAssertEqual(PageSelection.format([]), "")
        XCTAssertEqual(PageSelection.format([9, 1, 2]), "1-2, 9")
    }
}

final class SplitPlanTests: XCTestCase {
    func testEqualParts() throws {
        XCTAssertEqual(try SplitPlan.sizes(pageCount: 200, parts: 4), [50, 50, 50, 50])
    }

    func testRemainderGoesToFirstParts() throws {
        XCTAssertEqual(try SplitPlan.sizes(pageCount: 200, parts: 3), [67, 67, 66])
        XCTAssertEqual(try SplitPlan.sizes(pageCount: 10, parts: 4), [3, 3, 2, 2])
        XCTAssertEqual(try SplitPlan.ranges(pageCount: 10, parts: 3), [1...4, 5...7, 8...10])
    }

    func testInvalidParts() {
        XCTAssertThrowsError(try SplitPlan.sizes(pageCount: 3, parts: 4))
        XCTAssertThrowsError(try SplitPlan.sizes(pageCount: 10, parts: 1))
    }

    func testSummary() {
        XCTAssertEqual(SplitPlan.summary(pageCount: 200, parts: 4), "4 partes de 50 páginas")
        XCTAssertEqual(SplitPlan.summary(pageCount: 200, parts: 3), "3 partes: 67, 67 e 66 páginas")
    }
}

final class PDFOpsTests: XCTestCase {
    func testInsertSelectedPagesAfterPosition() {
        let target = TestPDF.digital(pages: 4, prefix: "A")
        let source = TestPDF.digital(pages: 20, prefix: "B")
        let added = PDFOps.insert(pages: try! PageSelection.parse("5-7, 10", pageCount: 20),
                                  from: source, into: target, at: .after(2))
        XCTAssertEqual(added, 4)
        XCTAssertEqual(TestPDF.markers(target),
                       ["MARCADOR-A-1", "MARCADOR-A-2", "MARCADOR-B-5", "MARCADOR-B-6", "MARCADOR-B-7",
                        "MARCADOR-B-10", "MARCADOR-A-3", "MARCADOR-A-4"])
        XCTAssertEqual(source.pageCount, 20, "a origem não pode perder páginas")
    }

    func testInsertAllAtStartAndEnd() {
        let target = TestPDF.digital(pages: 2, prefix: "A")
        let source = TestPDF.digital(pages: 2, prefix: "B")
        PDFOps.insert(pages: [1, 2], from: source, into: target, at: .start)
        PDFOps.insert(pages: [1], from: source, into: target, at: .end)
        XCTAssertEqual(TestPDF.markers(target),
                       ["MARCADOR-B-1", "MARCADOR-B-2", "MARCADOR-A-1", "MARCADOR-A-2", "MARCADOR-B-1"])
    }

    func testRemoveKeepsAtLeastOnePage() throws {
        let doc = TestPDF.digital(pages: 5)
        try PDFOps.remove(pages: [2, 4], from: doc)
        XCTAssertEqual(TestPDF.markers(doc), ["MARCADOR-A-1", "MARCADOR-A-3", "MARCADOR-A-5"])
        XCTAssertThrowsError(try PDFOps.remove(pages: [1, 2, 3], from: doc))
        XCTAssertEqual(doc.pageCount, 3)
    }

    func testArrangementReorderRotateDelete() throws {
        let doc = TestPDF.digital(pages: 5)
        var entries = (0..<5).map { PageArrangementEntry(sourceIndex: $0) }
        // move a página 5 para o início, gira a página 2 e exclui a página 3
        let last = entries.removeLast()
        entries.insert(last, at: 0)
        entries[2].extraRotation = 90
        entries.remove(at: 3)
        try PDFOps.apply(arrangement: entries, to: doc)
        XCTAssertEqual(TestPDF.markers(doc), ["MARCADOR-A-5", "MARCADOR-A-1", "MARCADOR-A-2", "MARCADOR-A-4"])
        XCTAssertEqual(doc.page(at: 2)?.rotation, 90)

        // A ordem continua igual depois de gravar e abrir de novo.
        let url = TestPDF.tempDir().appendingPathComponent("ordem.pdf")
        try PDFOps.write(doc, to: url)
        let reopened = try PDFOps.open(url)
        XCTAssertEqual(TestPDF.markers(reopened), ["MARCADOR-A-5", "MARCADOR-A-1", "MARCADOR-A-2", "MARCADOR-A-4"])
        XCTAssertEqual(reopened.page(at: 2)?.rotation, 90)
    }

    func testSplitAndExtractAndMerge() throws {
        let doc = TestPDF.digital(pages: 10)
        let parts = try PDFOps.split(doc, parts: 3)
        XCTAssertEqual(parts.map(\.pageCount), [4, 3, 3])
        XCTAssertEqual(TestPDF.markers(parts[1]), ["MARCADOR-A-5", "MARCADOR-A-6", "MARCADOR-A-7"])
        XCTAssertEqual(doc.pageCount, 10)

        let extracted = PDFOps.extract(pages: [2, 9], from: doc)
        XCTAssertEqual(TestPDF.markers(extracted), ["MARCADOR-A-2", "MARCADOR-A-9"])

        let merged = PDFOps.merge([parts[2], extracted])
        XCTAssertEqual(merged.pageCount, 5)
        XCTAssertEqual(TestPDF.markers(merged).first, "MARCADOR-A-8")
    }

    func testAnalyzerClassifiesPages() {
        let digital = Analyzer.analyze(TestPDF.digital(pages: 2))
        XCTAssertEqual(digital.status, .digital)
        let scanned = Analyzer.analyze(TestPDF.scanned(pages: 2))
        XCTAssertEqual(scanned.status, .scanned)
        XCTAssertEqual(scanned.ocrPages, [1, 2])
    }
}

final class ScanServiceTests: XCTestCase {
    func testMakesOnePagePerImageWithPhotoProportions() throws {
        let portrait = TestPDF.scanImage()
        let landscape = TestPDF.scanImage(size: CGSize(width: 1600, height: 1000))
        let data = ScanService.makePDF(from: [portrait, landscape])
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(doc.pageCount, 2)
        let b1 = try XCTUnwrap(doc.page(at: 0)).bounds(for: .mediaBox)
        let b2 = try XCTUnwrap(doc.page(at: 1)).bounds(for: .mediaBox)
        XCTAssertEqual(b1.width, 595.28, accuracy: 0.5)
        XCTAssertEqual(b1.height / b1.width, 1754.0 / 1240.0, accuracy: 0.01)
        XCTAssertGreaterThan(b2.width, b2.height)
        // As imagens ficam comprimidas (JPEG): bem menores que a imagem sem compressão.
        XCTAssertLessThan(data.count, 2 * 1240 * 1754)
        print("Tamanho do PDF escaneado de teste: \(data.count) bytes")
    }

    func testDefaultName() {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 19; c.hour = 9; c.minute = 5
        let date = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(ScanService.defaultName(date: date), "Escaneado 19-10-2026 09h05")
    }
}

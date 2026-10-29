import PDFKit
import XCTest
@testable import PrumoPDF

/// Versão 1.8.0: destaques, resumo, cortar e girar, numerar páginas, força da senha.
@MainActor
final class V18Tests: XCTestCase {
    var base: URL!
    var library: Library!

    private func fresh() {
        if let base { try? FileManager.default.removeItem(at: base) }
        base = TestPDF.tempDir()
        library = Library(baseDirectory: base)
    }

    private func addPDF(_ name: String, pages: Int) throws -> PDFItem {
        let url = base.appendingPathComponent("\(name).pdf")
        XCTAssertTrue(TestPDF.digital(pages: pages).write(to: url))
        return try XCTUnwrap(library.importFiles([url]).first)
    }

    func testMarginsRoundTripForEveryRotation() throws {
        let media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let m = PageMargins(left: 10, top: 20, right: 30, bottom: 40)
        for rot in [0, 90, 180, 270] {
            let box = try PageTools.box(media: media, rotation: rot, margins: m)
            let back = PageTools.margins(media: media, rotation: rot, box: box)
            XCTAssertEqual(back.left, m.left, accuracy: 0.001, "giro \(rot)")
            XCTAssertEqual(back.top, m.top, accuracy: 0.001, "giro \(rot)")
            XCTAssertEqual(back.right, m.right, accuracy: 0.001, "giro \(rot)")
            XCTAssertEqual(back.bottom, m.bottom, accuracy: 0.001, "giro \(rot)")
        }
        // Girar 90° leva a margem da esquerda para o alto.
        XCTAssertEqual(PageTools.rotate(m, by: 90), PageMargins(left: 40, top: 10, right: 20, bottom: 30))
        XCTAssertThrowsError(try PageTools.box(media: media, rotation: 0,
                                               margins: PageMargins(left: 300, top: 0, right: 300, bottom: 0)))
    }

    func testCropAndRotatePages() throws {
        let doc = TestPDF.digital(pages: 3)
        let mm = PageTools.mm
        let n = try PageTools.cropAndRotate(doc, pages: [1, 3], margins: PageMargins(left: 10 * mm, top: 20 * mm,
                                                                                   right: 10 * mm, bottom: 20 * mm),
                                            rotateBy: 0)
        XCTAssertEqual(n, 2)
        let crop = try XCTUnwrap(doc.page(at: 0)).bounds(for: .cropBox)
        XCTAssertEqual(crop.width, 595 - 20 * mm, accuracy: 0.5)
        XCTAssertEqual(crop.height, 842 - 40 * mm, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(doc.page(at: 1)).bounds(for: .cropBox).width, 595, accuracy: 0.5)
        try PageTools.cropAndRotate(doc, pages: [2], margins: nil, rotateBy: 90)
        XCTAssertEqual(doc.page(at: 1)?.rotation, 90)
        // Gravar e abrir de novo mantém o corte e o giro.
        let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(doc.dataRepresentation())))
        XCTAssertEqual(reopened.page(at: 0)!.bounds(for: .cropBox).width, 595 - 20 * mm, accuracy: 0.5)
        XCTAssertEqual(reopened.page(at: 1)?.rotation, 90)
        // Página inteira de novo.
        try PageTools.cropAndRotate(reopened, pages: [1], margins: .zero, rotateBy: 0)
        XCTAssertEqual(reopened.page(at: 0)!.bounds(for: .cropBox).width, 595, accuracy: 0.5)
    }

    func testNumberPagesKeepsTextAndHighlights() throws {
        let doc = TestPDF.digital(pages: 3)
        let sel = try XCTUnwrap(doc.findString("MARCADOR-A-1", withOptions: []).first)
        XCTAssertEqual(Highlights.add(sel, color: .green, in: doc).count, 1)
        var o = PageTools.NumberOptions()
        o.format = .paginaDe
        o.position = .bottomRight
        let data = try PageTools.numberedData(doc, options: o)
        let numbered = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(numbered.pageCount, 3)
        let s2 = numbered.page(at: 1)?.string ?? ""
        print("Página numerada: \(s2)")
        XCTAssertTrue(s2.contains("Página 2 de 3"), "o número é texto de verdade")
        XCTAssertTrue(s2.contains("MARCADOR-A-2"), "o texto da página continua")
        let anns = numbered.page(at: 0)?.annotations.filter { Highlights.isHighlight($0) } ?? []
        XCTAssertEqual(anns.count, 1, "o destaque continua na página")
        // A partir da página 2, começando em 5.
        o.firstPage = 2
        o.start = 5
        o.format = .n
        let partial = try XCTUnwrap(PDFDocument(data: try PageTools.numberedData(doc, options: o)))
        XCTAssertFalse((partial.page(at: 0)?.string ?? "").contains("5"))
        XCTAssertTrue((partial.page(at: 2)?.string ?? "").contains("6"))
    }

    func testHighlightIsSavedAsStandardAnnotation() throws {
        let doc = TestPDF.digital(pages: 2)
        let sel = try XCTUnwrap(doc.findString("texto digital", withOptions: [.caseInsensitive]).first)
        let added = Highlights.add(sel, color: .yellow, in: doc)
        XCTAssertEqual(added.count, 1)
        let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(doc.dataRepresentation())))
        let anns = reopened.page(at: 0)?.annotations.filter { Highlights.isHighlight($0) } ?? []
        XCTAssertEqual(anns.count, 1)
        let a = try XCTUnwrap(anns.first)
        XCTAssertGreaterThanOrEqual(a.quadrilateralPoints?.count ?? 0, 4)
        let center = CGPoint(x: a.bounds.midX, y: a.bounds.midY)
        XCTAssertNotNil(Highlights.highlight(at: center, on: reopened.page(at: 0)!))
        Highlights.remove(a)
        XCTAssertTrue(reopened.page(at: 0)!.annotations.filter { Highlights.isHighlight($0) }.isEmpty)
    }

    func testSummaryTextAndLabels() throws {
        XCTAssertEqual(Summary.pagesLabel([10]), "Trecho extraído da página 10")
        XCTAssertEqual(Summary.pagesLabel([11, 10]), "Trecho extraído das páginas 10-11")
        XCTAssertEqual(Summary.clean("A autora apresen-\ntou febre\npersistente."), "A autora apresentou febre persistente.")
        let data = Summary.buildPDF(sourceName: "Laudo", excerpts: [
            .init(pages: [3], text: "Primeiro trecho do laudo.", added: nil),
            .init(pages: [4, 5], text: "Segundo trecho, de duas páginas.", added: nil),
        ], header: true)
        let doc = try XCTUnwrap(PDFDocument(data: data))
        let text = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Primeiro trecho do laudo."))
        XCTAssertTrue(text.contains("Trecho extraído da página 3"))
        XCTAssertTrue(text.contains("Trecho extraído das páginas 4-5"))
    }

    func testSummaryIsCreatedAndExtended() async throws {
        fresh()
        let item = try addPDF("Laudo", pages: 4)
        let s1 = try await Summary.add([(pages: [1], text: "Trecho um.")], from: item, library: library)
        XCTAssertEqual(s1.name, "Laudo - resumo")
        let s2 = try await Summary.add([(pages: [2, 3], text: "Trecho dois.")], from: item, library: library)
        XCTAssertEqual(s2.id, s1.id, "o mesmo resumo")
        let doc = try XCTUnwrap(PDFDocument(url: s2.url))
        let text = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
        XCTAssertEqual(text.components(separatedBy: "Resumo de").count - 1, 1, "o cabeçalho aparece uma vez")
        XCTAssertTrue(text.contains("Trecho um."))
        XCTAssertTrue(text.contains("Trecho extraído das páginas 2-3"))
        let store = try XCTUnwrap(Summary.loadStore(root: library.root, rel: s2.relativePath))
        XCTAssertEqual(store.excerpts.count, 2)
        XCTAssertEqual(store.signature, Summary.signature(of: s2.url))
        XCTAssertTrue(library.canUndo(try XCTUnwrap(library.item(id: s2.id))))
    }

    func testPasswordStrength() {
        XCTAssertEqual(PasswordStrength.label("1234").hasPrefix("Senha fraca"), true)
        XCTAssertEqual(PasswordStrength.label("caso2026abc").hasPrefix("Senha média"), true)
        XCTAssertEqual(PasswordStrength.label("Caso2026!Ana"), "Senha forte.")
    }
}

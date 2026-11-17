import PDFKit
import UIKit
import XCTest
@testable import PrumoPDF

/// Preencher formulários (versão 1.15.0): campos do PDF, caixas de texto e marcas, finalizar.
/// Os PDFs vão para o CI conferir fora do simulador (scripts/verify_forms.py: pypdf e desenho no pdfium).
@MainActor
final class FormTests: XCTestCase {
    private var base: URL!

    override func setUp() {
        base = TestPDF.tempDir()
    }

    override func tearDown() {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    private func keep(_ url: URL, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["PRUMO_FORMS_OUT"], !dir.isEmpty else { return }
        let dest = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
    }

    /// PDF com um campo de texto e uma caixa de marcar (feitos pelo próprio PDFKit), gravado e reaberto.
    private func formPDF() -> URL {
        let doc = TestPDF.digital(pages: 2)
        let page = doc.page(at: 0)!
        let text = PDFAnnotation(bounds: CGRect(x: 60, y: 500, width: 300, height: 22), forType: .widget, withProperties: nil)
        text.widgetFieldType = .text
        text.fieldName = "nome"
        text.font = UIFont(name: "Helvetica", size: 12)
        page.addAnnotation(text)
        let check = PDFAnnotation(bounds: CGRect(x: 60, y: 460, width: 16, height: 16), forType: .widget, withProperties: nil)
        check.widgetFieldType = .button
        check.widgetControlType = .checkBoxControl
        check.fieldName = "aceito"
        page.addAnnotation(check)
        let url = base.appendingPathComponent("ficha.pdf")
        XCTAssertTrue(doc.write(to: url))
        return url
    }

    func testStyleStringRoundTrip() {
        let box = FormBox(page: 0, bounds: .zero, kind: "cross", text: "",
                          style: FormStyle(font: .times, bold: true, size: 14, color: .red), name: "prumo-mk-x")
        let s = FormBoxes.styleString(box)
        XCTAssertTrue(s.contains("font-family: Times") && s.contains("font-weight: bold") && s.contains("#c71212"), s)
        let (style, kind) = FormBoxes.parse(s)
        XCTAssertEqual(style, box.style)
        XCTAssertEqual(kind, "cross")
        // o mesmo texto que o Windows grava (forms.py) é entendido aqui
        let (w, k) = FormBoxes.parse("font: 12pt Helvetica; font-family: Helvetica; font-size: 12pt; font-weight: normal; " +
                                     "color: #0d339e; prumo-kind: check")
        XCTAssertEqual(w, FormStyle(font: .helvetica, bold: false, size: 12, color: .blue))
        XCTAssertEqual(k, "check")
    }

    func testFillFieldsAndBoxesThenFinalize() throws {
        let url = formPDF()
        let doc = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(FormFields.count(doc), 2)
        let widgets = doc.page(at: 0)!.annotations.filter { $0.type == "Widget" }
        let nome = try XCTUnwrap(widgets.first { $0.fieldName == "nome" })
        nome.widgetStringValue = "Maria Ação"
        let aceito = try XCTUnwrap(widgets.first { $0.fieldName == "aceito" })
        aceito.buttonWidgetState = .onState
        // caixa de texto de duas linhas, ✓ e ✗
        var style = FormStyle(font: .helvetica, bold: true, size: 14, color: .blue)
        let text = "Caio Fernandes Teixeira\nOAB/SP 483.995"
        let size = FormBoxes.size(text: text, style: style)
        XCTAssertGreaterThan(size.height, 2 * 14 * 1.2)
        let boxes = [
            FormBox(page: 0, bounds: CGRect(x: 300, y: 650, width: size.width, height: size.height), kind: "text",
                    text: text, style: style, name: FormBoxes.newName(kind: "text")),
            FormBox(page: 0, bounds: CGRect(x: 300, y: 600, width: 20, height: 20), kind: "check", text: "",
                    style: style, name: FormBoxes.newName(kind: "check")),
            FormBox(page: 1, bounds: CGRect(x: 100, y: 600, width: 24, height: 24), kind: "cross", text: "",
                    style: FormStyle(color: .red), name: FormBoxes.newName(kind: "cross")),
            FormBox(page: 1, bounds: CGRect(x: 100, y: 560, width: 16, height: 16), kind: "dot", text: "",
                    style: FormStyle(), name: FormBoxes.newName(kind: "dot")),
        ]
        FormBoxes.apply(boxes, to: doc)
        // um destaque, que tem de sobreviver ao "Finalizar"
        let hl = PDFAnnotation(bounds: CGRect(x: 55, y: 740, width: 200, height: 18), forType: .highlight, withProperties: nil)
        hl.color = HighlightColor.yellow.uiColor
        doc.page(at: 0)!.addAnnotation(hl)
        let filled = base.appendingPathComponent("preenchido.pdf")
        try XCTUnwrap(doc.dataRepresentation()).write(to: filled)
        keep(filled, "preenchido.pdf")

        // reabrir: valores e caixas voltam iguais
        let back = try XCTUnwrap(PDFDocument(url: filled))
        let w2 = back.page(at: 0)!.annotations.filter { $0.type == "Widget" }
        XCTAssertEqual(w2.first { $0.fieldName == "nome" }?.widgetStringValue, "Maria Ação")
        XCTAssertEqual(w2.first { $0.fieldName == "aceito" }?.buttonWidgetState, .onState)
        let read = FormBoxes.read(back)
        XCTAssertEqual(read.map(\.kind), ["text", "check", "cross", "dot"])
        XCTAssertEqual(read.map(\.name), boxes.map(\.name))
        XCTAssertEqual(read[0].text, text)
        XCTAssertEqual(read[0].style.bold, true)
        XCTAssertEqual(read[0].style.color, .blue)
        XCTAssertEqual(read[0].style.size, 14, accuracy: 0.01)
        XCTAssertEqual(read[2].style.color, .red)
        for (a, b) in zip(read, boxes) {
            XCTAssertEqual(a.bounds.minX, b.bounds.minX, accuracy: 0.5)
            XCTAssertEqual(a.bounds.maxY, b.bounds.maxY, accuracy: 0.5)
        }
        // gravar de novo troca as caixas, não duplica
        FormBoxes.apply(Array(read.dropLast()), to: back)
        XCTAssertEqual(FormBoxes.read(back).count, 3)

        // finalizar: cópia achatada, sem campos e sem caixas; o destaque continua
        style.size = 12
        let flat = try FormFields.flattened(doc)
        let final = base.appendingPathComponent("finalizado.pdf")
        try flat.write(to: final)
        keep(final, "finalizado.pdf")
        let f = try XCTUnwrap(PDFDocument(url: final))
        XCTAssertEqual(f.pageCount, 2)
        XCTAssertEqual(FormFields.count(f), 0)
        XCTAssertTrue(FormBoxes.read(f).isEmpty)
        XCTAssertEqual(f.page(at: 0)!.annotations.filter { $0.type == "Highlight" }.count, 1)
    }

    func testBoxesMadeOnWindowsAreReadAndConverted() throws {
        // como o Windows grava uma marca: /FreeText com /NM "prumo-mk-…" e o estilo em /PrumoStyle
        let doc = TestPDF.digital(pages: 1)
        let a = PDFAnnotation(bounds: CGRect(x: 100, y: 100, width: 20, height: 20), forType: .freeText, withProperties: nil)
        a.contents = "✗"
        _ = a.setValue("prumo-mk-0123456789abcdef", forAnnotationKey: .name)
        _ = a.setValue("font: 20pt Helvetica; font-family: Helvetica; font-size: 20pt; font-weight: normal; " +
                       "color: #c71212; prumo-kind: cross", forAnnotationKey: FormBoxes.styleKey)
        doc.page(at: 0)!.addAnnotation(a)
        let t = PDFAnnotation(bounds: CGRect(x: 100, y: 300, width: 120, height: 20), forType: .freeText, withProperties: nil)
        t.contents = "Escrito no Windows"
        _ = t.setValue("prumo-tx-0123456789abcdef", forAnnotationKey: .name)
        _ = t.setValue("font: 12pt Times; font-family: Times; font-size: 12pt; font-weight: bold; color: #000000",
                       forAnnotationKey: FormBoxes.styleKey)
        doc.page(at: 0)!.addAnnotation(t)
        FormBoxes.normalize(doc)
        let boxes = FormBoxes.read(doc)
        XCTAssertEqual(boxes.count, 2)
        let mark = try XCTUnwrap(boxes.first { $0.kind != "text" })
        XCTAssertEqual(mark.kind, "cross")
        XCTAssertEqual(mark.style.color, .red)
        XCTAssertEqual(mark.name, "prumo-mk-0123456789abcdef")
        XCTAssertEqual(doc.page(at: 0)!.annotations.first { FormBoxes.name(of: $0) == mark.name }?.type, "Ink")
        let text = try XCTUnwrap(boxes.first { $0.kind == "text" })
        XCTAssertEqual(text.text, "Escrito no Windows")
        XCTAssertEqual(text.style.font, .times)
        XCTAssertTrue(text.style.bold)
        XCTAssertEqual(text.bounds.maxY, 320, accuracy: 0.5)   // o canto de cima fica onde estava
    }

    func testModelEditUndoRedoAndDirty() throws {
        let url = formPDF()
        let model = FormModel()
        try model.load(url: url)
        XCTAssertEqual(model.tool, .select)        // PDF com campos começa escolhendo
        XCTAssertFalse(model.dirty)
        model.style = FormStyle(font: .courier, bold: false, size: 12, color: .black)
        model.finishEditing(FormEditRequest(page: 0, point: CGPoint(x: 80, y: 700), name: nil, text: ""), text: "Olá")
        XCTAssertEqual(model.boxes.map(\.text), ["Olá"])
        XCTAssertTrue(model.dirty)
        let name = try XCTUnwrap(model.selected)
        model.setStyle { $0.bold = true; $0.color = .green }
        XCTAssertEqual(model.boxes.first?.style.bold, true)
        XCTAssertEqual(model.boxes.first?.style.color, .green)
        // a seleção (retângulo tracejado) não conta como caixa e não vai para o arquivo
        XCTAssertEqual(model.boxes.count, 1)
        model.finishEditing(FormEditRequest(page: 0, point: CGPoint(x: 80, y: 700), name: name, text: "Olá"),
                            text: "Olá\nsegunda linha")
        XCTAssertEqual(model.boxes.first?.text, "Olá\nsegunda linha")
        XCTAssertEqual(model.boxes.first?.bounds.maxY ?? 0, 700, accuracy: 0.5)
        model.undo()
        XCTAssertEqual(model.boxes.first?.text, "Olá")
        model.redo()
        XCTAssertEqual(model.boxes.first?.text, "Olá\nsegunda linha")
        model.deleteSelected()
        XCTAssertTrue(model.boxes.isEmpty)
        model.undo()
        XCTAssertEqual(model.boxes.count, 1)
        // apagar todo o texto apaga a caixa
        model.finishEditing(FormEditRequest(page: 0, point: CGPoint(x: 80, y: 700), name: name, text: "x"), text: "  ")
        XCTAssertTrue(model.boxes.isEmpty)
        model.hideSelection()
        let data = try XCTUnwrap(model.document?.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(reopened.page(at: 0)!.annotations.allSatisfy { !FormBoxes.isSelection($0) })
    }

    func testSuffixInAnyLanguage() {
        XCTAssertEqual(AppLanguages.stripSuffix("Ficha - preenchido", template: "{} - preenchido"), "Ficha")
        XCTAssertEqual(AppLanguages.stripSuffix("Ficha - filled", template: "{} - preenchido"), "Ficha")
    }
}

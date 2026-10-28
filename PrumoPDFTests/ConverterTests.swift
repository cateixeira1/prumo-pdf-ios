import PDFKit
import UIKit
import XCTest
@testable import PrumoPDF

/// Conversão de outros arquivos em PDF (versão 1.3.0).
@MainActor
final class ConverterTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = TestPDF.tempDir()
    }

    private func image(_ size: CGSize, color: UIColor = .systemTeal) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func write(_ name: String, _ data: Data) -> URL {
        let url = dir.appendingPathComponent(name)
        try? data.write(to: url)
        return url
    }

    private func text(_ data: Data) -> String {
        PDFDocument(data: data)?.string ?? ""
    }

    func testKinds() {
        XCTAssertEqual(Converter.kind(of: URL(fileURLWithPath: "/a/Foto.HEIC")), .image)
        XCTAssertEqual(Converter.kind(of: URL(fileURLWithPath: "/a/b.docx")), .office)
        XCTAssertEqual(Converter.kind(of: URL(fileURLWithPath: "/a/b.pages")), .office)
        XCTAssertEqual(Converter.kind(of: URL(fileURLWithPath: "/a/b.txt")), .text)
        XCTAssertEqual(Converter.kind(of: URL(fileURLWithPath: "/a/b.rtf")), .rtf)
        XCTAssertEqual(Converter.kind(of: URL(fileURLWithPath: "/a/b.pdf")), .pdf)
        XCTAssertNil(Converter.kind(of: URL(fileURLWithPath: "/a/b.zip")))
    }

    func testImagesCombinedA4WithOrientation() async throws {
        let portrait = write("retrato.jpg", image(CGSize(width: 900, height: 1300)).jpegData(compressionQuality: 0.9)!)
        let landscape = write("paisagem.png", image(CGSize(width: 1600, height: 900)).pngData()!)
        let result = await Converter.convert(urls: [portrait, landscape], combineImages: true, combinedName: "Fotos")
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(result.outputs.count, 1)
        XCTAssertEqual(result.outputs[0].name, "Fotos")
        XCTAssertTrue(result.outputs[0].fromImages)
        let doc = try XCTUnwrap(PDFDocument(data: result.outputs[0].data))
        XCTAssertEqual(doc.pageCount, 2)
        let p0 = try XCTUnwrap(doc.page(at: 0)).bounds(for: .mediaBox)
        let p1 = try XCTUnwrap(doc.page(at: 1)).bounds(for: .mediaBox)
        XCTAssertGreaterThan(p0.height, p0.width, "foto em pé: A4 em pé")
        XCTAssertGreaterThan(p1.width, p1.height, "foto deitada: A4 deitado")
        XCTAssertEqual(max(p0.width, p0.height), 841.89, accuracy: 1)
    }

    func testImagesOnePDFEach() async {
        let a = write("a.jpg", image(CGSize(width: 800, height: 600)).jpegData(compressionQuality: 0.9)!)
        let b = write("b.jpg", image(CGSize(width: 600, height: 800)).jpegData(compressionQuality: 0.9)!)
        let result = await Converter.convert(urls: [a, b], combineImages: false, combinedName: nil)
        XCTAssertEqual(result.outputs.map(\.name), ["a", "b"])
    }

    func testMultipageTIFF() async throws {
        let url = dir.appendingPathComponent("digitalizacao.tiff")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 3, nil))
        for _ in 0..<3 { CGImageDestinationAddImage(dest, image(CGSize(width: 850, height: 1100)).cgImage!, nil) }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let result = await Converter.convert(urls: [url], combineImages: false, combinedName: nil)
        XCTAssertEqual(PDFDocument(data: try XCTUnwrap(result.outputs.first).data)?.pageCount, 3)
    }

    func testLongTextPaginatesA4() async throws {
        let body = String(repeating: "Prazo para contestação: 15 dias úteis, contados da juntada do mandado.\n", count: 150)
        let url = write("nota.txt", body.data(using: .utf8)!)
        let result = await Converter.convert(urls: [url], combineImages: false, combinedName: nil)
        let out = try XCTUnwrap(result.outputs.first)
        let doc = try XCTUnwrap(PDFDocument(data: out.data))
        XCTAssertGreaterThan(doc.pageCount, 1)
        XCTAssertEqual(try XCTUnwrap(doc.page(at: 0)).bounds(for: .mediaBox).width, 595.28, accuracy: 1)
        XCTAssertTrue(text(out.data).contains("contestação"))
    }

    func testHTMLAndRTF() async throws {
        let html = write("laudo.html", "<h1>Laudo</h1><p>Paciente com <b>sepse</b> após cirurgia.</p>".data(using: .utf8)!)
        let rtfString = "{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Helvetica;}}\\f0\\fs24 Procura\\'e7\\'e3o assinada pelo cliente.}"
        let rtf = write("procuracao.rtf", rtfString.data(using: .ascii)!)
        let result = await Converter.convert(urls: [html, rtf], combineImages: false, combinedName: nil)
        XCTAssertEqual(result.failed.count, 0, "\(result.failed)")
        XCTAssertEqual(result.outputs.count, 2)
        XCTAssertTrue(text(result.outputs[0].data).contains("sepse"))
        XCTAssertTrue(text(result.outputs[1].data).contains("assinada"))
    }

    func testWordDocument() async throws {
        let docx = write("Petição.docx", Data(base64Encoded: Self.docxBase64)!)
        let result = await Converter.convert(urls: [docx], combineImages: false, combinedName: nil)
        XCTAssertEqual(result.failed.count, 0, "\(result.failed)")
        let out = try XCTUnwrap(result.outputs.first)
        let content = text(out.data)
        print("Converter: texto do .docx no PDF: \(content.prefix(120))")
        XCTAssertTrue(content.contains("indenização"), "o texto do Word aparece no PDF")
    }

    func testSavedConversionGoesToLibraryAndPendingOCR() async throws {
        let base = TestPDF.tempDir()
        let library = Library(baseDirectory: base)
        let flow = AppFlow()
        let a = write("x.jpg", image(CGSize(width: 800, height: 1000)).jpegData(compressionQuality: 0.9)!)
        let b = write("y.jpg", image(CGSize(width: 800, height: 1000)).jpegData(compressionQuality: 0.9)!)
        let items = await flow.runConversion([a, b], folder: "", combine: false, askOCR: true, library: library)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { library.item(id: $0.id)?.meta.pendingOCR == true })
    }

    static let docxBase64 = "UEsDBBQAAAAAAFQJXF3wSsJ/LAIAACwCAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04IiBzdGFuZGFsb25lPSJ5ZXMiPz48VHlwZXMgeG1sbnM9Imh0dHA6Ly9zY2hlbWFzLm9wZW54bWxmb3JtYXRzLm9yZy9wYWNrYWdlLzIwMDYvY29udGVudC10eXBlcyI+PERlZmF1bHQgRXh0ZW5zaW9uPSJyZWxzIiBDb250ZW50VHlwZT0iYXBwbGljYXRpb24vdm5kLm9wZW54bWxmb3JtYXRzLXBhY2thZ2UucmVsYXRpb25zaGlwcyt4bWwiLz48RGVmYXVsdCBFeHRlbnNpb249InhtbCIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3htbCIvPjxPdmVycmlkZSBQYXJ0TmFtZT0iL3dvcmQvZG9jdW1lbnQueG1sIiBDb250ZW50VHlwZT0iYXBwbGljYXRpb24vdm5kLm9wZW54bWxmb3JtYXRzLW9mZmljZWRvY3VtZW50LndvcmRwcm9jZXNzaW5nbWwuZG9jdW1lbnQubWFpbit4bWwiLz48T3ZlcnJpZGUgUGFydE5hbWU9Ii93b3JkL3N0eWxlcy54bWwiIENvbnRlbnRUeXBlPSJhcHBsaWNhdGlvbi92bmQub3BlbnhtbGZvcm1hdHMtb2ZmaWNlZG9jdW1lbnQud29yZHByb2Nlc3NpbmdtbC5zdHlsZXMreG1sIi8+PC9UeXBlcz5QSwMEFAAAAAAAVAlcXZv9N+opAQAAKQEAAAsAAABfcmVscy8ucmVsczw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04IiBzdGFuZGFsb25lPSJ5ZXMiPz48UmVsYXRpb25zaGlwcyB4bWxucz0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL3BhY2thZ2UvMjAwNi9yZWxhdGlvbnNoaXBzIj48UmVsYXRpb25zaGlwIElkPSJySWQxIiBUeXBlPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvb2ZmaWNlRG9jdW1lbnQvMjAwNi9yZWxhdGlvbnNoaXBzL29mZmljZURvY3VtZW50IiBUYXJnZXQ9IndvcmQvZG9jdW1lbnQueG1sIi8+PC9SZWxhdGlvbnNoaXBzPlBLAwQUAAAAAABUCVxdEtwejk0CAABNAgAAEQAAAHdvcmQvZG9jdW1lbnQueG1sPD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiIHN0YW5kYWxvbmU9InllcyI/Pjx3OmRvY3VtZW50IHhtbG5zOnc9Imh0dHA6Ly9zY2hlbWFzLm9wZW54bWxmb3JtYXRzLm9yZy93b3JkcHJvY2Vzc2luZ21sLzIwMDYvbWFpbiI+PHc6Ym9keT48dzpwPjx3OnBQcj48dzpwU3R5bGUgdzp2YWw9IkhlYWRpbmcxIi8+PC93OnBQcj48dzpyPjx3OnQ+UGV0acOnw6NvIGluaWNpYWw8L3c6dD48L3c6cj48L3c6cD48dzpwPjx3OnI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5BIGF1dG9yYSB2ZW0gcHJvcG9yIGHDp8OjbyBkZSBpbmRlbml6YcOnw6NvIGVtIGZhY2UgZG8gaG9zcGl0YWwuPC93OnQ+PC93OnI+PC93OnA+PHc6cD48dzpyPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+UmVxdWVyIGEgY2l0YcOnw6NvIGRvIHLDqXUuPC93OnQ+PC93OnI+PC93OnA+PHc6dGJsPjx3OnRyPjx3OnRjPjx3OnA+PHc6cj48dzp0PkRhdGE8L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PHc6dGM+PHc6cD48dzpyPjx3OnQ+VmFsb3I8L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PC93OnRyPjwvdzp0Ymw+PC93OmJvZHk+PC93OmRvY3VtZW50PlBLAwQUAAAAAABUCVxdzGl5cOkAAADpAAAADwAAAHdvcmQvc3R5bGVzLnhtbDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04IiBzdGFuZGFsb25lPSJ5ZXMiPz48dzpzdHlsZXMgeG1sbnM6dz0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL3dvcmRwcm9jZXNzaW5nbWwvMjAwNi9tYWluIj48dzpzdHlsZSB3OnR5cGU9InBhcmFncmFwaCIgdzpzdHlsZUlkPSJIZWFkaW5nMSI+PHc6bmFtZSB3OnZhbD0iaGVhZGluZyAxIi8+PC93OnN0eWxlPjwvdzpzdHlsZXM+UEsDBBQAAAAAAFQJXF2UvSZWGgEAABoBAAAcAAAAd29yZC9fcmVscy9kb2N1bWVudC54bWwucmVsczw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04IiBzdGFuZGFsb25lPSJ5ZXMiPz48UmVsYXRpb25zaGlwcyB4bWxucz0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL3BhY2thZ2UvMjAwNi9yZWxhdGlvbnNoaXBzIj48UmVsYXRpb25zaGlwIElkPSJySWQxIiBUeXBlPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvb2ZmaWNlRG9jdW1lbnQvMjAwNi9yZWxhdGlvbnNoaXBzL3N0eWxlcyIgVGFyZ2V0PSJzdHlsZXMueG1sIi8+PC9SZWxhdGlvbnNoaXBzPlBLAQIUAxQAAAAAAFQJXF3wSsJ/LAIAACwCAAATAAAAAAAAAAAAAACAAQAAAABbQ29udGVudF9UeXBlc10ueG1sUEsBAhQDFAAAAAAAVAlcXZv9N+opAQAAKQEAAAsAAAAAAAAAAAAAAIABXQIAAF9yZWxzLy5yZWxzUEsBAhQDFAAAAAAAVAlcXRLcHo5NAgAATQIAABEAAAAAAAAAAAAAAIABrwMAAHdvcmQvZG9jdW1lbnQueG1sUEsBAhQDFAAAAAAAVAlcXcxpeXDpAAAA6QAAAA8AAAAAAAAAAAAAAIABKwYAAHdvcmQvc3R5bGVzLnhtbFBLAQIUAxQAAAAAAFQJXF2UvSZWGgEAABoBAAAcAAAAAAAAAAAAAACAAUEHAAB3b3JkL19yZWxzL2RvY3VtZW50LnhtbC5yZWxzUEsFBgAAAAAFAAUAQAEAAJUIAAAAAA=="
}

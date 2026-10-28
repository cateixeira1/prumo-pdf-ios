import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers
import WebKit

/// Transformar outros arquivos em PDF, tudo no próprio iPhone (sem internet).
///
/// - Fotos e imagens (JPG, PNG, HEIC, TIFF…): uma por página A4, na orientação da foto.
/// - Texto (TXT, CSV), RTF e HTML: paginação A4 com margens de 2 cm, pelo sistema de impressão do iOS.
/// - Word, Excel, PowerPoint, Pages, Numbers e Keynote: abertos pela mesma visualização do app
///   Arquivos e paginados em A4.
enum Converter {
    enum Kind { case pdf, image, text, rtf, html, office }

    static let a4 = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    static let margin: CGFloat = 56.7   // 2 cm

    static let officeExtensions: Set<String> = ["doc", "docx", "xls", "xlsx", "ppt", "pptx",
                                                "pages", "numbers", "key", "odt", "ods", "odp"]

    /// Tipos aceitos no app Arquivos (PDF e tudo o que dá para converter).
    static var importTypes: [UTType] {
        var types: [UTType] = [.pdf, .image, .heic, .plainText, .commaSeparatedText, .rtf, .html]
        for ext in officeExtensions.sorted() {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    static func kind(of url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if officeExtensions.contains(ext) { return .office }
        if ["txt", "csv", "md", "log"].contains(ext) { return .text }
        if ext == "rtf" { return .rtf }
        if ["html", "htm"].contains(ext) { return .html }
        if let t = UTType(filenameExtension: ext) {
            if t.conforms(to: .image) { return .image }
            if t.conforms(to: .pdf) { return .pdf }
            if t.conforms(to: .rtf) { return .rtf }
            if t.conforms(to: .html) { return .html }
            if t.conforms(to: .plainText) { return .text }
        }
        return nil
    }

    // MARK: - Imagens

    /// Reduz fotos muito grandes (acima de 3000 px) e entrega JPEG; a orientação da foto é aplicada.
    static func prepared(_ image: UIImage) -> UIImage {
        let maxSide: CGFloat = 3000
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let redrawn = UIGraphicsImageRenderer(size: target, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))   // aplica a rotação (EXIF)
        }
        if let jpeg = redrawn.jpegData(compressionQuality: 0.88), let back = UIImage(data: jpeg) { return back }
        return redrawn
    }

    /// Imagens em PDF: uma por página A4 (retrato ou paisagem, conforme a imagem), sem cortes.
    static func pdfData(images: [UIImage]) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: a4)
        return renderer.pdfData { ctx in
            for original in images {
                var source = original
                if AppSettings.dewarpPhotos, Dewarp.isAvailable, let fixed = try? Dewarp.unwarp(original) {
                    source = fixed   // foto de livro ou papel ondulado: texto reto
                }
                let img = prepared(source)
                let landscape = img.size.width > img.size.height
                let page = landscape ? CGRect(x: 0, y: 0, width: a4.height, height: a4.width) : a4
                ctx.beginPage(withBounds: page, pageInfo: [:])
                let s = min(page.width / img.size.width, page.height / img.size.height)
                let w = img.size.width * s, h = img.size.height * s
                img.draw(in: CGRect(x: (page.width - w) / 2, y: (page.height - h) / 2, width: w, height: h))
            }
        }
    }

    static func images(from url: URL) -> [UIImage] {
        // TIFF com várias páginas (digitalizações): uma imagem por página.
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let count = CGImageSourceGetCount(src)
        if count > 1 {
            return (0..<count).compactMap { i in CGImageSourceCreateImageAtIndex(src, i, nil).map { UIImage(cgImage: $0) } }
        }
        if let data = try? Data(contentsOf: url), let img = UIImage(data: data) { return [img] }
        return []
    }

    // MARK: - Texto, RTF e HTML

    /// Pagina qualquer formatador de impressão em A4 com margens de 2 cm.
    @MainActor
    static func pdfData(formatter: UIPrintFormatter) -> Data {
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        renderer.setValue(NSValue(cgRect: a4), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: a4.insetBy(dx: margin, dy: margin)), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, a4, nil)
        let pages = max(1, renderer.numberOfPages)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))
        for i in 0..<pages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    static func readText(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        for enc in [String.Encoding.utf8, .windowsCP1252, .isoLatin1] {
            if let s = String(data: data, encoding: enc) { return s }
        }
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    static func pdfData(text: String, monospaced: Bool = false) -> Data {
        let font = monospaced ? UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
                              : UIFont.systemFont(ofSize: 11)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.black])
        return pdfData(formatter: UISimpleTextPrintFormatter(attributedText: attr))
    }

    @MainActor
    static func pdfData(rtf url: URL) throws -> Data {
        let attr = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                          documentAttributes: nil)
        return pdfData(formatter: UISimpleTextPrintFormatter(attributedText: attr))
    }

    @MainActor
    static func pdfData(html: String) -> Data {
        let styled = "<style>body{font-family:-apple-system,Helvetica;font-size:11pt;color:#000}"
            + "table{border-collapse:collapse}td,th{border:1px solid #999;padding:4px}</style>" + html
        return pdfData(formatter: UIMarkupTextPrintFormatter(markupText: styled))
    }

    // MARK: - Word, Excel, PowerPoint, Pages…

    @MainActor
    static func pdfData(office url: URL) async throws -> Data {
        try await WebPDFRenderer().render(url: url)
    }

    // MARK: - Conversão de uma lista

    struct Output {
        var data: Data
        var name: String
        var fromImages: Bool
    }

    /// Converte arquivos (já copiados para dentro do app). Imagens podem virar um PDF só.
    @MainActor
    static func convert(urls: [URL], combineImages: Bool, combinedName: String?) async -> (outputs: [Output], failed: [(String, String)]) {
        var outputs: [Output] = []
        var failed: [(String, String)] = []
        let imageURLs = urls.filter { kind(of: $0) == .image }
        if combineImages && imageURLs.count > 1 {
            let imgs = imageURLs.flatMap { images(from: $0) }
            if imgs.isEmpty {
                failed.append(("Imagens", "Não foi possível abrir as imagens."))
            } else {
                outputs.append(Output(data: pdfData(images: imgs), name: combinedName ?? "Imagens", fromImages: true))
            }
        }
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            do {
                switch kind(of: url) {
                case .image?:
                    if combineImages && imageURLs.count > 1 { continue }
                    let imgs = images(from: url)
                    guard !imgs.isEmpty else { throw UserFacingError("Não foi possível abrir a imagem.") }
                    outputs.append(Output(data: pdfData(images: imgs), name: name, fromImages: true))
                case .text?:
                    let ext = url.pathExtension.lowercased()
                    outputs.append(Output(data: pdfData(text: readText(url), monospaced: ext == "csv" || ext == "log"),
                                          name: name, fromImages: false))
                case .rtf?:
                    outputs.append(Output(data: try pdfData(rtf: url), name: name, fromImages: false))
                case .html?:
                    outputs.append(Output(data: pdfData(html: readText(url)), name: name, fromImages: false))
                case .office?:
                    outputs.append(Output(data: try await pdfData(office: url), name: name, fromImages: false))
                case .pdf?, nil:
                    continue
                }
            } catch {
                failed.append((url.lastPathComponent, error.localizedDescription))
            }
        }
        // Confere se cada resultado é um PDF com páginas.
        outputs = outputs.filter { out in
            if let doc = PDFDocument(data: out.data), doc.pageCount > 0 { return true }
            failed.append((out.name, "A conversão não gerou páginas."))
            return false
        }
        return (outputs, failed)
    }
}

/// Abre o documento numa visualização da web (a mesma do app Arquivos) e pagina em A4.
@MainActor
final class WebPDFRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?

    func render(url: URL) async throws -> Data {
        let printable = Converter.a4.insetBy(dx: Converter.margin, dy: Converter.margin)
        let wv = WKWebView(frame: CGRect(x: -2000, y: 0, width: printable.width, height: printable.height))
        wv.navigationDelegate = self
        webView = wv
        // A visualização precisa estar numa janela para montar o documento.
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.windows.first
        window?.addSubview(wv)
        defer {
            wv.removeFromSuperview()
            webView = nil
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        // Documentos do Office terminam de montar um pouco depois do "carregado".
        try await Task.sleep(nanoseconds: 1_200_000_000)
        return Converter.pdfData(formatter: wv.viewPrintFormatter())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: UserFacingError("Não foi possível abrir o documento: \(error.localizedDescription)"))
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: UserFacingError("Não foi possível abrir o documento: \(error.localizedDescription)"))
        continuation = nil
    }
}

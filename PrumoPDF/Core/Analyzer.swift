import Foundation
import PDFKit

/// Tipo de conteúdo de um documento, conforme o texto selecionável das páginas.
enum TextStatus: String, Codable {
    case digital    // todas as páginas têm texto
    case scanned    // nenhuma página tem texto (escaneado ou foto)
    case mixed      // algumas páginas com texto, outras só imagem
    case empty      // documento sem páginas

    var label: String {
        switch self {
        case .digital: return "Texto digital"
        case .scanned: return "Escaneado"
        case .mixed: return "Misto"
        case .empty: return "Vazio"
        }
    }

    var needsOCR: Bool { self == .scanned || self == .mixed }
}

/// Classificação de uma página.
enum PageKind: Equatable {
    case digital          // texto selecionável; não precisa de OCR
    case image            // sem texto: escaneada ou foto
    case imageWithStamp   // imagem grande com pouco texto digital (ex.: rodapé de assinatura do PJe)

    var needsOCR: Bool { self != .digital }
}

struct DocumentAnalysis {
    var pageCount: Int
    var status: TextStatus
    var ocrPages: [Int]       // páginas (começando em 1) que precisam de OCR
    var text: String          // texto de todas as páginas, para a busca
    var locked = false        // protegido por senha
}

enum Analyzer {
    /// Abaixo disso a página é tratada como imagem (sem texto selecionável).
    static let minTextChars = 20
    /// Página com imagem grande e menos texto que isso é tratada como imagem com carimbo digital.
    static let stampMaxChars = 1500
    /// Imagem a partir deste número de pixels é considerada "página escaneada".
    static let largeImagePixels = 400_000

    static func analyze(url: URL) -> DocumentAnalysis? {
        guard let doc = PDFDocument(url: url) else { return nil }
        if doc.isLocked {
            return DocumentAnalysis(pageCount: doc.pageCount, status: .digital, ocrPages: [], text: "", locked: true)
        }
        return analyze(doc)
    }

    static func analyze(_ doc: PDFDocument) -> DocumentAnalysis {
        var ocrPages: [Int] = []
        var texts: [String] = []
        texts.reserveCapacity(doc.pageCount)
        for i in 0..<doc.pageCount {
            autoreleasepool {
                guard let page = doc.page(at: i) else { return }
                let text = page.string ?? ""
                if classify(page: page, text: text).needsOCR {
                    ocrPages.append(i + 1)
                }
                texts.append(text)
            }
        }
        let status: TextStatus
        if doc.pageCount == 0 {
            status = .empty
        } else if ocrPages.isEmpty {
            status = .digital
        } else if ocrPages.count == doc.pageCount {
            status = .scanned
        } else {
            status = .mixed
        }
        return DocumentAnalysis(pageCount: doc.pageCount, status: status,
                                ocrPages: ocrPages, text: texts.joined(separator: "\n"))
    }

    static func classify(page: PDFPage, text: String? = nil) -> PageKind {
        let chars = PDFOps.usefulCharacterCount(text ?? page.string ?? "")
        if chars < minTextChars { return .image }
        if chars < stampMaxChars, let cg = page.pageRef, largestImagePixels(in: cg) >= largeImagePixels {
            return .imageWithStamp
        }
        return .digital
    }

    // MARK: - Imagens da página (lidas direto da estrutura do PDF)

    static func largestImagePixels(in page: CGPDFPage) -> Int {
        guard let dict = page.dictionary else { return 0 }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let res = resources else { return 0 }
        return largestImage(in: res, depth: 0)
    }

    private static func largestImage(in resources: CGPDFDictionaryRef, depth: Int) -> Int {
        guard depth < 4 else { return 0 }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xo = xobjects else { return 0 }
        var best = 0
        CGPDFDictionaryApplyBlock(xo, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let s = stream,
                  let sd = CGPDFStreamGetDictionary(s) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(sd, "Subtype", &subtype), let st = subtype else { return true }
            let name = String(cString: st)
            if name == "Image" {
                var w: CGPDFInteger = 0
                var h: CGPDFInteger = 0
                _ = CGPDFDictionaryGetInteger(sd, "Width", &w)
                _ = CGPDFDictionaryGetInteger(sd, "Height", &h)
                best = max(best, Int(w) * Int(h))
            } else if name == "Form" {
                var sub: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(sd, "Resources", &sub), let r = sub {
                    best = max(best, largestImage(in: r, depth: depth + 1))
                }
            }
            return true
        }, nil)
        return best
    }
}

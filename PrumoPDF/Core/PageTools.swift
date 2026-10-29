import CoreText
import PDFKit
import UIKit

/// Margens como a página aparece na tela (depois do giro), em pontos.
struct PageMargins: Equatable {
    var left: CGFloat = 0
    var top: CGFloat = 0
    var right: CGFloat = 0
    var bottom: CGFloat = 0

    static let zero = PageMargins()
    var isZero: Bool { abs(left) < 0.01 && abs(top) < 0.01 && abs(right) < 0.01 && abs(bottom) < 0.01 }
}

/// Cortar margens, girar e numerar páginas (a mesma conta do Prumo para Windows).
enum PageTools {
    static let mm: CGFloat = 72 / 25.4

    // MARK: - Cortar e girar

    /// Margens (na tela) → CropBox no espaço do PDF, a partir da página inteira (MediaBox).
    static func box(media: CGRect, rotation: Int, margins m: PageMargins) throws -> CGRect {
        let x0 = media.minX, y0 = media.minY, x1 = media.maxX, y1 = media.maxY
        let r: (CGFloat, CGFloat, CGFloat, CGFloat)
        switch PDFOps.normalized(rotation) {
        case 90: r = (x0 + m.top, y0 + m.left, x1 - m.bottom, y1 - m.right)
        case 180: r = (x0 + m.right, y0 + m.top, x1 - m.left, y1 - m.bottom)
        case 270: r = (x0 + m.bottom, y0 + m.right, x1 - m.top, y1 - m.left)
        default: r = (x0 + m.left, y0 + m.bottom, x1 - m.right, y1 - m.top)
        }
        guard r.2 - r.0 >= 18, r.3 - r.1 >= 18 else {
            throw UserFacingError("As margens deixam a página pequena demais.")
        }
        return CGRect(x: r.0, y: r.1, width: r.2 - r.0, height: r.3 - r.1)
    }

    /// CropBox → margens (como a página aparece), o inverso de `box`.
    static func margins(media: CGRect, rotation: Int, box: CGRect) -> PageMargins {
        let dl = box.minX - media.minX, db = box.minY - media.minY
        let dr = media.maxX - box.maxX, dt = media.maxY - box.maxY
        switch PDFOps.normalized(rotation) {
        case 90: return PageMargins(left: db, top: dl, right: dt, bottom: dr)
        case 180: return PageMargins(left: dr, top: db, right: dl, bottom: dt)
        case 270: return PageMargins(left: dt, top: dr, right: db, bottom: dl)
        default: return PageMargins(left: dl, top: dt, right: dr, bottom: db)
        }
    }

    /// Margens depois de girar a página `delta` graus no sentido horário.
    static func rotate(_ m: PageMargins, by delta: Int) -> PageMargins {
        switch PDFOps.normalized(delta) {
        case 90: return PageMargins(left: m.bottom, top: m.left, right: m.top, bottom: m.right)
        case 180: return PageMargins(left: m.right, top: m.bottom, right: m.left, bottom: m.top)
        case 270: return PageMargins(left: m.top, top: m.right, right: m.bottom, bottom: m.left)
        default: return m
        }
    }

    /// Tamanho da página inteira como aparece (com o giro).
    static func displaySize(media: CGRect, rotation: Int) -> CGSize {
        let r = PDFOps.normalized(rotation)
        return (r == 90 || r == 270) ? CGSize(width: media.height, height: media.width) : media.size
    }

    /// Gira (`rotateBy`, sentido horário) e corta (`margins`, como a página fica depois do giro;
    /// nil não mexe no corte; zero volta à página inteira). Devolve quantas páginas mudaram.
    @discardableResult
    static func cropAndRotate(_ doc: PDFDocument, pages: [Int], margins: PageMargins?, rotateBy: Int) throws -> Int {
        let todo = Set(pages.filter { $0 >= 1 && $0 <= doc.pageCount }).sorted()
        guard !todo.isEmpty else { throw UserFacingError("Nenhuma página selecionada.") }
        for n in todo {
            guard let page = doc.page(at: n - 1) else { continue }
            if PDFOps.normalized(rotateBy) != 0 {
                page.rotation = PDFOps.normalized(page.rotation + rotateBy)
            }
            if let m = margins {
                let media = page.bounds(for: .mediaBox)
                let crop: CGRect
                if m.isZero {
                    crop = media
                } else {
                    crop = try box(media: media, rotation: page.rotation, margins: m)
                }
                page.setBounds(crop, for: .cropBox)
            }
        }
        return todo.count
    }

    /// Margens até onde há conteúdo (não branco) numa imagem da página com `pointWidth` pontos de largura.
    static func contentMargins(of image: UIImage, pointWidth: CGFloat, padding: CGFloat = 8) -> PageMargins? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: w * h)
        var drawn = false
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            drawn = true
        }
        guard drawn else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where pixels[row + x] < 225 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let s = pointWidth / CGFloat(w)
        // O bitmap do CGContext tem a linha 0 em cima (dados na ordem da memória).
        return PageMargins(left: max(0, CGFloat(minX) * s - padding), top: max(0, CGFloat(minY) * s - padding),
                           right: max(0, CGFloat(w - 1 - maxX) * s - padding),
                           bottom: max(0, CGFloat(h - 1 - maxY) * s - padding))
    }

    // MARK: - Numerar

    enum NumberFormat: String, CaseIterable, Identifiable {
        case n, pagina, paginaDe, barra, tracos
        var id: String { rawValue }
        var label: String {
            switch self {
            case .n: return "1"
            case .pagina: return "Página 1"
            case .paginaDe: return "Página 1 de 12"
            case .barra: return "1/12"
            case .tracos: return "- 1 -"
            }
        }
        func text(_ n: Int, total: Int) -> String {
            switch self {
            case .n: return "\(n)"
            case .pagina: return "Página \(n)"
            case .paginaDe: return "Página \(n) de \(total)"
            case .barra: return "\(n)/\(total)"
            case .tracos: return "- \(n) -"
            }
        }
    }

    enum NumberPosition: String, CaseIterable, Identifiable {
        case bottomCenter, bottomRight, bottomLeft, topCenter, topRight, topLeft
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bottomCenter: return "Embaixo, no centro"
            case .bottomRight: return "Embaixo, à direita"
            case .bottomLeft: return "Embaixo, à esquerda"
            case .topCenter: return "No alto, no centro"
            case .topRight: return "No alto, à direita"
            case .topLeft: return "No alto, à esquerda"
            }
        }
        var isTop: Bool { self == .topCenter || self == .topRight || self == .topLeft }
        var horizontal: Int {   // -1 esquerda, 0 centro, 1 direita
            switch self {
            case .bottomLeft, .topLeft: return -1
            case .bottomRight, .topRight: return 1
            default: return 0
            }
        }
    }

    struct NumberOptions {
        var format: NumberFormat = .n
        var position: NumberPosition = .bottomCenter
        var start = 1
        var firstPage = 1        // começa a numerar nesta página (começando em 1)
        var size: CGFloat = 10
        var margin: CGFloat = 10 * PageTools.mm
    }

    /// Ponto como a página aparece (origem no alto à esquerda) → espaço do PDF.
    static func displayToUser(crop: CGRect, rotation: Int, x dx: CGFloat, y dy: CGFloat) -> CGPoint {
        let x0 = crop.minX, y0 = crop.minY, x1 = crop.maxX, y1 = crop.maxY
        switch PDFOps.normalized(rotation) {
        case 90: return CGPoint(x: x0 + dy, y: y0 + dx)
        case 180: return CGPoint(x: x1 - dx, y: y0 + dy)
        case 270: return CGPoint(x: x1 - dy, y: y1 - dx)
        default: return CGPoint(x: x0 + dx, y: y1 - dy)
        }
    }

    /// Novo PDF com o número escrito em cada página (texto de verdade, em Helvetica). As páginas são
    /// redesenhadas com o mesmo tamanho, recorte e giro; destaques e outras anotações são copiados.
    static func numberedData(_ doc: PDFDocument, options o: NumberOptions) throws -> Data {
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw UserFacingError("Não foi possível preparar o PDF numerado.")
        }
        let count = doc.pageCount
        let first = max(1, min(o.firstPage, count))
        let total = o.start + (count - first)
        let font = CTFontCreateWithName("Helvetica" as CFString, o.size, nil)
        for i in 0..<count {
            guard let page = doc.page(at: i), let cgPage = page.pageRef else { continue }
            var media = page.bounds(for: .mediaBox)
            let boxData = NSData(bytes: &media, length: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            ctx.drawPDFPage(cgPage)
            if i + 1 >= first {
                let crop = page.bounds(for: .cropBox)
                let rot = PDFOps.normalized(page.rotation)
                let size = displaySize(media: crop, rotation: rot)
                let text = o.format.text(o.start + (i + 1 - first), total: total)
                let attr = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                ])
                let line = CTLineCreateWithAttributedString(attr as CFAttributedString)
                let tw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let dx: CGFloat
                switch o.position.horizontal {
                case -1: dx = o.margin
                case 1: dx = size.width - o.margin - tw
                default: dx = (size.width - tw) / 2
                }
                let dy = o.position.isTop ? o.margin + o.size * 0.72 : size.height - o.margin
                let p = displayToUser(crop: crop, rotation: rot, x: dx, y: dy)
                ctx.saveGState()
                ctx.translateBy(x: p.x, y: p.y)
                ctx.rotate(by: CGFloat(rot) * .pi / 180)
                ctx.textPosition = .zero
                ctx.setFillColor(gray: 0, alpha: 1)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        guard let numbered = PDFDocument(data: out as Data), numbered.pageCount == count else {
            throw UserFacingError("O PDF numerado não pôde ser conferido; nada foi alterado.")
        }
        for i in 0..<count {
            guard let old = doc.page(at: i), let new = numbered.page(at: i) else { continue }
            new.rotation = old.rotation
            new.setBounds(old.bounds(for: .cropBox), for: .cropBox)
            for a in old.annotations {
                if let copy = a.copy() as? PDFAnnotation { new.addAnnotation(copy) }
            }
        }
        if let attrs = doc.documentAttributes { numbered.documentAttributes = attrs }
        guard let data = numbered.dataRepresentation() else {
            throw UserFacingError("Não foi possível gravar o PDF numerado.")
        }
        return data
    }
}

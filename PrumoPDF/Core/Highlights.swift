import PDFKit
import UIKit

/// Cores do marca-texto (as mesmas do Prumo para Windows).
enum HighlightColor: String, CaseIterable, Identifiable {
    case yellow, green, blue, pink, orange
    var id: String { rawValue }

    var label: String {
        switch self {
        case .yellow: return "Amarelo"
        case .green: return "Verde"
        case .blue: return "Azul"
        case .pink: return "Rosa"
        case .orange: return "Laranja"
        }
    }

    var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .yellow: return (1.0, 0.89, 0.25)
        case .green: return (0.56, 0.87, 0.42)
        case .blue: return (0.49, 0.76, 1.0)
        case .pink: return (1.0, 0.6, 0.8)
        case .orange: return (1.0, 0.7, 0.36)
        }
    }

    var uiColor: UIColor { UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1) }
}

/// Destaques gravados no próprio PDF, como anotações padrão de destaque (/Highlight): aparecem
/// no Prumo, no Adobe, no Edge, no Chrome e no Windows, e podem ser apagados em qualquer um deles.
enum Highlights {
    static let author = "Prumo PDF"

    /// Destaca a seleção: uma anotação por página, com um quadrilátero por linha.
    /// Devolve as anotações criadas (para desfazer).
    @discardableResult
    static func add(_ selection: PDFSelection, color: HighlightColor, in document: PDFDocument) -> [PDFAnnotation] {
        var linesByPage: [Int: [(PDFPage, CGRect, String)]] = [:]
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let r = line.bounds(for: page)
                guard r.width > 0.5, r.height > 0.5 else { continue }
                let i = document.index(for: page)
                linesByPage[i, default: []].append((page, r, line.string ?? ""))
            }
        }
        var added: [PDFAnnotation] = []
        for i in linesByPage.keys.sorted() {
            guard let lines = linesByPage[i], let page = lines.first?.0 else { continue }
            let rects = lines.map { $0.1.insetBy(dx: -0.8, dy: -0.8) }
            let bounds = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            let ann = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            ann.color = color.uiColor
            ann.userName = author
            ann.contents = lines.map { $0.2 }.joined(separator: " ")
            ann.modificationDate = Date()
            _ = ann.setValue("prumo-hl-\(UUID().uuidString.prefix(16).lowercased())", forAnnotationKey: .name)
            // Quadriláteros relativos à origem da anotação: alto-esquerda, alto-direita, baixo-esquerda, baixo-direita.
            var quads: [NSValue] = []
            for r in rects {
                let x0 = r.minX - bounds.minX, x1 = r.maxX - bounds.minX
                let y0 = r.minY - bounds.minY, y1 = r.maxY - bounds.minY
                quads += [CGPoint(x: x0, y: y1), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0)]
                    .map { NSValue(cgPoint: $0) }
            }
            ann.quadrilateralPoints = quads
            page.addAnnotation(ann)
            added.append(ann)
        }
        return added
    }

    static func isHighlight(_ a: PDFAnnotation) -> Bool {
        a.type == "Highlight" || a.type == PDFAnnotationSubtype.highlight.rawValue
            || a.type == "/Highlight"
    }

    /// O destaque que está no ponto (coordenadas da página), se houver.
    static func highlight(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.last { isHighlight($0) && $0.bounds.insetBy(dx: -2, dy: -2).contains(point) && covers($0, point) }
    }

    private static func covers(_ a: PDFAnnotation, _ p: CGPoint) -> Bool {
        let q = a.quadrilateralPoints?.map { $0.cgPointValue } ?? []
        guard q.count >= 4 else { return true }
        var k = 0
        while k + 3 < q.count {
            let xs = q[k..<k + 4].map(\.x), ys = q[k..<k + 4].map(\.y)
            let r = CGRect(x: (xs.min() ?? 0) + a.bounds.minX, y: (ys.min() ?? 0) + a.bounds.minY,
                           width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
            if r.insetBy(dx: -2, dy: -2).contains(p) { return true }
            k += 4
        }
        return false
    }

    static func remove(_ a: PDFAnnotation) {
        a.page?.removeAnnotation(a)
    }

    static func recolor(_ a: PDFAnnotation, _ color: HighlightColor) {
        a.color = color.uiColor
        a.modificationDate = Date()
    }
}

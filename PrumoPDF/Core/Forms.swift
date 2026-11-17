import PDFKit
import UIKit

// Preencher formulários (o mesmo recurso do Prumo para Windows, forms.py).
//
// - Campos do PDF (AcroForm): o próprio PDFKit deixa tocar e preencher (texto, caixa de marcar, opção, lista)
//   e grava o valor no campo, com a aparência, ao salvar.
// - PDF sem campos: caixas de texto (/FreeText) e marcas (✓ ✗ com /Ink, ● com /Circle) em qualquer lugar.
//   Todas têm o nome (/NM) começando por "prumo-tx-" ou "prumo-mk-" e o estilo em /PrumoStyle e /DS, como no
//   Windows: assim as caixas feitas num aparelho continuam editáveis no outro.
// - "Finalizar": cópia com tudo gravado no desenho da página (os destaques continuam anotações).

enum FormFont: String, CaseIterable, Identifiable, Codable {
    case helvetica, times, courier
    var id: String { rawValue }

    var label: String {
        switch self {
        case .helvetica: return "Helvetica"
        case .times: return "Times"
        case .courier: return "Courier"
        }
    }

    /// Nome da família no estilo gravado no PDF (/DS), igual ao do Windows.
    var family: String {
        switch self {
        case .helvetica: return "Helvetica"
        case .times: return "Times"
        case .courier: return "Courier"
        }
    }

    func uiFont(size: CGFloat, bold: Bool) -> UIFont {
        let name: String
        switch self {
        case .helvetica: name = bold ? "Helvetica-Bold" : "Helvetica"
        case .times: name = bold ? "TimesNewRomanPS-BoldMT" : "TimesNewRomanPSMT"
        case .courier: name = bold ? "Courier-Bold" : "Courier"
        }
        return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    static func from(fontName: String) -> FormFont {
        let low = fontName.lowercased()
        if low.contains("cour") { return .courier }
        if low.contains("times") || low.contains("tiro") { return .times }
        return .helvetica
    }
}

enum FormColor: String, CaseIterable, Identifiable, Codable {
    case black, blue, red, green
    var id: String { rawValue }

    /// As mesmas cores do Windows (forms.COLORS).
    var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .black: return (0, 0, 0)
        case .blue: return (0.05, 0.20, 0.62)
        case .red: return (0.78, 0.07, 0.07)
        case .green: return (0.05, 0.45, 0.16)
        }
    }

    var uiColor: UIColor { UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1) }

    var label: String {
        switch self {
        case .black: return L("Preto")
        case .blue: return L("Azul")
        case .red: return L("Vermelho")
        case .green: return L("Verde")
        }
    }

    var hex: String {
        String(format: "#%02x%02x%02x", Int((rgb.0 * 255).rounded()), Int((rgb.1 * 255).rounded()),
               Int((rgb.2 * 255).rounded()))
    }

    static func nearest(_ color: UIColor?) -> FormColor {
        guard let color else { return .black }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return allCases.min { x, y in
            let dx = pow(x.rgb.0 - r, 2) + pow(x.rgb.1 - g, 2) + pow(x.rgb.2 - b, 2)
            let dy = pow(y.rgb.0 - r, 2) + pow(y.rgb.1 - g, 2) + pow(y.rgb.2 - b, 2)
            return dx < dy
        } ?? .black
    }
}

enum FormTool: String, CaseIterable, Identifiable {
    case select, text, check, cross, dot
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .text: return "character.textbox"
        case .check: return "checkmark"
        case .cross: return "xmark"
        case .dot: return "circle.fill"
        }
    }

    var label: String {
        switch self {
        case .select: return L("Selecionar e mover")
        case .text: return L("Texto: toque na página para escrever")
        case .check: return L("Marcar com ✓")
        case .cross: return L("Marcar com ✗")
        case .dot: return L("Marcar com ●")
        }
    }
}

struct FormStyle: Codable, Equatable {
    var font: FormFont = .helvetica
    var bold = false
    var size: CGFloat = 12
    var color: FormColor = .black
}

/// Uma caixa de texto ou marca, como ficará no PDF (coordenadas da página, origem embaixo à esquerda).
struct FormBox: Equatable {
    var page: Int
    var bounds: CGRect
    var kind: String            // "text", "check", "cross", "dot"
    var text: String
    var style: FormStyle
    var name: String            // /NM
}

enum FormBoxes {
    static let textPrefix = "prumo-tx-"
    static let markPrefix = "prumo-mk-"
    static let selectionName = "prumo-sel"
    static let styleKey = PDFAnnotationKey(rawValue: "/PrumoStyle")
    static let dsKey = PDFAnnotationKey(rawValue: "/DS")
    /// O PDFKit não grava o /NM ao salvar; a identificação vai também nesta chave (o Windows lê as duas).
    static let idKey = PDFAnnotationKey(rawValue: "/PrumoID")
    static let pad: CGFloat = 2
    static let line: CGFloat = 1.2
    static let author = "Prumo PDF"
    static let marks: [String: String] = ["check": "✓", "cross": "✗", "dot": "●"]

    static func name(of a: PDFAnnotation) -> String {
        for key in [idKey, PDFAnnotationKey.name] {
            if let s = a.value(forAnnotationKey: key) as? String, !s.isEmpty { return s }
            if let s = a.value(forAnnotationKey: key) as? NSString, s.length > 0 { return s as String }
        }
        return ""
    }

    static func isBox(_ a: PDFAnnotation) -> Bool {
        let n = name(of: a)
        if n.hasPrefix(textPrefix) || n.hasPrefix(markPrefix) { return true }
        // Sem identificação (o PDFKit pode não devolver /NM nem /PrumoID): autor "Prumo PDF" e o tipo de caixa
        return n.isEmpty && a.userName == author && (a.type == "FreeText" || a.type == "Ink")
    }

    /// Dá nome às caixas reconhecidas só pelo autor (para escolher, mover e desfazer).
    static func ensureNames(_ doc: PDFDocument) {
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where isBox(a) && name(of: a).isEmpty {
                let mark = a.type == "Ink" || marks.values.contains(a.contents ?? "")
                let id = newName(kind: mark ? "check" : "text")
                _ = a.setValue(id, forAnnotationKey: .name)
                _ = a.setValue(id, forAnnotationKey: idKey)
            }
        }
    }

    static func isSelection(_ a: PDFAnnotation) -> Bool { name(of: a) == selectionName }

    /// Tamanho da caixa: cada linha como foi digitada (sem quebra), com uma folga para o PDFKit não quebrar.
    static func size(text: String, style: FormStyle) -> CGSize {
        let font = style.font.uiFont(size: style.size, bold: style.bold)
        let lines = text.components(separatedBy: "\n")
        let w = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return CGSize(width: max(w, style.size * 0.6) + 2 * pad + 6,
                      height: CGFloat(max(1, lines.count)) * style.size * line + 2 * pad)
    }

    static func styleString(_ b: FormBox) -> String {
        let s = b.style
        let size = String(format: "%g", Double(s.size))
        var out = "font: \(size)pt \(s.font.family); font-family: \(s.font.family); font-size: \(size)pt; " +
            "font-weight: \(s.bold ? "bold" : "normal"); color: \(s.color.hex)"
        if b.kind != "text" { out += "; prumo-kind: \(b.kind)" }
        return out
    }

    static func parse(_ s: String) -> (FormStyle, String?) {
        var st = FormStyle()
        var kind: String?
        for part in s.split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "prumo-kind": if marks[kv[1]] != nil { kind = kv[1] }
            case "font-family": st.font = FormFont.from(fontName: kv[1])
            case "font-weight": st.bold = kv[1].lowercased() == "bold"
            case "font-size", "font":
                if let r = kv[1].range(of: #"[\d.]+(?=pt)"#, options: .regularExpression), let v = Double(kv[1][r]) {
                    st.size = CGFloat(min(144, max(4, v)))
                }
            case "color":
                if let c = FormColor.allCases.first(where: { $0.hex == kv[1].lowercased() }) { st.color = c }
            default: break
            }
        }
        return (st, kind)
    }

    /// As caixas do Prumo no documento (feitas no iPhone ou no Windows).
    static func read(_ doc: PDFDocument) -> [FormBox] {
        ensureNames(doc)
        var out: [FormBox] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where isBox(a) {
                let n = name(of: a)
                let raw = (a.value(forAnnotationKey: styleKey) as? String) ?? (a.value(forAnnotationKey: dsKey) as? String) ?? ""
                if a.type == "Ink", raw.isEmpty || !raw.contains("color") {
                    // marca sem estilo legível: a cor vem da própria anotação
                    var st = FormStyle()
                    st.color = FormColor.nearest(a.color)
                    let k = marks.first(where: { $0.value == (a.contents ?? "") })?.key ?? "check"
                    st.size = a.bounds.width
                    out.append(FormBox(page: i, bounds: a.bounds, kind: k, text: "", style: st, name: name(of: a)))
                    continue
                }
                var (style, kind) = parse(raw)
                if raw.isEmpty, let f = a.font {
                    style.font = FormFont.from(fontName: f.fontName)
                    style.bold = f.fontName.lowercased().contains("bold")
                    style.size = f.pointSize
                    style.color = FormColor.nearest(a.fontColor)
                }
                if n.hasPrefix(markPrefix) {
                    let k = kind ?? marks.first(where: { $0.value == (a.contents ?? "") })?.key ?? "check"
                    style.size = a.bounds.width
                    out.append(FormBox(page: i, bounds: a.bounds, kind: k, text: "", style: style, name: n))
                } else {
                    out.append(FormBox(page: i, bounds: a.bounds, kind: "text", text: a.contents ?? "", style: style, name: n))
                }
            }
        }
        return out
    }

    /// A anotação de uma caixa. Marcas: ✓ e ✗ como traços (/Ink), ● como círculo cheio (/Circle).
    static func make(_ b: FormBox) -> PDFAnnotation {
        let s = b.style
        let a: PDFAnnotation
        let border = PDFBorder()
        switch b.kind {
        case "text":
            a = PDFAnnotation(bounds: b.bounds, forType: .freeText, withProperties: nil)
            a.font = s.font.uiFont(size: s.size, bold: s.bold)
            a.fontColor = s.color.uiColor
            a.color = .clear
            a.alignment = .left
            a.contents = b.text
            border.lineWidth = 0
        case "dot":
            let d = b.bounds.width * 0.56
            let r = CGRect(x: b.bounds.midX - d / 2, y: b.bounds.midY - d / 2, width: d, height: d)
            a = PDFAnnotation(bounds: b.bounds, forType: .ink, withProperties: nil)
            // círculo cheio feito com um traço grosso em volta do centro (o /Ink desenha igual em todo leitor)
            let path = UIBezierPath(ovalIn: r.offsetBy(dx: -b.bounds.minX, dy: -b.bounds.minY).insetBy(dx: d / 4, dy: d / 4))
            a.add(path)
            a.color = s.color.uiColor
            border.lineWidth = d / 2
            a.contents = marks[b.kind]
        default:
            a = PDFAnnotation(bounds: b.bounds, forType: .ink, withProperties: nil)
            let w = b.bounds.width
            let path = UIBezierPath()
            if b.kind == "cross" {
                path.move(to: CGPoint(x: w * 0.2, y: w * 0.2))
                path.addLine(to: CGPoint(x: w * 0.8, y: w * 0.8))
                path.move(to: CGPoint(x: w * 0.2, y: w * 0.8))
                path.addLine(to: CGPoint(x: w * 0.8, y: w * 0.2))
            } else {
                path.move(to: CGPoint(x: w * 0.15, y: w * 0.52))
                path.addLine(to: CGPoint(x: w * 0.40, y: w * 0.22))
                path.addLine(to: CGPoint(x: w * 0.86, y: w * 0.82))
            }
            a.add(path)
            a.color = s.color.uiColor
            border.lineWidth = max(0.8, w * 0.12)
            a.contents = marks[b.kind]
        }
        a.border = border
        a.userName = author
        a.modificationDate = Date()
        let id = b.name.isEmpty ? newName(kind: b.kind) : b.name
        _ = a.setValue(id, forAnnotationKey: .name)
        _ = a.setValue(id, forAnnotationKey: idKey)
        let style = styleString(b)
        _ = a.setValue(style, forAnnotationKey: styleKey)
        _ = a.setValue(style.components(separatedBy: "; prumo-kind").first ?? style, forAnnotationKey: dsKey)
        return a
    }

    static func newName(kind: String) -> String {
        let id = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16))
        return (kind == "text" ? textPrefix : markPrefix) + id
    }

    /// Troca todas as caixas do Prumo do documento pelas de `boxes`.
    static func apply(_ boxes: [FormBox], to doc: PDFDocument) {
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where isBox(a) { page.removeAnnotation(a) }
        }
        for b in boxes {
            if b.kind == "text" && b.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            doc.page(at: b.page)?.addAnnotation(make(b))
        }
    }

    /// Caixas feitas no Windows chegam como /FreeText com desenho próprio; aqui viram a forma do iPhone
    /// (o desenho fica igual e o PDFKit sabe redesenhar ao mover).
    static func normalize(_ doc: PDFDocument) {
        let boxes = read(doc)
        apply(boxes.map { b in
            var b = b
            if b.kind == "text" {
                let s = size(text: b.text, style: b.style)
                b.bounds = CGRect(x: b.bounds.minX, y: b.bounds.maxY - s.height, width: s.width, height: s.height)
            }
            return b
        }, to: doc)
    }
}

enum FormFields {
    /// Os valores dos campos do PDF (para saber se algo mudou).
    static func snapshot(_ doc: PDFDocument) -> [String] {
        var out: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where a.type == "Widget" {
                out.append("\(i)|\(a.fieldName ?? "")|\(a.widgetStringValue ?? "")|\(a.buttonWidgetState.rawValue)")
            }
        }
        return out
    }

    static func count(_ doc: PDFDocument) -> Int {
        var n = 0
        for i in 0..<doc.pageCount {
            n += doc.page(at: i)?.annotations.filter { $0.type == "Widget" && $0.widgetFieldType != .signature }.count ?? 0
        }
        return n
    }

    /// Cópia "finalizada": campos e caixas gravados no desenho da página. Os destaques continuam anotações.
    static func flattened(_ doc: PDFDocument) throws -> Data {
        guard let data = doc.dataRepresentation(), let copy = PDFDocument(data: data) else {
            throw UserFacingError(L("Não foi possível salvar o PDF."))
        }
        var keep: [(Int, PDFAnnotation)] = []
        for i in 0..<copy.pageCount {
            guard let page = copy.page(at: i) else { continue }
            for a in page.annotations {
                if FormBoxes.isSelection(a) {
                    page.removeAnnotation(a)
                } else if a.type == "Highlight" {
                    keep.append((i, a))
                    page.removeAnnotation(a)
                }
            }
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard copy.write(to: tmp, withOptions: [.burnInAnnotationsOption: true]),
              let flat = PDFDocument(url: tmp), flat.pageCount == doc.pageCount else {
            throw UserFacingError(L("Não foi possível salvar o PDF."))
        }
        for (i, a) in keep { flat.page(at: i)?.addAnnotation(a) }
        guard let out = flat.dataRepresentation() else { throw UserFacingError(L("Não foi possível salvar o PDF.")) }
        return out
    }
}

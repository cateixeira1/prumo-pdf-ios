import Foundation
import PDFKit

/// Texto de um PDF organizado para leitura corrida (modo leitor):
/// as linhas de cada página são juntadas em parágrafos.
struct ReaderDocument {
    struct Page {
        let number: Int          // começa em 1
        let paragraphs: [String]
        /// Para cada parágrafo, a posição (em `page.string`, UTF-16) de cada caractere; -1 nos espaços
        /// criados ao juntar linhas. Assim um trecho escolhido no texto corrido vira um destaque no PDF.
        var maps: [[Int]] = []
        var isEmpty: Bool { paragraphs.isEmpty }
    }

    var pages: [Page]

    var plainText: String {
        pages.map { page in
            "— Página \(page.number) —\n\n" + (page.isEmpty ? "(sem texto)" : page.paragraphs.joined(separator: "\n\n"))
        }
        .joined(separator: "\n\n")
    }

    var isEmpty: Bool { pages.allSatisfy(\.isEmpty) }
}

struct TextLine {
    let text: String
    let rect: CGRect   // no espaço da página (origem embaixo à esquerda); .null quando desconhecido
    var range: NSRange? = nil   // onde o texto está em `page.string` (UTF-16)
}

enum ReaderTextBuilder {

    static func build(url: URL) -> ReaderDocument? {
        guard let doc = PDFDocument(url: url), !doc.isLocked else { return nil }
        return build(doc)
    }

    static func build(_ doc: PDFDocument) -> ReaderDocument {
        var pages: [ReaderDocument.Page] = []
        for i in 0..<doc.pageCount {
            autoreleasepool {
                guard let page = doc.page(at: i) else { return }
                let mapped = reflowMapped(lines(of: page))
                pages.append(ReaderDocument.Page(number: i + 1, paragraphs: mapped.map { $0.0 }, maps: mapped.map { $0.1 }))
            }
        }
        return ReaderDocument(pages: pages)
    }

    /// Linhas da página, com a posição de cada uma quando o PDFKit informa.
    static func lines(of page: PDFPage) -> [TextLine] {
        let full = (page.string ?? "") as NSString
        if page.rotation % 360 == 0,
           let selection = page.selection(for: page.bounds(for: .mediaBox)) {
            let byLine = selection.selectionsByLine()
                .compactMap { sel -> TextLine? in
                    let raw = sel.string ?? ""
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    var range: NSRange?
                    if sel.numberOfTextRanges(on: page) > 0 {
                        let r = sel.range(at: 0, on: page)
                        let lead = (raw as NSString).range(of: text).location
                        if r.location != NSNotFound, lead != NSNotFound {
                            let candidate = NSRange(location: r.location + lead, length: (text as NSString).length)
                            if NSMaxRange(candidate) <= full.length, full.substring(with: candidate) == text {
                                range = candidate
                            }
                        }
                    }
                    if range == nil { range = locate(text, in: full, near: 0) }
                    return TextLine(text: text, rect: sel.bounds(for: page), range: range)
                }
            if !byLine.isEmpty { return byLine }
        }
        // Sem posições: usa só o texto, linha por linha (procurando onde cada linha está).
        var cursor = 0
        return (page.string ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { text in
                let r = locate(text, in: full, near: cursor)
                if let r { cursor = NSMaxRange(r) }
                return TextLine(text: text, rect: .null, range: r)
            }
    }

    private static func locate(_ text: String, in full: NSString, near start: Int) -> NSRange? {
        guard start < full.length else { return nil }
        let r = full.range(of: text, options: [], range: NSRange(location: start, length: full.length - start))
        return r.location == NSNotFound ? nil : r
    }

    /// Como `reflow`, guardando a posição de cada caractere na página.
    static func reflowMapped(_ lines: [TextLine]) -> [(String, [Int])] {
        guard !lines.isEmpty else { return [] }
        func positions(_ line: TextLine) -> [Int] {
            let n = (line.text as NSString).length
            if let r = line.range, r.length == n { return (0..<n).map { r.location + $0 } }
            return Array(repeating: -1, count: n)
        }
        let texts = reflow(lines)
        // refaz a junção com as posições (mesmas regras de `reflow`)
        var out: [(String, [Int])] = []
        var current = ""
        var currentMap: [Int] = []
        var previous: TextLine?
        let known = lines.filter { !$0.rect.isNull && $0.rect.height > 0 }
        let medianHeight = median(known.map(\.rect.height)) ?? 0
        let maxWidth = known.map(\.rect.width).max() ?? 0
        var gaps: [CGFloat] = []
        for (a, b) in zip(lines, lines.dropFirst()) where !a.rect.isNull && !b.rect.isNull {
            let gap = a.rect.minY - b.rect.maxY
            if gap > -medianHeight * 0.5 { gaps.append(max(0, gap)) }
        }
        let paragraphGap: CGFloat
        if gaps.count >= 3, let typical = median(gaps) {
            paragraphGap = max(typical * 1.6, typical + medianHeight * 0.45)
        } else {
            paragraphGap = medianHeight * 0.9
        }
        for line in lines {
            guard let prev = previous else {
                current = line.text
                currentMap = positions(line)
                previous = line
                continue
            }
            if startsNewParagraph(line, after: prev, medianHeight: medianHeight,
                                  paragraphGap: paragraphGap, maxWidth: maxWidth) {
                out.append((current, currentMap))
                current = line.text
                currentMap = positions(line)
            } else if current.hasSuffix("-"), let first = line.text.first, first.isLowercase {
                current = String(current.dropLast()) + line.text
                currentMap = Array(currentMap.dropLast()) + positions(line)
            } else {
                current += " " + line.text
                currentMap += [-1] + positions(line)
            }
            previous = line
        }
        if !current.isEmpty { out.append((current, currentMap)) }
        // mesmo resultado de `reflow` (os dois seguem as mesmas regras)
        return out.count == texts.count ? out : texts.map { ($0, Array(repeating: -1, count: ($0 as NSString).length)) }
    }

    /// Junta as linhas em parágrafos.
    /// Começa um parágrafo novo quando há um espaço vertical maior entre as linhas, quando a linha
    /// anterior é um título em maiúsculas, quando a anterior termina uma frase e é curta, ou quando
    /// a linha começa com marcador de lista. Palavras hifenizadas no fim da linha são reunidas.
    static func reflow(_ lines: [TextLine]) -> [String] {
        guard !lines.isEmpty else { return [] }
        let known = lines.filter { !$0.rect.isNull && $0.rect.height > 0 }
        let medianHeight = median(known.map(\.rect.height)) ?? 0
        let maxWidth = known.map(\.rect.width).max() ?? 0

        // Espaço "normal" entre linhas desta página (o espaçamento varia: simples, 1,5, duplo).
        var gaps: [CGFloat] = []
        for (a, b) in zip(lines, lines.dropFirst()) where !a.rect.isNull && !b.rect.isNull {
            let gap = a.rect.minY - b.rect.maxY
            if gap > -medianHeight * 0.5 { gaps.append(max(0, gap)) }
        }
        let paragraphGap: CGFloat
        if gaps.count >= 3, let typical = median(gaps) {
            paragraphGap = max(typical * 1.6, typical + medianHeight * 0.45)
        } else {
            paragraphGap = medianHeight * 0.9
        }

        var paragraphs: [String] = []
        var current = ""
        var previous: TextLine?

        for line in lines {
            guard let prev = previous else {
                current = line.text
                previous = line
                continue
            }
            if startsNewParagraph(line, after: prev, medianHeight: medianHeight,
                                  paragraphGap: paragraphGap, maxWidth: maxWidth) {
                paragraphs.append(current)
                current = line.text
            } else if current.hasSuffix("-"), let first = line.text.first, first.isLowercase {
                current = String(current.dropLast()) + line.text
            } else {
                current += " " + line.text
            }
            previous = line
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs
    }

    static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func startsNewParagraph(_ line: TextLine, after prev: TextLine, medianHeight: CGFloat,
                                   paragraphGap: CGFloat, maxWidth: CGFloat) -> Bool {
        if isListItem(line.text) { return true }
        if isHeading(prev.text) && !isHeading(line.text) { return true }
        let endsSentence = prev.text.last.map { ".:;!?)".contains($0) } ?? false

        if !prev.rect.isNull, !line.rect.isNull, medianHeight > 0 {
            let gap = prev.rect.minY - line.rect.maxY
            if gap > paragraphGap { return true }               // espaço entre parágrafos
            if gap < -medianHeight * 2 { return true }           // voltou para cima: outra coluna
            let short = maxWidth > 0 && prev.rect.width < maxWidth * 0.7
            if endsSentence && short { return true }
            return false
        }
        // Sem posições: fim de frase seguido de letra maiúscula.
        let startsUpper = line.text.first?.isUppercase ?? false
        return endsSentence && startsUpper && prev.text.count < 60
    }

    static func isHeading(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 4 else { return false }
        let upper = letters.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        return Double(upper) / Double(letters.count) > 0.85
    }

    static func isListItem(_ text: String) -> Bool {
        if let first = text.first, "•●▪–-*".contains(first) { return true }
        // "1.", "1)", "a)", "IV -"
        let pattern = #"^(\d{1,3}[\.\)]|[a-zA-Z][\)]|[IVXLC]{1,5}\s*[-–\.])\s"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}

import CryptoKit
import Foundation
import PDFKit
import UIKit

/// Resumo de um PDF: os trechos escolhidos no leitor ("Adicionar ao resumo deste PDF") vão para um
/// PDF à parte, "Nome - resumo.pdf", na mesma pasta do original. Embaixo de cada trecho, em letra
/// menor: "Trecho extraído da página 10" ou "das páginas 10-11".
///
/// Os trechos ficam anotados em <biblioteca>/.prumo/resumos/<código>.json (o mesmo formato do
/// Prumo para Windows), para o resumo ser refeito inteiro a cada trecho novo. Se o resumo foi mudado
/// em outro programa, as páginas que ele já tem ficam como estão e os trechos novos entram depois.
enum Summary {
    static let suffix = " - resumo"

    struct Excerpt: Codable, Equatable {
        var pages: [Int]
        var text: String
        var added: String?
    }

    struct Store: Codable {
        var version = 1
        var source: String
        var title: String
        var basePages: Int
        var signature: String
        var excerpts: [Excerpt]

        enum CodingKeys: String, CodingKey {
            case version, source, title, signature, excerpts
            case basePages = "base_pages"
        }
    }

    static func name(for item: PDFItem) -> String { "\(item.name)\(suffix)" }

    static func relativePath(for item: PDFItem) -> String {
        let file = "\(name(for: item)).pdf"
        return item.folder.isEmpty ? file : "\(item.folder)/\(file)"
    }

    @MainActor
    static func find(in library: Library, for item: PDFItem) -> PDFItem? {
        let rel = relativePath(for: item).lowercased()
        return library.items.first { $0.relativePath.lowercased() == rel }
    }

    static func pagesLabel(_ pages: [Int]) -> String {
        let p = Array(Set(pages)).sorted()
        guard let a = p.first, let b = p.last else { return "Trecho extraído" }
        return a == b ? "Trecho extraído da página \(a)" : "Trecho extraído das páginas \(a)-\(b)"
    }

    static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Tamanho + SHA-1 do conteúdo: o mesmo valor no iPhone e no Windows para o mesmo arquivo.
    static func signature(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return "\(data.count)-\(sha1Hex(data))"
    }

    static func storeURL(root: URL, rel: String) -> URL {
        let key = sha1Hex(Data(rel.precomposedStringWithCanonicalMapping.lowercased().utf8)).prefix(20)
        return root.appendingPathComponent(".prumo", isDirectory: true)
            .appendingPathComponent("resumos", isDirectory: true)
            .appendingPathComponent("\(key).json")
    }

    static func loadStore(root: URL, rel: String) -> Store? {
        guard let data = try? Data(contentsOf: storeURL(root: root, rel: rel)) else { return nil }
        return try? JSONDecoder().decode(Store.self, from: data)
    }

    static func saveStore(_ store: Store, root: URL, rel: String) {
        let url = storeURL(root: root, rel: rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(store) { try? data.write(to: url, options: .atomic) }
    }

    /// Texto selecionado → texto corrido: junta as linhas, refaz palavras hifenizadas e mantém parágrafos.
    static func clean(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var paras: [String] = []
        for block in blocks {
            var cur = ""
            for raw in block.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                if cur.isEmpty {
                    cur = line
                } else if cur.hasSuffix("-"), let f = line.first, f.isLowercase,
                          let prev = cur.dropLast().last, prev.isLetter {
                    cur = String(cur.dropLast()) + line
                } else {
                    cur += " " + line
                }
            }
            let p = cur.split(whereSeparator: { $0 == " " }).joined(separator: " ")
            if !p.isEmpty { paras.append(p) }
        }
        return paras.joined(separator: "\n\n")
    }

    // MARK: - PDF do resumo

    private static func font(_ name: String, _ size: CGFloat, fallback: UIFont) -> UIFont {
        UIFont(name: name, size: size) ?? fallback
    }

    /// PDF A4 com os trechos (texto de verdade, selecionável).
    static func buildPDF(sourceName: String, excerpts: [Excerpt], header: Bool) -> Data {
        let body = NSMutableAttributedString()
        let regular = font("Helvetica", 11.5, fallback: .systemFont(ofSize: 11.5))
        let bold = font("Helvetica-Bold", 16, fallback: .boldSystemFont(ofSize: 16))
        let italic = font("Helvetica-Oblique", 9, fallback: .italicSystemFont(ofSize: 9))
        let small = font("Helvetica", 9.5, fallback: .systemFont(ofSize: 9.5))
        func para(spacing: CGFloat, before: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = spacing
            p.paragraphSpacingBefore = before
            p.lineSpacing = 2
            return p
        }
        if header {
            body.append(NSAttributedString(string: "Resumo de “\(sourceName)”\n", attributes: [
                .font: bold, .foregroundColor: UIColor(white: 0.16, alpha: 1), .paragraphStyle: para(spacing: 4)]))
            body.append(NSAttributedString(string: "Trechos selecionados no Prumo PDF, na ordem em que foram adicionados.\n",
                                           attributes: [.font: small, .foregroundColor: UIColor(white: 0.47, alpha: 1),
                                                        .paragraphStyle: para(spacing: 18)]))
        }
        for ex in excerpts {
            let paras = ex.text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !paras.isEmpty else { continue }
            for (k, p) in paras.enumerated() {
                body.append(NSAttributedString(string: p + "\n", attributes: [
                    .font: regular, .foregroundColor: UIColor(white: 0.12, alpha: 1),
                    .paragraphStyle: para(spacing: k == paras.count - 1 ? 3 : 6)]))
            }
            body.append(NSAttributedString(string: pagesLabel(ex.pages) + "\n", attributes: [
                .font: italic, .foregroundColor: UIColor(white: 0.45, alpha: 1), .paragraphStyle: para(spacing: 20)]))
        }
        let page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let textRect = page.insetBy(dx: 56.7, dy: 56.7)
        let storage = NSTextStorage(attributedString: body)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        repeat {
            let c = NSTextContainer(size: textRect.size)
            c.lineFragmentPadding = 0
            layout.addTextContainer(c)
            containers.append(c)
            let range = layout.glyphRange(for: c)
            if NSMaxRange(range) >= layout.numberOfGlyphs { break }
        } while containers.count < 5000
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "Resumo de \(sourceName)",
                               kCGPDFContextCreator as String: "Prumo PDF"]
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)
        return renderer.pdfData { ctx in
            for c in containers {
                ctx.beginPage()
                let range = layout.glyphRange(for: c)
                layout.drawBackground(forGlyphRange: range, at: textRect.origin)
                layout.drawGlyphs(forGlyphRange: range, at: textRect.origin)
            }
        }
    }

    /// As primeiras `basePages` páginas do resumo atual, seguidas dos trechos.
    static func compose(current: URL?, basePages: Int, sourceName: String, excerpts: [Excerpt]) throws -> Data {
        let generated = buildPDF(sourceName: sourceName, excerpts: excerpts, header: basePages == 0)
        guard basePages > 0, let current else { return generated }
        guard let base = PDFDocument(url: current), let gen = PDFDocument(data: generated) else {
            throw UserFacingError("Não foi possível abrir o resumo atual.")
        }
        if base.isLocked { throw UserFacingError("O resumo atual tem senha; remova a senha antes.") }
        while base.pageCount > basePages { base.removePage(at: base.pageCount - 1) }
        for i in 0..<gen.pageCount {
            if let p = gen.page(at: i)?.copy() as? PDFPage { base.insert(p, at: base.pageCount) }
        }
        guard let data = base.dataRepresentation() else { throw UserFacingError("Não foi possível gravar o resumo.") }
        return data
    }

    /// Acrescenta trechos ao resumo de `item` (criando o resumo, se preciso). Devolve o item do resumo.
    @MainActor
    static func add(_ new: [(pages: [Int], text: String)], from item: PDFItem, library: Library) async throws -> PDFItem {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let stamp = f.string(from: Date())
        let entries = new.map { Excerpt(pages: $0.pages, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                        added: stamp) }
            .filter { !$0.text.isEmpty }
        guard !entries.isEmpty else { throw UserFacingError("Selecione um trecho com texto para adicionar ao resumo.") }
        let root = library.root
        let current = find(in: library, for: item)
        var basePages = 0
        var list: [Excerpt] = []
        if let current {
            if let store = loadStore(root: root, rel: current.relativePath),
               let sig = signature(of: current.url), store.signature == sig {
                basePages = store.basePages
                list = store.excerpts
            } else {
                basePages = PDFDocument(url: current.url)?.pageCount ?? 0
            }
        }
        list += entries
        let currentURL = current?.url
        let name = item.name
        let all = list
        let base = basePages
        let data = try await Task.detached(priority: .userInitiated) {
            try compose(current: currentURL, basePages: base, sourceName: name, excerpts: all)
        }.value
        let result: PDFItem
        if let current {
            try await library.replaceContents(current, with: data, keepReview: true)
            result = library.item(id: current.id) ?? current
        } else {
            result = try library.save(newData: data, name: Summary.name(for: item), folder: item.folder)
        }
        saveStore(Store(source: item.relativePath, title: item.name, basePages: basePages,
                        signature: signature(of: result.url) ?? "", excerpts: list),
                  root: root, rel: result.relativePath)
        return result
    }
}

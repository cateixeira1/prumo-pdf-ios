import Foundation
import PDFKit

/// Onde inserir páginas novas.
enum InsertPosition: Hashable {
    case start
    case end
    case after(Int)   // depois da página N (começando em 1)

    func index(pageCount: Int) -> Int {
        switch self {
        case .start: return 0
        case .end: return pageCount
        case .after(let n): return min(max(n, 0), pageCount)
        }
    }
}

/// Uma página na tela de organização: de onde ela veio e quanto girar.
struct PageArrangementEntry: Hashable, Identifiable {
    let id = UUID()
    let sourceIndex: Int      // índice original (começando em 0)
    var extraRotation: Int = 0
}

/// Operações com PDF, sem interface. Todas trabalham com cópias das páginas,
/// porque no PDFKit uma página só pode pertencer a um documento.
enum PDFOps {

    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else {
            throw UserFacingError("Não foi possível abrir o PDF. O arquivo pode estar corrompido.")
        }
        if doc.isLocked {
            throw UserFacingError("Este PDF está protegido por senha. Remova a senha antes de editar.")
        }
        return doc
    }

    /// Cópias das páginas indicadas (números começando em 1), na ordem dada.
    static func copyPages(from doc: PDFDocument, pages: [Int]) -> [PDFPage] {
        pages.compactMap { n in
            guard n >= 1, n <= doc.pageCount, let page = doc.page(at: n - 1) else { return nil }
            return page.copy() as? PDFPage
        }
    }

    /// Insere as páginas de `source` em `target`, na posição indicada. Devolve quantas entraram.
    @discardableResult
    static func insert(pages: [Int], from source: PDFDocument, into target: PDFDocument, at position: InsertPosition) -> Int {
        let copies = copyPages(from: source, pages: pages)
        var index = position.index(pageCount: target.pageCount)
        for page in copies {
            target.insert(page, at: index)
            index += 1
        }
        return copies.count
    }

    /// Remove as páginas indicadas (começando em 1). Sempre mantém pelo menos uma página.
    static func remove(pages: [Int], from doc: PDFDocument) throws {
        let valid = Set(pages.filter { $0 >= 1 && $0 <= doc.pageCount })
        guard !valid.isEmpty else { return }
        guard valid.count < doc.pageCount else {
            throw UserFacingError("Não é possível remover todas as páginas. Para isso, exclua o documento.")
        }
        for n in valid.sorted(by: >) {
            doc.removePage(at: n - 1)
        }
    }

    /// Reorganiza o documento conforme a lista (ordem, giros e páginas excluídas).
    static func apply(arrangement: [PageArrangementEntry], to doc: PDFDocument) throws {
        guard !arrangement.isEmpty else {
            throw UserFacingError("O documento precisa ter pelo menos uma página.")
        }
        let original = (0..<doc.pageCount).compactMap { doc.page(at: $0) }
        guard original.count == doc.pageCount else { throw UserFacingError("Não foi possível ler todas as páginas.") }
        // Cópias primeiro: a mesma página pode aparecer só uma vez, mas copiar evita qualquer
        // dependência do objeto original durante a remoção.
        let newPages: [PDFPage] = try arrangement.map { entry in
            guard entry.sourceIndex >= 0, entry.sourceIndex < original.count,
                  let copy = original[entry.sourceIndex].copy() as? PDFPage else {
                throw UserFacingError("Página inválida na organização.")
            }
            copy.rotation = normalized(copy.rotation + entry.extraRotation)
            return copy
        }
        for i in stride(from: doc.pageCount - 1, through: 0, by: -1) {
            doc.removePage(at: i)
        }
        for (i, page) in newPages.enumerated() {
            doc.insert(page, at: i)
        }
    }

    static func normalized(_ degrees: Int) -> Int {
        let r = degrees % 360
        return r < 0 ? r + 360 : r
    }

    /// Novo documento só com as páginas indicadas.
    static func extract(pages: [Int], from doc: PDFDocument) -> PDFDocument {
        let out = PDFDocument()
        for (i, page) in copyPages(from: doc, pages: pages).enumerated() {
            out.insert(page, at: i)
        }
        return out
    }

    /// Divide em `parts` documentos de tamanho o mais igual possível.
    static func split(_ doc: PDFDocument, parts: Int) throws -> [PDFDocument] {
        try SplitPlan.ranges(pageCount: doc.pageCount, parts: parts).map { range in
            extract(pages: Array(range), from: doc)
        }
    }

    /// Junta vários documentos, na ordem dada.
    static func merge(_ docs: [PDFDocument]) -> PDFDocument {
        let out = PDFDocument()
        for doc in docs {
            for i in 0..<doc.pageCount {
                if let copy = doc.page(at: i)?.copy() as? PDFPage {
                    out.insert(copy, at: out.pageCount)
                }
            }
        }
        return out
    }

    /// Grava de forma segura: escreve num arquivo temporário e só então substitui o destino.
    static func write(_ doc: PDFDocument, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp.pdf")
        guard doc.write(to: tmp) else {
            try? FileManager.default.removeItem(at: tmp)
            throw UserFacingError("Não foi possível salvar o PDF.")
        }
        // Confere que o resultado abre antes de substituir o arquivo.
        guard let check = PDFDocument(url: tmp), check.pageCount == doc.pageCount else {
            try? FileManager.default.removeItem(at: tmp)
            throw UserFacingError("O PDF salvo não pôde ser conferido; nada foi alterado.")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    /// Texto de cada página.
    static func pageTexts(_ doc: PDFDocument) -> [String] {
        (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
    }

    static func usefulCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (CharacterSet.whitespacesAndNewlines.contains($1) ? 0 : 1) }
    }
}

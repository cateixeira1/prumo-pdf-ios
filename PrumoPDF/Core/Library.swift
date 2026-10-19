import Combine
import Foundation
import PDFKit

/// Informações que o app guarda sobre cada PDF (o arquivo em si fica na pasta Documentos).
struct DocMeta: Codable, Hashable {
    var id: String
    var path: String                 // caminho relativo, ex.: "Clientes/Petição.pdf"
    var favorite = false
    var pendingOCR = false           // o usuário escolheu "Mais tarde"
    var isOCRResult = false          // arquivo criado pelo OCR do app
    var ocrCopyID: String?           // cópia com OCR gerada a partir deste arquivo
    var sourceID: String?            // arquivo de origem (para os arquivos com OCR)
    var textStatus: TextStatus?
    var pageCount: Int?
    var ocrPages: [Int]?             // páginas que precisam de OCR
    var signature: String?           // tamanho + data; quando muda, o arquivo é reanalisado
    var reviewPages: [Int]?          // páginas com baixa confiança no OCR
    var ocrConfidence: Double?
    var lastOpened: Date?
    var hasUndo = false
    var added: Date?

    init(id: String = UUID().uuidString, path: String, added: Date? = Date()) {
        self.id = id
        self.path = path
        self.added = added
    }

    // Decodificação tolerante: campos novos em versões futuras não quebram os dados antigos.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        pendingOCR = try c.decodeIfPresent(Bool.self, forKey: .pendingOCR) ?? false
        isOCRResult = try c.decodeIfPresent(Bool.self, forKey: .isOCRResult) ?? false
        ocrCopyID = try c.decodeIfPresent(String.self, forKey: .ocrCopyID)
        sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID)
        textStatus = try? c.decodeIfPresent(TextStatus.self, forKey: .textStatus)
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount)
        ocrPages = try c.decodeIfPresent([Int].self, forKey: .ocrPages)
        signature = try c.decodeIfPresent(String.self, forKey: .signature)
        reviewPages = try c.decodeIfPresent([Int].self, forKey: .reviewPages)
        ocrConfidence = try c.decodeIfPresent(Double.self, forKey: .ocrConfidence)
        lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened)
        hasUndo = try c.decodeIfPresent(Bool.self, forKey: .hasUndo) ?? false
        added = try c.decodeIfPresent(Date.self, forKey: .added)
    }
}

struct PDFItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let relativePath: String
    let size: Int64
    let modified: Date
    var meta: DocMeta

    var name: String { ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension }
    var folder: String { (relativePath as NSString).deletingLastPathComponent }
    var folderName: String { folder.isEmpty ? "Sem pasta" : (folder as NSString).lastPathComponent }
    /// Muda sempre que o arquivo muda (usado no cache de miniaturas).
    var version: String { "\(size)-\(Int(modified.timeIntervalSince1970 * 1000))" }
    var pageCount: Int? { meta.pageCount }
    var lastActivity: Date { max(meta.lastOpened ?? .distantPast, modified) }
}

struct FolderItem: Identifiable, Hashable {
    var id: String { path }
    let path: String
    var name: String { (path as NSString).lastPathComponent }
    var parent: String { (path as NSString).deletingLastPathComponent }
    var depth: Int { path.split(separator: "/").count - 1 }
    let docCount: Int        // PDFs diretamente nesta pasta
    let totalDocCount: Int   // incluindo subpastas
    let subfolderCount: Int
}

enum DocList: String, Hashable, CaseIterable {
    case all, recent, pendingOCR, ocr, favorites

    var title: String {
        switch self {
        case .all: return "Todos os PDFs"
        case .recent: return "Recentes"
        case .pendingOCR: return "Aguardando OCR"
        case .ocr: return "Com OCR"
        case .favorites: return "Favoritos"
        }
    }
}

/// Biblioteca de PDFs: arquivos e pastas reais dentro de Documentos (visíveis no app Arquivos,
/// em "No meu iPhone") e metadados guardados à parte.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var items: [PDFItem] = []
    @Published private(set) var folders: [FolderItem] = []
    @Published private(set) var isAnalyzing = false

    let root: URL
    let supportDir: URL
    let versionsDir: URL
    let textCacheDir: URL
    let tempDir: URL
    private let metaURL: URL
    private var metas: [String: DocMeta] = [:]
    private var texts: [String: String] = [:]
    private var analysisTask: Task<Void, Never>?
    private let fm = FileManager.default

    /// `baseDirectory` existe para os testes; no app usa as pastas padrão do sistema.
    init(baseDirectory: URL? = nil) {
        let fm = FileManager.default
        if let base = baseDirectory {
            root = base.appendingPathComponent("Documents", isDirectory: true)
            supportDir = base.appendingPathComponent("Support", isDirectory: true)
            textCacheDir = base.appendingPathComponent("Caches/Text", isDirectory: true)
            tempDir = base.appendingPathComponent("tmp", isDirectory: true)
        } else {
            root = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PrumoPDF", isDirectory: true)
            textCacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PrumoPDF/Text", isDirectory: true)
            tempDir = fm.temporaryDirectory.appendingPathComponent("PrumoPDF", isDirectory: true)
        }
        versionsDir = supportDir.appendingPathComponent("Versions", isDirectory: true)
        metaURL = supportDir.appendingPathComponent("library.json")
        for dir in [root, supportDir, versionsDir, textCacheDir, tempDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        loadMeta()
        reload()
    }

    // MARK: - Leitura

    func reload() {
        var files: [(url: URL, rel: String, size: Int64, modified: Date)] = []
        var dirs: [String] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in en {
                let rel = relativePath(of: url)
                guard !rel.isEmpty else { continue }
                let values = try? url.resourceValues(forKeys: Set(keys))
                let isDir = values?.isDirectory ?? false
                if rel == "Inbox" || rel.hasPrefix("Inbox/") {
                    if isDir { en.skipDescendants() }
                    continue
                }
                if isDir {
                    dirs.append(rel)
                } else if url.pathExtension.lowercased() == "pdf" {
                    files.append((url, rel, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? Date()))
                }
            }
        }

        // Associa cada arquivo aos metadados pelo caminho.
        var byPath: [String: DocMeta] = [:]
        for m in metas.values { byPath[m.path] = m }
        var newMetas: [String: DocMeta] = [:]
        var newItems: [PDFItem] = []
        for f in files {
            let meta = byPath[f.rel] ?? DocMeta(path: f.rel)
            newMetas[meta.id] = meta
            newItems.append(PDFItem(id: meta.id, url: f.url, relativePath: f.rel, size: f.size,
                                    modified: f.modified, meta: meta))
        }
        // Metadados de arquivos que não existem mais: apaga versões e cache de texto.
        for (id, _) in metas where newMetas[id] == nil {
            try? fm.removeItem(at: versionsDir.appendingPathComponent("\(id).pdf"))
            try? fm.removeItem(at: textCacheDir.appendingPathComponent("\(id).txt"))
            texts[id] = nil
        }
        let changed = newMetas != metas
        metas = newMetas
        items = newItems.sorted { $0.modified > $1.modified }

        folders = dirs.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { path in
            let prefix = path + "/"
            return FolderItem(path: path,
                              docCount: newItems.filter { $0.folder == path }.count,
                              totalDocCount: newItems.filter { $0.relativePath.hasPrefix(prefix) }.count,
                              subfolderCount: dirs.filter { ($0 as NSString).deletingLastPathComponent == path }.count)
        }
        if changed { saveMeta() }
        scheduleAnalysis()
    }

    func item(id: String) -> PDFItem? { items.first { $0.id == id } }
    func item(path: String) -> PDFItem? { items.first { $0.relativePath == path } }
    func folder(path: String) -> FolderItem? { folders.first { $0.path == path } }

    func items(inFolder path: String) -> [PDFItem] {
        items.filter { $0.folder == path }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func subfolders(of path: String) -> [FolderItem] {
        folders.filter { $0.parent == path }
    }

    var topLevelFolders: [FolderItem] { subfolders(of: "") }

    func needsOCRAttention(_ item: PDFItem) -> Bool {
        let m = item.meta
        if m.isOCRResult { return false }
        if let copy = m.ocrCopyID, metas[copy] != nil { return false }
        return m.pendingOCR || (m.textStatus?.needsOCR ?? false)
    }

    func items(for list: DocList) -> [PDFItem] {
        switch list {
        case .all:
            return items
        case .recent:
            let limit = Date().addingTimeInterval(-7 * 24 * 3600)
            return items.filter { $0.lastActivity >= limit }.sorted { $0.lastActivity > $1.lastActivity }
        case .pendingOCR:
            return items.filter { needsOCRAttention($0) }
        case .ocr:
            return items.filter { $0.meta.isOCRResult }
        case .favorites:
            return items.filter { $0.meta.favorite }
        }
    }

    func count(for list: DocList) -> Int { items(for: list).count }

    // MARK: - Busca (nome e texto dos PDFs)

    nonisolated static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func search(_ query: String, in pool: [PDFItem]? = nil) -> [PDFItem] {
        let q = Self.fold(query)
        guard !q.isEmpty else { return [] }
        let source = pool ?? items
        let byName = source.filter { Self.fold($0.name).contains(q) }
        let nameIDs = Set(byName.map(\.id))
        let byText = source.filter { !nameIDs.contains($0.id) && text(for: $0.id).contains(q) }
        return byName + byText
    }

    private func text(for id: String) -> String {
        if let t = texts[id] { return t }
        let t = (try? String(contentsOf: textCacheDir.appendingPathComponent("\(id).txt"), encoding: .utf8)) ?? ""
        texts[id] = t
        return t
    }

    // MARK: - Análise em segundo plano

    nonisolated static func signature(size: Int64, modified: Date) -> String {
        "\(size)-\(Int(modified.timeIntervalSince1970))"
    }

    private func scheduleAnalysis() {
        let pending = items
            .filter { $0.meta.signature != Self.signature(size: $0.size, modified: $0.modified) }
            .map { (id: $0.id, url: $0.url, sig: Self.signature(size: $0.size, modified: $0.modified)) }
        guard !pending.isEmpty else { return }
        analysisTask?.cancel()
        isAnalyzing = true
        let cacheDir = textCacheDir
        analysisTask = Task.detached(priority: .utility) { [weak self] in
            for job in pending {
                if Task.isCancelled { return }
                let analysis = autoreleasepool { Analyzer.analyze(url: job.url) }
                let folded = Library.fold(analysis?.text ?? "")
                try? folded.write(to: cacheDir.appendingPathComponent("\(job.id).txt"),
                                  atomically: true, encoding: .utf8)
                await self?.applyAnalysis(id: job.id, signature: job.sig, analysis: analysis, folded: folded)
            }
            await self?.finishAnalysis()
        }
    }

    private func applyAnalysis(id: String, signature: String, analysis: DocumentAnalysis?, folded: String) {
        guard var meta = metas[id] else { return }
        meta.signature = signature
        meta.pageCount = analysis?.pageCount
        meta.textStatus = analysis?.status
        meta.ocrPages = analysis?.ocrPages
        metas[id] = meta
        texts[id] = folded
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].meta = meta
        }
    }

    private func finishAnalysis() {
        isAnalyzing = false
        saveMeta()
    }

    // MARK: - Metadados

    private func loadMeta() {
        guard let data = try? Data(contentsOf: metaURL),
              let list = try? JSONDecoder().decode([DocMeta].self, from: data) else { return }
        metas = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func saveMeta() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(metas.values)) else { return }
        try? data.write(to: metaURL, options: .atomic)
        BackupPolicy.apply(to: metaURL)
    }

    private func updateMeta(_ id: String, _ change: (inout DocMeta) -> Void) {
        guard var m = metas[id] else { return }
        change(&m)
        metas[id] = m
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].meta = m }
        saveMeta()
    }

    func setFavorite(_ item: PDFItem, _ value: Bool) { updateMeta(item.id) { $0.favorite = value } }
    func setPendingOCR(_ item: PDFItem, _ value: Bool) { updateMeta(item.id) { $0.pendingOCR = value } }
    func markOpened(_ item: PDFItem) { updateMeta(item.id) { $0.lastOpened = Date() } }

    // MARK: - Caminhos

    func folderURL(_ path: String) -> URL {
        path.isEmpty ? root : root.appendingPathComponent(path, isDirectory: true)
    }

    func relativePath(of url: URL) -> String {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let full = url.resolvingSymlinksInPath().standardizedFileURL.path
        if full == base { return "" }
        if full.hasPrefix(base + "/") { return String(full.dropFirst(base.count + 1)) }
        // Último recurso: compara sem resolver links simbólicos.
        let base2 = root.standardizedFileURL.path
        let full2 = url.standardizedFileURL.path
        if full2.hasPrefix(base2 + "/") { return String(full2.dropFirst(base2.count + 1)) }
        return url.lastPathComponent
    }

    static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.lowercased().hasSuffix(".pdf") { s = String(s.dropLast(4)) }
        if s.isEmpty { s = "Documento" }
        return String(s.prefix(150))
    }

    func uniqueURL(folder: String, baseName: String) -> URL {
        let dir = folderURL(folder)
        let clean = Self.sanitize(baseName)
        var candidate = dir.appendingPathComponent("\(clean).pdf")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(clean) (\(n)).pdf")
            n += 1
        }
        return candidate
    }

    // MARK: - Pastas

    @discardableResult
    func createFolder(named name: String, in parent: String = "") throws -> String {
        let clean = Self.sanitize(name).replacingOccurrences(of: ".pdf", with: "")
        let path = parent.isEmpty ? clean : parent + "/" + clean
        let url = folderURL(path)
        guard !fm.fileExists(atPath: url.path) else { throw UserFacingError("Já existe uma pasta chamada “\(clean)”.") }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        BackupPolicy.apply(to: url)
        reload()
        return path
    }

    func renameFolder(_ path: String, to newName: String) throws {
        let clean = Self.sanitize(newName)
        let parent = (path as NSString).deletingLastPathComponent
        let newPath = parent.isEmpty ? clean : parent + "/" + clean
        guard newPath != path else { return }
        guard !fm.fileExists(atPath: folderURL(newPath).path) else {
            throw UserFacingError("Já existe uma pasta chamada “\(clean)”.")
        }
        try fm.moveItem(at: folderURL(path), to: folderURL(newPath))
        let prefix = path + "/"
        for (id, meta) in metas where meta.path.hasPrefix(prefix) {
            var m = meta
            m.path = newPath + "/" + String(meta.path.dropFirst(prefix.count))
            metas[id] = m
        }
        saveMeta()
        reload()
    }

    func deleteFolder(_ path: String) throws {
        guard !path.isEmpty else { return }
        try fm.removeItem(at: folderURL(path))
        reload()
    }

    // MARK: - Arquivos

    func rename(_ item: PDFItem, to newName: String) throws {
        let clean = Self.sanitize(newName)
        let dest = folderURL(item.folder).appendingPathComponent("\(clean).pdf")
        guard dest.path != item.url.path else { return }
        if fm.fileExists(atPath: dest.path),
           dest.path.lowercased() != item.url.path.lowercased() {
            throw UserFacingError("Já existe um PDF chamado “\(clean)” nesta pasta.")
        }
        try fm.moveItem(at: item.url, to: dest)
        updateMeta(item.id) { $0.path = self.relativePath(of: dest) }
        reload()
    }

    func move(_ items: [PDFItem], toFolder folder: String) throws {
        for item in items where item.folder != folder {
            let dest = uniqueURL(folder: folder, baseName: item.name)
            try fm.moveItem(at: item.url, to: dest)
            BackupPolicy.apply(to: dest)
            metas[item.id]?.path = relativePath(of: dest)
        }
        saveMeta()
        reload()
    }

    func delete(_ items: [PDFItem]) throws {
        for item in items {
            try fm.removeItem(at: item.url)
        }
        reload()
    }

    @discardableResult
    func duplicate(_ item: PDFItem) throws -> PDFItem? {
        let dest = uniqueURL(folder: item.folder, baseName: "\(item.name) (cópia)")
        try fm.copyItem(at: item.url, to: dest)
        return register(dest) { _ in }
    }

    /// Copia PDFs de fora do app (app Arquivos, "Abrir em…", outros apps) para a biblioteca.
    @discardableResult
    func importFiles(_ urls: [URL], into folder: String = "") -> [PDFItem] {
        var paths: [String] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard url.pathExtension.lowercased() == "pdf" || PDFDocument(url: url) != nil else { continue }
            let dest = uniqueURL(folder: folder, baseName: url.deletingPathExtension().lastPathComponent)
            do {
                try fm.copyItem(at: url, to: dest)
                BackupPolicy.apply(to: dest)
                paths.append(relativePath(of: dest))
            } catch {
                continue
            }
            // Arquivos entregues por outros apps na pasta Inbox são removidos depois de copiados.
            let rel = relativePath(of: url)
            if rel.hasPrefix("Inbox/") { try? fm.removeItem(at: url) }
        }
        reload()
        return paths.compactMap { item(path: $0) }
    }

    /// Registra um arquivo recém-gravado na biblioteca.
    @discardableResult
    private func register(_ url: URL, configure: (inout DocMeta) -> Void) -> PDFItem? {
        BackupPolicy.apply(to: url)
        var meta = DocMeta(path: relativePath(of: url))
        configure(&meta)
        metas[meta.id] = meta
        saveMeta()
        reload()
        return item(id: meta.id)
    }

    /// Grava um documento novo (o trabalho pesado roda fora da tela principal).
    func save(newDocument doc: PDFDocument, name: String, folder: String,
              configure: @escaping (inout DocMeta) -> Void = { _ in }) async throws -> PDFItem {
        let dest = uniqueURL(folder: folder, baseName: name)
        try await Task.detached(priority: .userInitiated) {
            try PDFOps.write(doc, to: dest)
        }.value
        guard let item = register(dest, configure: configure) else {
            throw UserFacingError("O arquivo foi salvo, mas não apareceu na biblioteca.")
        }
        return item
    }

    func save(newData data: Data, name: String, folder: String,
              configure: @escaping (inout DocMeta) -> Void = { _ in }) throws -> PDFItem {
        let dest = uniqueURL(folder: folder, baseName: name)
        try data.write(to: dest, options: .atomic)
        guard let item = register(dest, configure: configure) else {
            throw UserFacingError("O arquivo foi salvo, mas não apareceu na biblioteca.")
        }
        return item
    }

    /// Move um arquivo pronto (ex.: resultado do OCR) para a biblioteca.
    func adopt(fileAt tmp: URL, name: String, folder: String,
               configure: (inout DocMeta) -> Void = { _ in }) throws -> PDFItem {
        let dest = uniqueURL(folder: folder, baseName: name)
        try fm.moveItem(at: tmp, to: dest)
        guard let item = register(dest, configure: configure) else {
            throw UserFacingError("O arquivo foi salvo, mas não apareceu na biblioteca.")
        }
        return item
    }

    func updateAfterOCR(original: PDFItem, result: PDFItem, report: OCRReport) {
        updateMeta(original.id) {
            $0.pendingOCR = false
            $0.ocrCopyID = result.id
        }
        updateMeta(result.id) {
            $0.isOCRResult = true
            $0.sourceID = original.id
            $0.reviewPages = report.reviewPages
            $0.ocrConfidence = report.averageConfidence
        }
    }

    /// Altera o próprio arquivo (incluir, remover, reorganizar páginas).
    /// Antes, guarda a versão atual para o "Desfazer".
    func modify(_ item: PDFItem, change: @escaping (PDFDocument) throws -> Void) async throws {
        let url = item.url
        let backup = versionsDir.appendingPathComponent("\(item.id).pdf")
        try await Task.detached(priority: .userInitiated) {
            let doc = try PDFOps.open(url)
            try change(doc)
            let fm = FileManager.default
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
            try PDFOps.write(doc, to: url)
        }.value
        BackupPolicy.apply(to: url)
        BackupPolicy.apply(to: backup)
        ThumbnailCache.shared.invalidate(url: url)
        updateMeta(item.id) {
            $0.hasUndo = true
            $0.signature = nil
            // Depois de mudar as páginas, o relatório de revisão do OCR deixa de valer.
            $0.reviewPages = nil
        }
        reload()
    }

    func canUndo(_ item: PDFItem) -> Bool {
        item.meta.hasUndo && fm.fileExists(atPath: versionsDir.appendingPathComponent("\(item.id).pdf").path)
    }

    func undo(_ item: PDFItem) throws {
        let backup = versionsDir.appendingPathComponent("\(item.id).pdf")
        guard fm.fileExists(atPath: backup.path) else {
            throw UserFacingError("Não há alteração para desfazer.")
        }
        _ = try fm.replaceItemAt(item.url, withItemAt: backup)
        BackupPolicy.apply(to: item.url)
        ThumbnailCache.shared.invalidate(url: item.url)
        updateMeta(item.id) {
            $0.hasUndo = false
            $0.signature = nil
        }
        reload()
    }

    /// Reaplica a escolha de backup a todos os arquivos.
    func applyBackupPreference() {
        let roots = [root, supportDir]
        let include = AppSettings.includeInBackup
        Task.detached(priority: .utility) {
            BackupPolicy.applyAll(roots: roots, include: include)
        }
    }

    func newTempURL(_ name: String = UUID().uuidString) -> URL {
        tempDir.appendingPathComponent("\(name).pdf")
    }

    // MARK: - Somente para demonstração e testes

    func wipeEverything() {
        analysisTask?.cancel()
        for dir in [root, supportDir, textCacheDir] {
            if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for url in contents { try? fm.removeItem(at: url) }
            }
        }
        try? fm.createDirectory(at: versionsDir, withIntermediateDirectories: true)
        metas = [:]
        texts = [:]
        reload()
    }
}

import Foundation
import PDFKit
import SwiftUI
import VisionKit

enum Route: Hashable {
    case list(DocList)
    case folders
    case folder(String)
    case document(String)
    case organize(String)
    case reader(String, mode: ReaderMode = .original)
    case settings
    case merge
}

enum ScanTarget: Identifiable, Equatable {
    case newDocument(folder: String)
    case insert(itemID: String)

    var id: String {
        switch self {
        case .newDocument(let f): return "new:\(f)"
        case .insert(let i): return "insert:\(i)"
        }
    }
}

/// Arquivos esperando a resposta "um PDF só ou um para cada" (quando há várias imagens).
struct PendingConversion: Identifiable {
    let id = UUID()
    let urls: [URL]
    let folder: String
    let imageCount: Int
}

/// Páginas escaneadas esperando a escolha de onde entrar no documento.
struct PendingScanInsert: Identifiable {
    let id = UUID()
    let itemID: String
    let data: Data
    let pageCount: Int
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let actionTitle: String?
    static func == (a: ToastMessage, b: ToastMessage) -> Bool { a.id == b.id }
}

/// Navegação e avisos do app.
@MainActor
final class AppFlow: ObservableObject {
    static let shared = AppFlow()

    @Published var path: [Route] = []
    @Published var scanTarget: ScanTarget?
    @Published var askOCRItemID: String?
    @Published var pendingScanInsert: PendingScanInsert?
    @Published var pendingConversion: PendingConversion?
    @Published var toastMessage: ToastMessage?
    @Published var busyMessage: String?
    /// PDFs já escolhidos ao abrir "Combinar" a partir de uma seleção.
    var mergePreselection: [String] = []
    /// Pasta recém-criada: ao abrir, já mostra "Adicionar PDFs".
    var pendingAddToFolder: String?
    /// Ferramenta escolhida na tela inicial, executada quando a tela do PDF abrir.
    private var pendingTool: (itemID: String, action: String)?

    /// Abre a tela do PDF já com uma ferramenta acionada ("insert", "remove", "extract", "split", "read").
    func openTool(_ action: String, on item: PDFItem) {
        pendingTool = (item.id, action)
        open(.document(item.id))
    }

    func consumeTool(for itemID: String) -> String? {
        guard let p = pendingTool, p.itemID == itemID else { return nil }
        pendingTool = nil
        return p.action
    }

    private var toastAction: (() -> Void)?
    private var toastTask: Task<Void, Never>?

    func open(_ route: Route) {
        path.append(route)
    }

    func popToRoot() {
        path.removeAll()
    }

    func toast(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        toastAction = action
        withAnimation(.spring(duration: 0.3)) {
            toastMessage = ToastMessage(text: text, actionTitle: actionTitle)
        }
        toastTask?.cancel()
        let seconds: UInt64 = actionTitle == nil ? 4 : 7
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissToast()
        }
    }

    func dismissToast() {
        withAnimation(.easeOut(duration: 0.25)) { toastMessage = nil }
        toastAction = nil
    }

    func runToastAction() {
        let action = toastAction
        dismissToast()
        action?()
    }

    func show(error: Error) {
        toast(error.localizedDescription)
    }

    // MARK: - Escanear

    func startScan(_ target: ScanTarget) {
        guard ScanService.scannerAvailable else {
            toast("O scanner de documentos não está disponível neste aparelho.")
            return
        }
        scanTarget = target
    }

    func finishScan(_ scan: VNDocumentCameraScan, target: ScanTarget, library: Library = .shared) {
        scanTarget = nil
        guard scan.pageCount > 0 else { return }
        busyMessage = "Salvando \(scan.pageCount) página\(scan.pageCount == 1 ? "" : "s")…"
        let count = scan.pageCount
        Task {
            let data = await Task.detached(priority: .userInitiated) { ScanService.makePDF(from: scan) }.value
            busyMessage = nil
            switch target {
            case .newDocument(let folder):
                do {
                    let item = try library.save(newData: data, name: ScanService.defaultName(), folder: folder)
                    askOCRItemID = item.id
                } catch {
                    show(error: error)
                }
            case .insert(let itemID):
                pendingScanInsert = PendingScanInsert(itemID: itemID, data: data, pageCount: count)
            }
        }
    }

    /// Resposta ao aviso "Usar OCR agora?".
    func answerOCR(now: Bool, library: Library = .shared, jobs: JobCenter = .shared) {
        guard let id = askOCRItemID, let item = library.item(id: id) else {
            askOCRItemID = nil
            return
        }
        askOCRItemID = nil
        if now {
            jobs.startOCR(item, library: library, flow: self)
        } else {
            library.setPendingOCR(item, true)
        }
        open(.document(item.id))
    }

    func insertScannedPages(_ pending: PendingScanInsert, at position: InsertPosition, library: Library = .shared) {
        pendingScanInsert = nil
        guard let item = library.item(id: pending.itemID) else { return }
        busyMessage = "Incluindo páginas…"
        let data = pending.data
        Task {
            do {
                try await library.modify(item) { doc in
                    guard let source = PDFDocument(data: data), source.pageCount > 0 else {
                        throw UserFacingError("Não foi possível ler as páginas escaneadas.")
                    }
                    PDFOps.insert(pages: Array(1...source.pageCount), from: source, into: doc, at: position)
                }
                busyMessage = nil
                toast("\(pending.pageCount) página\(pending.pageCount == 1 ? "" : "s") incluída\(pending.pageCount == 1 ? "" : "s").")
            } catch {
                busyMessage = nil
                show(error: error)
            }
        }
    }

    // MARK: - Arquivos vindos de outros apps

    func handleIncoming(url: URL, library: Library = .shared) {
        let imported = library.importFiles([url])
        if let first = imported.first {
            popToRoot()
            open(.document(first.id))
            toast("PDF importado: \(first.name)")
        } else {
            toast("Não foi possível importar o arquivo.")
        }
    }

    // MARK: - Converter outros arquivos em PDF

    /// Copia os arquivos escolhidos (app Arquivos, Fotos) para uma pasta temporária do app.
    func copyForConversion(_ urls: [URL]) -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let dest = dir.appendingPathComponent(url.lastPathComponent)
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { out.append(dest) }
        }
        return out
    }

    /// Começa a conversão: com várias imagens, pergunta antes se viram um PDF só.
    func startConversion(_ urls: [URL], folder: String = "", alreadyLocal: Bool = false) {
        let local = alreadyLocal ? urls : copyForConversion(urls)
        guard !local.isEmpty else {
            toast("Não foi possível ler os arquivos escolhidos.")
            return
        }
        let images = local.filter { Converter.kind(of: $0) == .image }.count
        if images > 1 {
            pendingConversion = PendingConversion(urls: local, folder: folder, imageCount: images)
        } else {
            Task { await runConversion(local, folder: folder, combine: false) }
        }
    }

    func answerConversion(combine: Bool) {
        guard let p = pendingConversion else { return }
        pendingConversion = nil
        Task { await runConversion(p.urls, folder: p.folder, combine: combine) }
    }

    /// Converte e guarda na biblioteca. Fotos: pergunta "Usar OCR agora?" (ou deixam aguardando OCR).
    @discardableResult
    func runConversion(_ urls: [URL], folder: String, combine: Bool, askOCR: Bool = true,
                       library: Library = .shared) async -> [PDFItem] {
        busyMessage = "Convertendo em PDF…"
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "dd-MM-yyyy HH'h'mm"
        let result = await Converter.convert(urls: urls, combineImages: combine,
                                             combinedName: "Imagens \(f.string(from: Date()))")
        busyMessage = nil
        var failed = result.failed
        var items: [PDFItem] = []
        var imageItems: [PDFItem] = []
        for out in result.outputs {
            do {
                let item = try library.save(newData: out.data, name: out.name, folder: folder)
                items.append(item)
                if out.fromImages { imageItems.append(item) }
            } catch {
                failed.append((out.name, error.localizedDescription))
            }
        }
        if let dir = urls.first?.deletingLastPathComponent(), dir.lastPathComponent.hasPrefix("conv-") {
            try? FileManager.default.removeItem(at: dir)
        }
        if items.isEmpty {
            if let first = failed.first { toast("Não foi possível converter “\(first.0)”: \(first.1)") }
            return []
        }
        if askOCR && items.count == 1 && imageItems.count == 1 {
            askOCRItemID = imageItems[0].id   // a pergunta abre o PDF depois da resposta
        } else {
            for item in imageItems { library.setPendingOCR(item, true) }
            var msg = items.count == 1 ? "PDF criado: \(items[0].name)" : "\(items.count) PDFs criados"
            if !imageItems.isEmpty && askOCR { msg += ". Os de fotos estão em Aguardando OCR." }
            if !failed.isEmpty { msg += " \(failed.count) não \(failed.count == 1 ? "foi convertido" : "foram convertidos")." }
            let first = items[0]
            if items.count == 1 {
                toast(msg, actionTitle: "Abrir") { [weak self] in self?.open(.document(first.id)) }
            } else {
                toast(msg)
            }
        }
        return items
    }
}

import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Pedido para abrir o seletor de páginas.
struct PagePickerRequest: Identifiable {
    enum Kind { case insertFromFile, remove, extract }
    let id = UUID()
    let kind: Kind
    let sourceURL: URL
    let sourceVersion: String
    let sourceTitle: String
}

struct DocumentDetailScreen: View {
    let itemID: String
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @EnvironmentObject private var jobs: JobCenter
    @Environment(\.dismiss) private var dismiss
    @StateObject private var actions = ItemActions()
    @State private var showInsertMenu = false
    @State private var showLibraryInsert = false
    @State private var showFileImporter = false
    @State private var pickerRequest: PagePickerRequest?
    @State private var showSplit = false
    @State private var confirmUndo = false
    @State private var showReadChoice = false
    @State private var showDewarp = false
    @State private var showProtect = false
    @State private var askUnprotect = false
    @State private var unprotectText = ""
    @State private var showCrop = false
    @State private var showNumber = false

    private var item: PDFItem? { library.item(id: itemID) }

    var body: some View {
        Group {
            if let item {
                content(item)
            } else {
                Screen {
                    EmptyStateView(systemImage: "doc.questionmark", title: "PDF não encontrado",
                                   message: "O arquivo foi movido ou apagado.")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ item: PDFItem) -> some View {
        let pages = item.pageCount ?? 0
        let ocrBusy = jobs.isBusy(with: item.id)
        Screen {
            header(item)
            if let review = item.meta.reviewPages, !review.isEmpty {
                TileCard {
                    Label {
                        Text("Revise as páginas \(PageSelection.format(review)): o OCR teve baixa confiança nelas. Confira nomes, datas, números e valores no original.")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.text)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                    }
                }
            }
            TileGrid {
                Tile(title: "Ler", systemImage: "book.fill", color: Theme.blue,
                     subtitle: hasOCRText(item) ? "Original ou modo leitor" : nil) {
                    library.markOpened(item)
                    if hasOCRText(item) {
                        showReadChoice = true
                    } else {
                        flow.open(.reader(item.id))
                    }
                }
                ShareLink(item: item.url) {
                    TileLabel(title: "Compartilhar", systemImage: "square.and.arrow.up", color: Theme.green,
                              subtitle: "E-mail, WhatsApp, Arquivos")
                }
                .buttonStyle(TileButtonStyle(color: Theme.green))
                Tile(title: "OCR", systemImage: "text.viewfinder", color: Theme.orange, count: ocrCount(item),
                     shape: .rounded, subtitle: ocrSubtitle(item, busy: ocrBusy)) {
                    startOCR(item)
                }
                Tile(title: "Organizar páginas", systemImage: "rectangle.grid.2x2.fill", color: Theme.purple,
                     count: pages > 0 ? "\(pages)" : nil, shape: .rounded) {
                    flow.open(.organize(item.id))
                }
                Tile(title: "Incluir páginas", systemImage: "plus.rectangle.on.rectangle", color: Theme.teal,
                     shape: .rounded) {
                    showInsertMenu = true
                }
                Tile(title: "Remover páginas", systemImage: "minus.rectangle", color: Theme.red, shape: .rounded) {
                    pickerRequest = PagePickerRequest(kind: .remove, sourceURL: item.url,
                                                      sourceVersion: item.version, sourceTitle: item.name)
                }
                Tile(title: "Dividir em partes", systemImage: "scissors", color: Theme.pink) {
                    showSplit = true
                }
                Tile(title: "Corrigir páginas curvas", systemImage: "book.pages", color: Theme.teal, shape: .rounded,
                     subtitle: "Fotos de livros, papel ondulado") {
                    showDewarp = true
                }
                Tile(title: "Extrair páginas", systemImage: "doc.badge.plus", color: Theme.indigo) {
                    pickerRequest = PagePickerRequest(kind: .extract, sourceURL: item.url,
                                                      sourceVersion: item.version, sourceTitle: item.name)
                }
                Tile(title: "Cortar e girar", systemImage: "crop.rotate", color: Theme.indigo, shape: .rounded,
                     subtitle: "Margens e orientação") {
                    if item.meta.locked == true { lockedToast() } else { showCrop = true }
                }
                Tile(title: "Numerar páginas", systemImage: "number", color: Theme.indigo,
                     subtitle: "Posição e formato") {
                    if item.meta.locked == true { lockedToast() } else { showNumber = true }
                }
                Tile(title: "Renomear", systemImage: "pencil", color: Theme.gray) {
                    actions.rename(item)
                }
                Tile(title: "Mover", systemImage: "folder.fill", color: Theme.brown, subtitle: item.folderName) {
                    actions.move([item])
                }
                Tile(title: item.meta.favorite ? "Favorito" : "Favoritar", systemImage: "star.fill",
                     color: Theme.yellow, shape: .rounded, selected: item.meta.favorite) {
                    library.setFavorite(item, !item.meta.favorite)
                }
                if item.meta.locked == true {
                    Tile(title: "Remover senha", systemImage: "lock.open.fill", color: Theme.purple, shape: .rounded,
                         subtitle: "Cria uma cópia sem senha") {
                        askUnprotect = true
                    }
                } else {
                    Tile(title: "Proteger com senha", systemImage: "lock.fill", color: Theme.purple, shape: .rounded,
                         subtitle: "Criptografia padrão de PDF") {
                        showProtect = true
                    }
                }
                Tile(title: "Duplicar", systemImage: "plus.square.on.square", color: Theme.gray, shape: .rounded) {
                    do {
                        if let copy = try library.duplicate(item) {
                            flow.toast("Cópia criada: \(copy.name)")
                        }
                    } catch { flow.show(error: error) }
                }
            }
            if library.canUndo(item) {
                WideTile(title: "Desfazer última alteração", systemImage: "arrow.uturn.backward", color: Theme.gray,
                         subtitle: "Volta o arquivo para como estava antes da última mudança nas páginas") {
                    confirmUndo = true
                }
            }
            WideTile(title: "Excluir", systemImage: "trash.fill", color: Theme.red) {
                actions.delete([item])
            }
        }
        .navigationTitle(item.name)
        .modifier(ItemActionsModifier(actions: actions, onDeleted: { dismiss() }))
        .confirmationDialog("Incluir páginas", isPresented: $showInsertMenu, titleVisibility: .visible) {
            Button("Escanear páginas") { flow.startScan(.insert(itemID: item.id)) }
            Button("De outro PDF da biblioteca") { showLibraryInsert = true }
            Button("Do app Arquivos") { showFileImporter = true }
            Button("Cancelar", role: .cancel) {}
        }
        .confirmationDialog("Como você quer ler?", isPresented: $showReadChoice, titleVisibility: .visible) {
            Button("Como foi escaneado") { flow.open(.reader(item.id, mode: .original)) }
            Button("Modo leitor (só o texto)") { flow.open(.reader(item.id, mode: .text)) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("O modo leitor mostra o texto reconhecido pelo OCR em fundo branco, como uma nota. Dá para alternar entre os dois a qualquer momento.")
        }
        .confirmationDialog("Desfazer a última alteração?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Desfazer") {
                do {
                    try library.undo(item)
                    flow.toast("Alteração desfeita.")
                } catch { flow.show(error: error) }
            }
            Button("Cancelar", role: .cancel) {}
        }
        .sheet(isPresented: $showLibraryInsert) {
            InsertFromLibrarySheet(target: item, initialSourceID: DemoSeeder.consumePickerSource())
                .appEnvironment()
        }
        .sheet(item: $pickerRequest) { request in
            NavigationStack {
                pagePicker(for: request, target: item)
            }
            .appEnvironment()
        }
        .sheet(isPresented: $showProtect) {
            ProtectSheet(item: item)
                .appEnvironment()
        }
        .alert("Remover a senha", isPresented: $askUnprotect) {
            SecureField("Senha atual", text: $unprotectText)
            Button("Cancelar", role: .cancel) { unprotectText = "" }
            Button("Remover") {
                do {
                    let new = try library.unprotect(item, password: unprotectText)
                    flow.toast("Cópia sem senha: \(new.name)", actionTitle: "Abrir") { flow.open(.document(new.id)) }
                } catch { flow.show(error: error) }
                unprotectText = ""
            }
        } message: {
            Text("Cria uma cópia sem senha, para fazer OCR, organizar ou dividir. O PDF com senha continua guardado.")
        }
        .sheet(isPresented: $showDewarp) {
            DewarpSheet(item: item)
                .appEnvironment()
        }
        .sheet(isPresented: $showSplit) {
            SplitSheet(item: item)
                .appEnvironment()
        }
        .sheet(isPresented: $showCrop) {
            CropSheet(item: item)
                .appEnvironment()
        }
        .sheet(isPresented: $showNumber) {
            NumberSheet(item: item)
                .appEnvironment()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [UTType.pdf]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let tmp = library.newTempURL()
            do {
                try FileManager.default.copyItem(at: url, to: tmp)
                pickerRequest = PagePickerRequest(kind: .insertFromFile, sourceURL: tmp, sourceVersion: UUID().uuidString,
                                                  sourceTitle: url.deletingPathExtension().lastPathComponent)
            } catch {
                flow.show(error: error)
            }
        }
        .onAppear {
            // Ferramenta pedida na tela inicial (ou captura de tela de demonstração).
            switch flow.consumeTool(for: item.id) ?? DemoSeeder.consumeDetailAction() {
            case "split"?: showSplit = true
            case "picker"?: showLibraryInsert = true
            case "readchoice"?: showReadChoice = true
            case "dewarp"?: showDewarp = true
            case "insert"?: showInsertMenu = true
            case "insertLibrary"?: showLibraryInsert = true
            case "insertFile"?: showFileImporter = true
            case "crop"?: if item.meta.locked == true { lockedToast() } else { showCrop = true }
            case "number"?: if item.meta.locked == true { lockedToast() } else { showNumber = true }
            case "protect"?: showProtect = true
            case "remove"?:
                pickerRequest = PagePickerRequest(kind: .remove, sourceURL: item.url,
                                                  sourceVersion: item.version, sourceTitle: item.name)
            case "extract"?:
                pickerRequest = PagePickerRequest(kind: .extract, sourceURL: item.url,
                                                  sourceVersion: item.version, sourceTitle: item.name)
            case "read"?:
                library.markOpened(item)
                if hasOCRText(item) { showReadChoice = true } else { flow.open(.reader(item.id)) }
            default: break
            }
        }
    }

    @ViewBuilder
    private func pagePicker(for request: PagePickerRequest, target: PDFItem) -> some View {
        switch request.kind {
        case .insertFromFile:
            PagePickerScreen(mode: .insert(targetPageCount: target.pageCount ?? 0),
                             sourceURL: request.sourceURL, sourceVersion: request.sourceVersion,
                             sourceTitle: request.sourceTitle) { pages, position in
                let src = request.sourceURL
                try await library.modify(target) { doc in
                    let source = try PDFOps.open(src)
                    PDFOps.insert(pages: pages, from: source, into: doc, at: position)
                }
                try? FileManager.default.removeItem(at: src)
                flow.toast("\(pages.count.pagesText) incluída\(pages.count == 1 ? "" : "s").")
            }
        case .remove:
            PagePickerScreen(mode: .remove, sourceURL: request.sourceURL, sourceVersion: request.sourceVersion,
                             sourceTitle: request.sourceTitle) { pages, _ in
                try await library.modify(target) { doc in
                    try PDFOps.remove(pages: pages, from: doc)
                }
                flow.toast("\(pages.count.pagesText) removida\(pages.count == 1 ? "" : "s"). Use “Desfazer” se precisar.")
            }
        case .extract:
            PagePickerScreen(mode: .extract, sourceURL: request.sourceURL, sourceVersion: request.sourceVersion,
                             sourceTitle: request.sourceTitle) { pages, _ in
                let src = request.sourceURL
                let newDoc = try await Task.detached(priority: .userInitiated) {
                    PDFOps.extract(pages: pages, from: try PDFOps.open(src))
                }.value
                let label = PageSelection.format(pages)
                let name = label.count <= 40 ? "\(target.name) - págs. \(label)" : "\(target.name) - \(pages.count) páginas"
                let saved = try await library.save(newDocument: newDoc, name: name, folder: target.folder)
                flow.toast("Novo PDF: \(saved.name)", actionTitle: "Abrir") { flow.open(.document(saved.id)) }
            }
        }
    }

    private func header(_ item: PDFItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            PageThumbnailView(url: item.url, version: item.version, width: 92)
                .frame(width: 92, height: 124)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                .onTapGesture { flow.open(.reader(item.id)) }
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text([item.pageCount.map { $0.pagesText }, item.size.fileSizeText].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                Label(item.folderName, systemImage: "folder")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.secondaryText)
                Text("Alterado em \(item.modified.shortText)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                HStack(spacing: 4) {
                    if let status = item.meta.textStatus {
                        Badge(text: status.label, color: status.needsOCR ? Theme.orange : Theme.blue)
                    }
                    if item.meta.isOCRResult { Badge(text: "OCR", color: Theme.green) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).fill(Theme.tile))
    }

    private func lockedToast() {
        flow.toast("Este PDF tem senha. Para cortar, girar ou numerar, crie antes uma cópia sem senha (“Remover senha”).")
    }

    /// PDF com texto vindo do OCR (o próprio arquivo com OCR, ou o escaneado que já tem cópia com OCR).
    private func hasOCRText(_ item: PDFItem) -> Bool {
        if item.meta.isOCRResult { return true }
        if let copyID = item.meta.ocrCopyID, library.item(id: copyID) != nil { return true }
        return false
    }

    private func ocrCount(_ item: PDFItem) -> String? {
        if let copyID = item.meta.ocrCopyID, library.item(id: copyID) != nil { return nil }
        guard let n = item.meta.ocrPages?.count, n > 0, !item.meta.isOCRResult else { return nil }
        return "\(n)"
    }

    private func ocrSubtitle(_ item: PDFItem, busy: Bool) -> String {
        if busy { return "Em andamento…" }
        if item.meta.isOCRResult { return "Já tem OCR" }
        if let copyID = item.meta.ocrCopyID, library.item(id: copyID) != nil { return "Cópia com OCR criada" }
        switch item.meta.textStatus {
        case .digital: return "Já tem texto"
        case .scanned, .mixed:
            let n = item.meta.ocrPages?.count ?? 0
            return n == 1 ? "1 página em imagem" : "\(n) páginas em imagem"
        default: return "Verificando…"
        }
    }

    private func startOCR(_ item: PDFItem) {
        if jobs.isBusy(with: item.id) {
            flow.toast("O OCR deste PDF já está em andamento.")
        } else if item.meta.textStatus == .digital {
            flow.toast("Todas as páginas já têm texto selecionável. O OCR não é necessário.")
        } else {
            jobs.startOCR(item, library: library, flow: flow)
        }
    }
}

/// Incluir páginas de outro PDF da biblioteca: escolher o PDF e depois as páginas.
struct InsertFromLibrarySheet: View {
    let target: PDFItem
    var initialSourceID: String? = nil
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            DocumentChooser(title: "De qual PDF?", excluding: [target.id],
                            onDone: { items in if let first = items.first { path.append(first.id) } },
                            onCancel: { dismiss() })
                .onAppear {
                    if let initialSourceID, path.isEmpty { path = [initialSourceID] }
                }
                .navigationDestination(for: String.self) { sourceID in
                    if let source = library.item(id: sourceID) {
                        PagePickerScreen(mode: .insert(targetPageCount: target.pageCount ?? 0),
                                         sourceURL: source.url, sourceVersion: source.version,
                                         sourceTitle: source.name,
                                         initialSelection: initialSourceID == nil ? nil : "2, 5-9",
                                         dismissAll: { dismiss() }) { pages, position in
                            let src = source.url
                            try await library.modify(target) { doc in
                                let sourceDoc = try PDFOps.open(src)
                                PDFOps.insert(pages: pages, from: sourceDoc, into: doc, at: position)
                            }
                            flow.toast("\(pages.count.pagesText) de “\(source.name)” incluída\(pages.count == 1 ? "" : "s").")
                        }
                    }
                }
        }
    }
}

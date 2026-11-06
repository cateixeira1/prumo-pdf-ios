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
    @State private var showSign = false

    private var item: PDFItem? { library.item(id: itemID) }

    var body: some View {
        Group {
            if let item {
                content(item)
            } else {
                Screen {
                    EmptyStateView(systemImage: "doc.questionmark", title: L("PDF não encontrado"),
                                   message: L("O arquivo foi movido ou apagado."))
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
                        Text(LF("Revise as páginas {}: o OCR teve baixa confiança nelas. Confira nomes, datas, números e valores no original.", PageSelection.format(review)))
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.text)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                    }
                }
            }
            if item.meta.isSigned { signedCard(item) }
            TileGrid {
                Tile(title: L("Ler"), systemImage: "book.fill", color: Theme.blue,
                     subtitle: hasOCRText(item) ? L("Original ou modo leitor") : nil) {
                    library.markOpened(item)
                    if hasOCRText(item) {
                        showReadChoice = true
                    } else {
                        flow.open(.reader(item.id))
                    }
                }
                ShareLink(item: item.url) {
                    TileLabel(title: L("Compartilhar"), systemImage: "square.and.arrow.up", color: Theme.green,
                              subtitle: L("E-mail, WhatsApp, Arquivos"))
                }
                .buttonStyle(TileButtonStyle(color: Theme.green))
                Tile(title: "OCR", systemImage: "text.viewfinder", color: Theme.orange, count: ocrCount(item),
                     shape: .rounded, subtitle: ocrSubtitle(item, busy: ocrBusy)) {
                    startOCR(item)
                }
                Tile(title: L("Organizar páginas"), systemImage: "rectangle.grid.2x2.fill", color: Theme.purple,
                     count: pages > 0 ? "\(pages)" : nil, shape: .rounded) {
                    edit(item) { flow.open(.organize(item.id)) }
                }
                Tile(title: L("Incluir páginas"), systemImage: "plus.rectangle.on.rectangle", color: Theme.teal,
                     shape: .rounded) {
                    edit(item) { showInsertMenu = true }
                }
                Tile(title: L("Remover páginas"), systemImage: "minus.rectangle", color: Theme.red, shape: .rounded) {
                    edit(item) {
                        pickerRequest = PagePickerRequest(kind: .remove, sourceURL: item.url,
                                                          sourceVersion: item.version, sourceTitle: item.name)
                    }
                }
                Tile(title: L("Dividir em partes"), systemImage: "scissors", color: Theme.pink) {
                    showSplit = true
                }
                Tile(title: L("Corrigir páginas curvas"), systemImage: "book.pages", color: Theme.teal, shape: .rounded,
                     subtitle: L("Fotos de livros, papel ondulado")) {
                    edit(item) { showDewarp = true }
                }
                Tile(title: L("Extrair páginas"), systemImage: "doc.badge.plus", color: Theme.indigo) {
                    pickerRequest = PagePickerRequest(kind: .extract, sourceURL: item.url,
                                                      sourceVersion: item.version, sourceTitle: item.name)
                }
                Tile(title: L("Cortar e girar"), systemImage: "crop.rotate", color: Theme.indigo, shape: .rounded,
                     subtitle: L("Margens e orientação")) {
                    if item.meta.locked == true { lockedToast() } else { edit(item) { showCrop = true } }
                }
                Tile(title: L("Numerar páginas"), systemImage: "number", color: Theme.indigo,
                     subtitle: L("Posição e formato")) {
                    if item.meta.locked == true { lockedToast() } else { edit(item) { showNumber = true } }
                }
                signTile(item)
                Tile(title: L("Renomear"), systemImage: "pencil", color: Theme.gray) {
                    actions.rename(item)
                }
                Tile(title: L("Mover"), systemImage: "folder.fill", color: Theme.brown, subtitle: item.folderName) {
                    actions.move([item])
                }
                Tile(title: item.meta.favorite ? L("Favorito") : L("Favoritar"), systemImage: "star.fill",
                     color: Theme.yellow, shape: .rounded, selected: item.meta.favorite) {
                    library.setFavorite(item, !item.meta.favorite)
                }
                if item.meta.locked == true {
                    Tile(title: L("Remover senha"), systemImage: "lock.open.fill", color: Theme.purple, shape: .rounded,
                         subtitle: L("Cria uma cópia sem senha")) {
                        askUnprotect = true
                    }
                } else {
                    Tile(title: L("Proteger com senha"), systemImage: "lock.fill", color: Theme.purple, shape: .rounded,
                         subtitle: L("Criptografia padrão de PDF")) {
                        edit(item) { showProtect = true }
                    }
                }
                Tile(title: L("Duplicar"), systemImage: "plus.square.on.square", color: Theme.gray, shape: .rounded) {
                    do {
                        if let copy = try library.duplicate(item) {
                            flow.toast(LF("Cópia criada: {}", copy.name))
                        }
                    } catch { flow.show(error: error) }
                }
            }
            if library.canUndo(item) {
                WideTile(title: L("Desfazer última alteração"), systemImage: "arrow.uturn.backward", color: Theme.gray,
                         subtitle: L("Volta o arquivo para como estava antes da última mudança nas páginas")) {
                    confirmUndo = true
                }
            }
            WideTile(title: L("Excluir"), systemImage: "trash.fill", color: Theme.red) {
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
                    flow.toast(L("Alteração desfeita."))
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
                    flow.toast(LF("Cópia sem senha: {}", new.name), actionTitle: L("Abrir")) { flow.open(.document(new.id)) }
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
            let requested = flow.consumeTool(for: item.id) ?? DemoSeeder.consumeDetailAction()
            let editing: Set<String> = ["crop", "number", "protect", "dewarp", "insert", "insertLibrary", "insertFile", "remove"]
            if let r = requested, editing.contains(r), item.meta.isSigned {
                edit(item) {}
                return
            }
            switch requested {
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
            case "sign"?: showSign = true
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
                flow.toast(LN(pages.count, "1 página incluída.", "{} páginas incluídas."))
            }
        case .remove:
            PagePickerScreen(mode: .remove, sourceURL: request.sourceURL, sourceVersion: request.sourceVersion,
                             sourceTitle: request.sourceTitle) { pages, _ in
                try await library.modify(target) { doc in
                    try PDFOps.remove(pages: pages, from: doc)
                }
                flow.toast(LN(pages.count, "1 página removida. Use “Desfazer” se precisar.", "{} páginas removidas. Use “Desfazer” se precisar."))
            }
        case .extract:
            PagePickerScreen(mode: .extract, sourceURL: request.sourceURL, sourceVersion: request.sourceVersion,
                             sourceTitle: request.sourceTitle) { pages, _ in
                let src = request.sourceURL
                let newDoc = try await Task.detached(priority: .userInitiated) {
                    PDFOps.extract(pages: pages, from: try PDFOps.open(src))
                }.value
                let label = PageSelection.format(pages)
                let name = label.count <= 40 ? LF("{} - págs. {}", target.name, label) : LF("{} - {} páginas", target.name, pages.count)
                let saved = try await library.save(newDocument: newDoc, name: name, folder: target.folder)
                flow.toast(LF("Novo PDF: {}", saved.name), actionTitle: L("Abrir")) { flow.open(.document(saved.id)) }
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
                Text(LF("Alterado em {}", item.modified.shortText))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                HStack(spacing: 4) {
                    if let status = item.meta.textStatus {
                        Badge(text: status.label, color: status.needsOCR ? Theme.orange : Theme.blue)
                    }
                    if item.meta.isOCRResult { Badge(text: "OCR", color: Theme.green) }
                    if item.meta.isSigned { Badge(text: L("Assinado"), color: Theme.blue) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).fill(Theme.tile))
    }

    /// PDF assinado não pode ser alterado (qualquer mudança invalida a assinatura).
    private func edit(_ item: PDFItem, _ action: () -> Void) {
        if item.meta.isSigned {
            flow.toast(L("Este PDF está assinado digitalmente: qualquer alteração invalidaria a assinatura. Use o original, sem assinatura, para mudar páginas, cortar ou numerar."))
        } else {
            action()
        }
    }

    private func signTile(_ item: PDFItem) -> some View {
        Tile(title: L("Assinar digitalmente"), systemImage: "signature", color: Theme.blue, shape: .rounded,
             subtitle: item.meta.isSigned ? L("Assinado · assinar de novo") : L("Certificado A1")) {
            if item.meta.locked == true {
                flow.toast(L("PDF com senha não pode ser assinado. Remova a senha antes."))
            } else {
                showSign = true
            }
        }
        .sheet(isPresented: $showSign) {
            SignSheet(item: item).appEnvironment()
        }
    }

    private func signedCard(_ item: PDFItem) -> some View {
        let n = item.meta.signed ?? 1
        let count: String = n == 1 ? L("1 assinatura") : LF("{} assinaturas", n)
        return TileCard {
            Label {
                Text(LF("Assinado digitalmente ({}). O PDF não pode ser alterado sem invalidar a assinatura. Para conferir a validade, abra no Adobe Reader ou em validar.iti.gov.br.", count))
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.text)
            } icon: {
                Image(systemName: "signature").foregroundStyle(Theme.blue)
            }
        }
    }

    private func lockedToast() {
        flow.toast(L("Este PDF tem senha. Para cortar, girar ou numerar, crie antes uma cópia sem senha (“Remover senha”)."))
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
        if busy { return L("Em andamento…") }
        if item.meta.isOCRResult { return L("Já tem OCR") }
        if let copyID = item.meta.ocrCopyID, library.item(id: copyID) != nil { return L("Cópia com OCR criada") }
        switch item.meta.textStatus {
        case .digital: return L("Já tem texto")
        case .scanned, .mixed:
            let n = item.meta.ocrPages?.count ?? 0
            return n == 1 ? L("1 página em imagem") : LF("{} páginas em imagem", n)
        default: return L("Verificando…")
        }
    }

    private func startOCR(_ item: PDFItem) {
        if jobs.isBusy(with: item.id) {
            flow.toast(L("O OCR deste PDF já está em andamento."))
        } else if item.meta.textStatus == .digital {
            flow.toast(L("Todas as páginas já têm texto selecionável. O OCR não é necessário."))
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
            DocumentChooser(title: L("De qual PDF?"), excluding: [target.id],
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
                            flow.toast(LN(pages.count, "1 página de “{}” incluída.", "{} páginas de “{}” incluídas.", source.name))
                        }
                    }
                }
        }
    }
}

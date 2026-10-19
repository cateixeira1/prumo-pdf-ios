import SwiftUI
import UniformTypeIdentifiers

enum DocSort: String, CaseIterable, Identifiable {
    case recent = "Mais recentes"
    case name = "Nome"
    case pages = "Número de páginas"
    var id: String { rawValue }
}

/// Lista de PDFs em cartões: usada pelas listas da tela inicial e pelas pastas.
struct DocumentGridScreen: View {
    enum Source: Hashable {
        case list(DocList)
        case folder(String)
    }

    let source: Source
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @EnvironmentObject private var jobs: JobCenter
    @StateObject private var actions = ItemActions()
    @StateObject private var folderActions = FolderActions()
    @State private var query = ""
    @State private var selecting = false
    @State private var selected: [String] = []    // na ordem em que foram tocados
    @State private var sort: DocSort = .recent
    @State private var showImporter = false

    private var folderPath: String? {
        if case .folder(let p) = source { return p }
        return nil
    }

    private var title: String {
        switch source {
        case .list(let l): return l.title
        case .folder(let p): return p.isEmpty ? "Sem pasta" : (p as NSString).lastPathComponent
        }
    }

    private var baseItems: [PDFItem] {
        switch source {
        case .list(let l): return library.items(for: l)
        case .folder(let p): return library.items(inFolder: p)
        }
    }

    private var docs: [PDFItem] {
        let base = query.trimmingCharacters(in: .whitespaces).isEmpty ? baseItems : library.search(query, in: baseItems)
        guard query.isEmpty else { return base }
        switch sort {
        case .recent:
            if case .list(.recent) = source { return base }
            return base.sorted { $0.modified > $1.modified }
        case .name:
            return base.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .pages:
            return base.sorted { ($0.pageCount ?? 0) > ($1.pageCount ?? 0) }
        }
    }

    private var subfolders: [FolderItem] {
        guard let p = folderPath, !p.isEmpty, query.isEmpty else { return [] }
        return library.subfolders(of: p)
    }

    private var selectedItems: [PDFItem] {
        selected.compactMap { library.item(id: $0) }
    }

    var body: some View {
        Screen {
            SearchField(text: $query, placeholder: "Buscar em \(title)")
            if case .list(.pendingOCR) = source, !docs.isEmpty, !selecting {
                WideTile(title: "Fazer OCR de todos", systemImage: "text.viewfinder", color: Theme.orange,
                         count: "\(docs.count)", subtitle: "Um arquivo por vez; cada um gera uma cópia com “OCR” no nome") {
                    for item in docs { jobs.startOCR(item, library: library, flow: flow) }
                }
            }
            if !subfolders.isEmpty {
                TileGrid {
                    ForEach(subfolders) { folder in
                        FolderTile(folder: folder, actions: folderActions) { flow.open(.folder(folder.path)) }
                    }
                }
            }
            if docs.isEmpty && subfolders.isEmpty {
                emptyState
            } else {
                TileGrid {
                    ForEach(docs) { item in
                        DocTile(item: item,
                                showFolder: folderPath == nil,
                                selection: selecting ? selected.contains(item.id) : nil,
                                actions: actions) {
                            if selecting {
                                if let i = selected.firstIndex(of: item.id) { selected.remove(at: i) } else { selected.append(item.id) }
                            } else {
                                flow.open(.document(item.id))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if selecting { selectionBar }
        }
        .modifier(ItemActionsModifier(actions: actions, onDeleted: { selected.removeAll() }))
        .modifier(FolderActionsModifier(actions: folderActions))
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType.pdf],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let imported = library.importFiles(urls, into: folderPath ?? "")
            if !imported.isEmpty { flow.toast("\(imported.count) PDF\(imported.count == 1 ? "" : "s") importado\(imported.count == 1 ? "" : "s").") }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if selecting {
                Button("OK") {
                    selecting = false
                    selected.removeAll()
                }
                .fontWeight(.semibold)
            } else {
                Menu {
                    Button { selecting = true } label: { Label("Selecionar", systemImage: "checkmark.circle") }
                    Picker("Ordenar", selection: $sort) {
                        ForEach(DocSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if let path = folderPath {
                        Divider()
                        Button { flow.startScan(.newDocument(folder: path)) } label: {
                            Label("Escanear aqui", systemImage: "doc.viewfinder")
                        }
                        Button { showImporter = true } label: {
                            Label("Importar para esta pasta", systemImage: "square.and.arrow.down")
                        }
                        if !path.isEmpty {
                            Button { folderActions.create(in: path) } label: {
                                Label("Nova subpasta", systemImage: "folder.badge.plus")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text(selected.isEmpty ? "Toque nos PDFs" : "\(selected.count) selecionado\(selected.count == 1 ? "" : "s")")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            ShareLink(items: selectedItems.map(\.url)) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 19, weight: .semibold))
            }
            .disabled(selected.isEmpty)
            Button { actions.move(selectedItems) } label: {
                Image(systemName: "folder").font(.system(size: 19, weight: .semibold))
            }
            .disabled(selected.isEmpty)
            Button {
                flow.mergePreselection = selected
                flow.open(.merge)
            } label: {
                Image(systemName: "square.stack.3d.down.right").font(.system(size: 19, weight: .semibold))
            }
            .disabled(selected.count < 2)
            Button(role: .destructive) { actions.delete(selectedItems) } label: {
                Image(systemName: "trash").font(.system(size: 19, weight: .semibold))
            }
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).fill(Theme.tile)
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2))
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var emptyState: some View {
        switch source {
        case .list(.pendingOCR):
            EmptyStateView(systemImage: "checkmark.seal", title: "Nada aguardando OCR",
                           message: "PDFs escaneados ou em imagem aparecem aqui até você fazer o OCR.")
        case .list(.favorites):
            EmptyStateView(systemImage: "star", title: "Nenhum favorito",
                           message: "Abra um PDF e toque em “Favoritar”.")
        case .list(.ocr):
            EmptyStateView(systemImage: "text.viewfinder", title: "Nenhum PDF com OCR",
                           message: "Os arquivos criados pelo OCR aparecem aqui.")
        case .folder:
            EmptyStateView(systemImage: "folder", title: "Pasta vazia",
                           message: "Use o menu ⋯ para escanear ou importar PDFs para esta pasta.")
        default:
            EmptyStateView(systemImage: "doc", title: query.isEmpty ? "Nenhum PDF" : "Nada encontrado",
                           message: query.isEmpty ? "Escaneie ou importe um PDF pela tela inicial." : "Tente outro termo.")
        }
    }
}

struct FoldersScreen: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @StateObject private var folderActions = FolderActions()

    var body: some View {
        Screen {
            WideTile(title: "Sem pasta", systemImage: "tray.fill", color: Theme.gray,
                     count: "\(library.items(inFolder: "").count)") {
                flow.open(.folder(""))
            }
            if library.topLevelFolders.isEmpty {
                EmptyStateView(systemImage: "folder.badge.plus", title: "Nenhuma pasta",
                               message: "Crie pastas para organizar seus PDFs, por cliente ou por processo.")
            } else {
                TileGrid {
                    ForEach(library.topLevelFolders) { folder in
                        FolderTile(folder: folder, actions: folderActions) { flow.open(.folder(folder.path)) }
                    }
                }
            }
            WideTile(title: "Nova pasta", systemImage: "folder.badge.plus", color: Theme.blue) {
                folderActions.create(in: "")
            }
            Text("As pastas também aparecem no app Arquivos, em No meu iPhone › Prumo PDF.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
        .navigationTitle("Pastas")
        .modifier(FolderActionsModifier(actions: folderActions))
    }
}

/// Escolha de PDFs da biblioteca (um ou vários).
struct DocumentChooser: View {
    let title: String
    var multiple = false
    var excluding: Set<String> = []
    var initialSelection: [String] = []
    let onDone: ([PDFItem]) -> Void
    var onCancel: (() -> Void)? = nil
    @EnvironmentObject private var library: Library
    @State private var query = ""
    @State private var selected: [String] = []

    private var docs: [PDFItem] {
        let pool = library.items.filter { !excluding.contains($0.id) }
        return query.isEmpty ? pool.sorted { $0.modified > $1.modified } : library.search(query, in: pool)
    }

    var body: some View {
        Screen {
            SearchField(text: $query, placeholder: "Buscar PDF")
            if docs.isEmpty {
                EmptyStateView(systemImage: "doc", title: "Nenhum PDF", message: "Não há outros PDFs na biblioteca.")
            } else {
                TileGrid {
                    ForEach(docs) { item in
                        DocTile(item: item, showFolder: true,
                                selection: multiple ? selected.contains(item.id) : nil) {
                            if multiple {
                                if let i = selected.firstIndex(of: item.id) { selected.remove(at: i) } else { selected.append(item.id) }
                            } else {
                                onDone([item])
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onCancel {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { onCancel() } }
            }
            if multiple {
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected.isEmpty ? "Adicionar" : "Adicionar (\(selected.count))") {
                        onDone(selected.compactMap { library.item(id: $0) })
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .onAppear { if selected.isEmpty { selected = initialSelection } }
    }
}

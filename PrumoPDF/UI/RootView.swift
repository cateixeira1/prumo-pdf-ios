import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @EnvironmentObject private var jobs: JobCenter
    @State private var ready = !DemoSeeder.isActive

    var body: some View {
        ZStack {
            if ready {
                NavigationStack(path: $flow.path) {
                    HomeView()
                        .navigationDestination(for: Route.self) { route in
                            destination(for: route)
                        }
                }
            } else {
                Theme.background.ignoresSafeArea()
            }
        }
        .overlay(alignment: .bottom) { BottomOverlays() }
        .overlay {
            if let message = flow.busyMessage { BusyOverlay(message: message) }
        }
        .fullScreenCover(item: $flow.scanTarget) { target in
            DocumentScannerView(onFinish: { scan in flow.finishScan(scan, target: target, library: library) },
                                onCancel: { flow.scanTarget = nil })
                .ignoresSafeArea()
        }
        .alert("Usar OCR agora?",
               isPresented: Binding(get: { flow.askOCRItemID != nil }, set: { _ in })) {
            Button("Mais tarde") { flow.answerOCR(now: false, library: library, jobs: jobs) }
            Button("Sim") { flow.answerOCR(now: true, library: library, jobs: jobs) }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("O OCR cria um novo PDF com o texto pesquisável, com “OCR” no nome. O arquivo escaneado continua salvo.")
        }
        .sheet(item: $flow.pendingScanInsert) { pending in
            InsertPositionSheet(pending: pending,
                                targetPageCount: library.item(id: pending.itemID)?.pageCount ?? 1) { position in
                flow.insertScannedPages(pending, at: position, library: library)
            }
            .appEnvironment()
        }
        .task {
            if DemoSeeder.isActive && !ready {
                DemoSeeder.seed(library: library)
                ready = true
                DemoSeeder.applyStartScreen(library: library, flow: flow, jobs: jobs)
            }
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .list(let list):
            DocumentGridScreen(source: .list(list))
        case .folders:
            FoldersScreen()
        case .folder(let path):
            DocumentGridScreen(source: .folder(path))
        case .document(let id):
            DocumentDetailScreen(itemID: id)
        case .organize(let id):
            PageOrganizerScreen(itemID: id)
        case .reader(let id):
            PDFReaderScreen(itemID: id)
        case .settings:
            SettingsScreen()
        case .merge:
            MergeScreen()
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @State private var query = ""
    @State private var results: [PDFItem] = []
    @State private var showImporter = false

    var body: some View {
        Screen {
            SearchField(text: $query, placeholder: "Buscar nome ou texto")
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                TileGrid {
                    Tile(title: "Escanear", systemImage: "doc.viewfinder", color: Theme.yellow, shape: .rounded) {
                        flow.startScan(.newDocument(folder: ""))
                    }
                    Tile(title: "Importar", systemImage: "square.and.arrow.down", color: Theme.blue, shape: .rounded) {
                        showImporter = true
                    }
                    Tile(title: "Todos os PDFs", systemImage: "doc.on.doc.fill", color: Theme.red,
                         count: "\(library.items.count)") {
                        flow.open(.list(.all))
                    }
                    Tile(title: "Recentes", systemImage: "clock.fill", color: Theme.gray,
                         count: "\(library.count(for: .recent))") {
                        flow.open(.list(.recent))
                    }
                    Tile(title: "Aguardando OCR", systemImage: "text.viewfinder", color: Theme.orange,
                         count: "\(library.count(for: .pendingOCR))", shape: .rounded) {
                        flow.open(.list(.pendingOCR))
                    }
                    Tile(title: "Com OCR", systemImage: "checkmark.seal.fill", color: Theme.green,
                         count: "\(library.count(for: .ocr))") {
                        flow.open(.list(.ocr))
                    }
                    Tile(title: "Favoritos", systemImage: "star.fill", color: Theme.pink,
                         count: "\(library.count(for: .favorites))", shape: .rounded) {
                        flow.open(.list(.favorites))
                    }
                    Tile(title: "Combinar PDFs", systemImage: "square.stack.3d.down.right.fill", color: Theme.purple,
                         shape: .rounded) {
                        flow.open(.merge)
                    }
                }
                WideTile(title: "Pastas", systemImage: "folder.fill", color: Theme.indigo,
                         count: "\(library.folders.count)") {
                    flow.open(.folders)
                }
            } else {
                SearchResultsView(results: results, query: query)
            }
        }
        .navigationTitle("Prumo PDF")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { flow.open(.settings) } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Ajustes")
            }
        }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            results = library.search(query)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType.pdf],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let imported = library.importFiles(urls)
            if imported.count == 1 {
                flow.toast("PDF importado: \(imported[0].name)", actionTitle: "Abrir") {
                    flow.open(.document(imported[0].id))
                }
            } else if !imported.isEmpty {
                flow.toast("\(imported.count) PDFs importados.")
            }
        }
    }
}

struct SearchResultsView: View {
    let results: [PDFItem]
    let query: String
    @EnvironmentObject private var flow: AppFlow

    var body: some View {
        if results.isEmpty {
            EmptyStateView(systemImage: "magnifyingglass", title: "Nada encontrado",
                           message: "A busca procura no nome dos arquivos e no texto dos PDFs. PDFs escaneados só aparecem pelo texto depois do OCR.")
        } else {
            SectionTitle(text: "\(results.count) resultado\(results.count == 1 ? "" : "s")")
            TileGrid {
                ForEach(results) { item in
                    DocTile(item: item, showFolder: true) { flow.open(.document(item.id)) }
                }
            }
        }
    }
}

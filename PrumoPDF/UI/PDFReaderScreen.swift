import PDFKit
import SwiftUI

@MainActor
final class ReaderModel: ObservableObject {
    weak var pdfView: PDFView?
    @Published var currentPage = 1
    @Published var pageCount = 0
    @Published var results: [PDFSelection] = []
    @Published var resultIndex = 0
    @Published var searched = false

    func pageChanged() {
        guard let view = pdfView, let doc = view.document, let page = view.currentPage else { return }
        currentPage = doc.index(for: page) + 1
        pageCount = doc.pageCount
    }

    func search(_ text: String) {
        guard let doc = pdfView?.document else { return }
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { clearSearch(); return }
        results = doc.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
        searched = true
        resultIndex = 0
        pdfView?.highlightedSelections = results
        show()
    }

    func next() {
        guard !results.isEmpty else { return }
        resultIndex = (resultIndex + 1) % results.count
        show()
    }

    func previous() {
        guard !results.isEmpty else { return }
        resultIndex = (resultIndex - 1 + results.count) % results.count
        show()
    }

    func clearSearch() {
        results = []
        searched = false
        pdfView?.highlightedSelections = nil
        pdfView?.clearSelection()
    }

    func go(toPage n: Int) {
        guard let doc = pdfView?.document, n >= 1, n <= doc.pageCount, let page = doc.page(at: n - 1) else { return }
        pdfView?.go(to: page)
    }

    private func show() {
        guard results.indices.contains(resultIndex) else { return }
        let sel = results[resultIndex]
        pdfView?.setCurrentSelection(sel, animate: true)
        pdfView?.go(to: sel)
    }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL
    let model: ReaderModel
    var password: String? = nil

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.pageShadowsEnabled = true
        view.backgroundColor = Theme.backgroundUI
        let doc = PDFDocument(url: url)
        if let password, doc?.isLocked == true { _ = doc?.unlock(withPassword: password) }
        view.document = doc
        model.pdfView = view
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged),
                                               name: .PDFViewPageChanged, object: view)
        Task { @MainActor in model.pageChanged() }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject {
        let model: ReaderModel
        init(model: ReaderModel) { self.model = model }
        @objc func pageChanged() {
            Task { @MainActor in self.model.pageChanged() }
        }
    }
}

struct PDFReaderScreen: View {
    let itemID: String
    var initialMode: ReaderMode = .original
    @EnvironmentObject private var library: Library
    @StateObject private var model = ReaderModel()
    @StateObject private var textModel = TextReaderModel()
    @State private var mode: ReaderMode = .original
    @State private var didSetMode = false
    @State private var query = ""
    @State private var askPage = false
    @State private var pageText = ""
    @State private var password: String?
    @State private var askPassword = false
    @State private var passwordText = ""
    @State private var wrongPassword = false

    private var item: PDFItem? { library.item(id: itemID) }

    /// De onde vem o texto do modo leitor: o próprio PDF, ou a cópia com OCR de um PDF escaneado.
    private var textSource: PDFItem? {
        guard let item else { return nil }
        if item.meta.isOCRResult || item.meta.textStatus == .digital || item.meta.textStatus == .mixed {
            return item
        }
        if let copyID = item.meta.ocrCopyID, let copy = library.item(id: copyID) { return copy }
        return nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if mode == .original {
                originalPane
            } else {
                TextReaderPane(model: textModel)
            }
            pageBar
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(item?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .alert("Ir para a página", isPresented: $askPage) {
            TextField("Número da página", text: $pageText)
                .keyboardType(.numberPad)
            Button("Cancelar", role: .cancel) {}
            Button("Ir") {
                guard let n = Int(pageText) else { return }
                if mode == .original { model.go(toPage: n) } else { textModel.scrollTo(page: n, animated: true) }
            }
        } message: {
            Text("O documento tem \(totalPages.pagesText).")
        }
        .onAppear {
            if let item { library.markOpened(item) }
            if !didSetMode {
                didSetMode = true
                mode = (initialMode == .text && textSource != nil) ? .text : .original
            }
        }
        .task(id: mode) {
            if mode == .text, let source = textSource {
                await textModel.load(url: source.url, reviewPages: source.meta.reviewPages ?? [])
            }
        }
        .onChange(of: mode) { old, new in
            // Mantém a mesma página ao trocar de modo.
            if new == .text {
                let page = model.currentPage
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    textModel.scrollTo(page: page)
                }
            } else if old == .text {
                let page = textModel.currentPage
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    model.go(toPage: page)
                }
            }
        }
    }

    private var totalPages: Int { mode == .original ? model.pageCount : textModel.pageCount }
    private var shownPage: Int { mode == .original ? model.currentPage : textModel.currentPage }

    @ViewBuilder private var originalPane: some View {
        if let item, item.meta.locked == true, password == nil {
            VStack(spacing: 14) {
                Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(Theme.purple)
                Text("Este PDF tem senha").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
                PrimaryButton(title: "Digitar a senha", color: Theme.blue) { askPassword = true }
                    .padding(.horizontal, 60)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { askPassword = true }
            .alert(wrongPassword ? "Senha incorreta" : "Senha do PDF", isPresented: $askPassword) {
                SecureField("Senha", text: $passwordText)
                Button("Cancelar", role: .cancel) {}
                Button("Abrir") {
                    if Library.checkPassword(item.url, passwordText) {
                        password = passwordText
                        wrongPassword = false
                    } else {
                        wrongPassword = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { askPassword = true }
                    }
                    passwordText = ""
                }
            } message: {
                Text(wrongPassword ? "Tente de novo (maiúsculas e minúsculas fazem diferença)." : "Digite a senha para abrir.")
            }
        } else if let item {
            PDFKitView(url: item.url, model: model, password: password)
                .ignoresSafeArea(edges: .bottom)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                            prompt: "Buscar no documento")
                .onSubmit(of: .search) { model.search(query) }
                .onChange(of: query) { _, newValue in
                    if newValue.isEmpty { model.clearSearch() }
                }
        }
    }

    private var pageBar: some View {
        HStack(spacing: 10) {
            Button {
                pageText = ""
                askPage = true
            } label: {
                Text("\(shownPage) / \(totalPages)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Capsule().fill(.regularMaterial))
            }
            .accessibilityLabel("Página \(shownPage) de \(totalPages). Toque para ir para outra página.")
            Spacer()
            if mode == .original && model.searched {
                HStack(spacing: 14) {
                    Text(model.results.isEmpty ? "Nada encontrado" : "\(model.resultIndex + 1) de \(model.results.count)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if !model.results.isEmpty {
                        Button { model.previous() } label: { Image(systemName: "chevron.up") }
                        Button { model.next() } label: { Image(systemName: "chevron.down") }
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(.regularMaterial))
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, 10)
        .opacity(totalPages > 0 ? 1 : 0)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if textSource != nil {
            ToolbarItem(placement: .principal) {
                Picker("Modo de leitura", selection: $mode) {
                    Text("Original").tag(ReaderMode.original)
                    Text("Texto").tag(ReaderMode.text)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if mode == .text {
                Button { textModel.presentFind() } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Buscar no texto")
                Menu {
                    Section("Tamanho da letra") {
                        Button { textModel.biggerFont() } label: { Label("Aumentar", systemImage: "textformat.size.larger") }
                        Button { textModel.smallerFont() } label: { Label("Diminuir", systemImage: "textformat.size.smaller") }
                    }
                    Section("Letra") {
                        Picker("Letra", selection: $textModel.serif) {
                            Text("Com serifa").tag(true)
                            Text("Sem serifa").tag(false)
                        }
                    }
                    Section("Fundo") {
                        Picker("Fundo", selection: $textModel.theme) {
                            ForEach(ReaderTheme.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    Section {
                        Button {
                            UIPasteboard.general.string = textModel.document?.plainText ?? ""
                            AppFlow.shared.toast("Texto copiado.")
                        } label: { Label("Copiar todo o texto", systemImage: "doc.on.doc") }
                        if let text = textModel.document?.plainText {
                            ShareLink(item: text, preview: SharePreview(item?.name ?? "Texto")) {
                                Label("Compartilhar o texto", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "textformat.size")
                }
                .accessibilityLabel("Opções de leitura")
            } else if let item {
                ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") }
            }
        }
    }
}

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

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.pageShadowsEnabled = true
        view.backgroundColor = Theme.backgroundUI
        view.document = PDFDocument(url: url)
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
    @EnvironmentObject private var library: Library
    @StateObject private var model = ReaderModel()
    @State private var query = ""
    @State private var askPage = false
    @State private var pageText = ""

    private var item: PDFItem? { library.item(id: itemID) }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let item {
                PDFKitView(url: item.url, model: model)
                    .ignoresSafeArea(edges: .bottom)
            }
            HStack(spacing: 10) {
                Button {
                    pageText = ""
                    askPage = true
                } label: {
                    Text("\(model.currentPage) / \(model.pageCount)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(Capsule().fill(.regularMaterial))
                }
                .accessibilityLabel("Página \(model.currentPage) de \(model.pageCount). Toque para ir para outra página.")
                Spacer()
                if model.searched {
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
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(item?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Buscar no documento")
        .onSubmit(of: .search) { model.search(query) }
        .onChange(of: query) { _, newValue in
            if newValue.isEmpty { model.clearSearch() }
        }
        .toolbar {
            if let item {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .alert("Ir para a página", isPresented: $askPage) {
            TextField("Número da página", text: $pageText)
                .keyboardType(.numberPad)
            Button("Cancelar", role: .cancel) {}
            Button("Ir") { if let n = Int(pageText) { model.go(toPage: n) } }
        } message: {
            Text("O documento tem \(model.pageCount.pagesText).")
        }
        .onAppear { if let item { library.markOpened(item) } }
    }
}

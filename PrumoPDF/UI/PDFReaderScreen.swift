import PDFKit
import SwiftUI
import UIKit

/// Estado do leitor (modo Original): página, busca, seleção de texto, marca-texto e destaques.
@MainActor
final class ReaderModel: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    weak var pdfView: PDFView?
    @Published var currentPage = 1
    @Published var pageCount = 0
    @Published var results: [PDFSelection] = []
    @Published var resultIndex = 0
    @Published var searched = false
    @Published var hasSelection = false
    @Published var hasMarksInSelection = false
    /// Marca-texto ligado: um dedo destaca, dois dedos rolam (como a Marcação da Apple).
    @Published private(set) var marking = false
    @Published var color: HighlightColor = HighlightColor(rawValue: UserDefaults.standard.string(forKey: "readerColor") ?? "") ?? .yellow {
        didSet { UserDefaults.standard.set(color.rawValue, forKey: "readerColor") }
    }
    /// Destaque tocado (para apagar ou mudar a cor).
    @Published var tappedMark: PDFAnnotation?
    /// Qual PDF está aberto (para o desfazer saber onde aplicar).
    var docID = ""
    /// Destaque feito, apagado ou recolorido (para o desfazer e para gravar).
    var onEdit: ((String, ReaderHistory.Change) -> Void)?
    private var markPan: UIPanGestureRecognizer?
    private var markStart: (PDFPage, CGPoint)?
    private var markSelection: PDFSelection?

    func attach(_ view: PDFView) {
        pdfView = view
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleMark(_:)))
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = false
        pan.delegate = self
        view.addGestureRecognizer(pan)
        markPan = pan
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g is UITapGestureRecognizer
    }

    func pageChanged() {
        guard let view = pdfView, let doc = view.document, let page = view.currentPage else { return }
        let n = doc.index(for: page) + 1
        if n != currentPage { currentPage = n }
        if doc.pageCount != pageCount { pageCount = doc.pageCount }
    }

    func selectionRanges() -> [(page: Int, range: NSRange)] {
        guard let view = pdfView, let doc = view.document, let sel = view.currentSelection else { return [] }
        return Highlights.ranges(of: sel, in: doc)
    }

    func selectionChanged() {
        let text = pdfView?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        hasSelection = !text.isEmpty && !marking
        if hasSelection, let doc = pdfView?.document {
            hasMarksInSelection = Highlights.hasMarks(selectionRanges(), in: doc)
        } else {
            hasMarksInSelection = false
        }
    }

    // MARK: Busca

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

    // MARK: Marca-texto

    private var scrollView: UIScrollView? {
        guard let view = pdfView else { return nil }
        if let s = view.subviews.compactMap({ $0 as? UIScrollView }).first { return s }
        for sub in view.subviews {
            if let s = sub.subviews.compactMap({ $0 as? UIScrollView }).first { return s }
        }
        return nil
    }

    func setMarking(_ on: Bool) {
        marking = on
        markPan?.isEnabled = on
        // Com o marca-texto ligado, a página rola com dois dedos.
        scrollView?.panGestureRecognizer.minimumNumberOfTouches = on ? 2 : 1
        if on { pdfView?.clearSelection() }
        selectionChanged()
    }

    @objc private func handleMark(_ g: UIPanGestureRecognizer) {
        guard let view = pdfView, let doc = view.document else { return }
        let p = g.location(in: view)
        guard let page = view.page(for: p, nearest: true) else { return }
        let pp = view.convert(p, to: page)
        switch g.state {
        case .began:
            markStart = (page, pp)
        case .changed:
            guard let start = markStart else { return }
            let sel = doc.selection(from: start.0, at: start.1, to: page, at: pp)
            sel?.color = color.uiColor.withAlphaComponent(0.55)
            markSelection = sel
            view.highlightedSelections = sel.map { [$0] }
        case .ended:
            if let sel = markSelection,
               !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                apply(sel, color: color)
            }
            fallthrough
        default:
            markStart = nil
            markSelection = nil
            view.highlightedSelections = results.isEmpty ? nil : results
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, let view = pdfView else { return }
        let p = g.location(in: view)
        guard let page = view.page(for: p, nearest: false) else { return }
        if let mark = Highlights.highlight(at: view.convert(p, to: page), on: page) {
            tappedMark = mark
        }
    }

    private func apply(_ selection: PDFSelection, color c: HighlightColor) {
        guard let doc = pdfView?.document else { return }
        let added = Highlights.add(selection, color: c, in: doc)
        guard !added.isEmpty else { return }
        let pairs = added.compactMap { a in a.page.map { (doc.index(for: $0), a) } }
        onEdit?("Destaque", .marks(docID: docID, removed: [], added: pairs))
    }

    /// Destaca o texto selecionado (sem o marca-texto).
    func highlightSelection(_ c: HighlightColor) {
        guard let sel = pdfView?.currentSelection else { return }
        color = c
        apply(sel, color: c)
        pdfView?.clearSelection()
        selectionChanged()
    }

    /// Tira o destaque só do texto selecionado (o resto de cada destaque continua).
    func unmarkSelection() {
        guard let doc = pdfView?.document else { return }
        let change = Highlights.unmark(selectionRanges(), in: doc)
        guard !change.removed.isEmpty else { return }
        onEdit?("Desfazer destaque", .marks(docID: docID, removed: change.removed, added: change.added))
        pdfView?.clearSelection()
        selectionChanged()
    }

    func removeMark(_ a: PDFAnnotation) {
        guard let doc = pdfView?.document, let page = a.page else { return }
        let p = doc.index(for: page)
        Highlights.remove(a)
        onEdit?("Apagar destaque", .marks(docID: docID, removed: [(p, a)], added: []))
    }

    func recolorMark(_ a: PDFAnnotation, _ c: HighlightColor) {
        guard let doc = pdfView?.document, let page = a.page else { return }
        let from = a.color
        Highlights.recolor(a, c)
        onEdit?("Cor do destaque", .recolor(docID: docID, page: doc.index(for: page), mark: a, from: from, to: c.uiColor))
    }

    func copySelection() -> Bool {
        guard let t = pdfView?.currentSelection?.string, !t.isEmpty else { return false }
        UIPasteboard.general.string = t
        return true
    }

    /// A seleção como trecho para o resumo: páginas e texto corrido.
    func excerpt() -> (pages: [Int], text: String)? {
        guard let view = pdfView, let doc = view.document, let sel = view.currentSelection else { return nil }
        let text = Summary.clean(sel.string ?? "")
        guard !text.isEmpty else { return nil }
        let pages = sel.pages.map { doc.index(for: $0) + 1 }.sorted()
        return (pages, text)
    }

    func clearSelection() {
        pdfView?.clearSelection()
        selectionChanged()
    }

    /// Só para a captura de tela: um trecho selecionado, com parte dele já destacada.
    func demoSelection() {
        guard let view = pdfView, let doc = view.document,
              let phrase = doc.findString("febre persistente, dor abdominal intensa", withOptions: [.caseInsensitive]).first,
              let word = doc.findString("febre persistente", withOptions: [.caseInsensitive]).first else { return }
        Highlights.add(word, color: .yellow, in: doc)
        view.setCurrentSelection(phrase, animate: false)
        selectionChanged()
    }
}

/// O PDFView e, à esquerda, a coluna de miniaturas (que aparece e some pela barra de baixo).
final class ReaderContainerView: UIView {
    let pdfView = PDFView()
    let thumbs = PDFThumbnailView()
    private var leading: NSLayoutConstraint!
    private var widthConstraint: NSLayoutConstraint!
    static let thumbsWidth: CGFloat = 92
    /// Depois da primeira medida, a primeira página começa no alto (sem cortar o cabeçalho).
    var needsInitialPosition = true
    private var lastWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.backgroundUI
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        thumbs.translatesAutoresizingMaskIntoConstraints = false
        thumbs.layoutMode = .vertical
        thumbs.thumbnailSize = CGSize(width: 64, height: 86)
        thumbs.backgroundColor = Theme.tileUI
        thumbs.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 60, right: 0)
        addSubview(pdfView)
        addSubview(thumbs)
        widthConstraint = thumbs.widthAnchor.constraint(equalToConstant: Self.thumbsWidth)
        leading = pdfView.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            thumbs.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbs.topAnchor.constraint(equalTo: topAnchor),
            thumbs.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
            leading,
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        thumbs.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = pdfView.bounds.width
        guard w > 0, pdfView.document != nil else { return }
        if abs(w - lastWidth) > 0.5 {
            lastWidth = w
            // zoom: de "página inteira na largura" até 5x; sem encolher além da largura
            let fit = pdfView.scaleFactorForSizeToFit
            if fit > 0 {
                pdfView.minScaleFactor = fit
                pdfView.maxScaleFactor = max(fit * 5, 4)
                if pdfView.scaleFactor < fit { pdfView.scaleFactor = fit }
            }
        }
        if needsInitialPosition {
            needsInitialPosition = false
            DispatchQueue.main.async { [weak self] in
                guard let view = self?.pdfView, let page = view.document?.page(at: 0) else { return }
                let b = page.bounds(for: view.displayBox)
                view.go(to: CGRect(x: b.minX, y: b.maxY - 1, width: 1, height: 1), on: page)
            }
        }
    }

    func showThumbnails(_ on: Bool) {
        guard thumbs.isHidden == on else { return }
        thumbs.isHidden = !on
        leading.constant = on ? Self.thumbsWidth : 0
        UIView.animate(withDuration: 0.2) { self.layoutIfNeeded() }
    }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL
    let model: ReaderModel
    var password: String? = nil
    var showThumbnails = false
    /// Muda quando o arquivo foi alterado por outra ferramenta: o documento é lido de novo.
    var reloadToken = 0

    func makeUIView(context: Context) -> ReaderContainerView {
        let container = ReaderContainerView()
        let view = container.pdfView
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.pageShadowsEnabled = true
        view.backgroundColor = Theme.backgroundUI
        view.document = Self.load(url, password: password)
        container.thumbs.pdfView = view
        model.attach(view)
        context.coordinator.token = reloadToken
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged),
                                               name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.selectionChanged),
                                               name: .PDFViewSelectionChanged, object: view)
        Task { @MainActor in model.pageChanged() }
        return container
    }

    /// Lê o PDF para a memória: o arquivo pode ser regravado (destaques) sem afetar o que está na tela.
    static func load(_ url: URL, password: String?) -> PDFDocument? {
        let doc = (try? Data(contentsOf: url)).flatMap { PDFDocument(data: $0) } ?? PDFDocument(url: url)
        if let password, doc?.isLocked == true { _ = doc?.unlock(withPassword: password) }
        return doc
    }

    func updateUIView(_ container: ReaderContainerView, context: Context) {
        container.showThumbnails(showThumbnails)
        if context.coordinator.token != reloadToken {
            context.coordinator.token = reloadToken
            let page = container.pdfView.currentPage.flatMap { container.pdfView.document?.index(for: $0) } ?? 0
            container.pdfView.document = Self.load(url, password: password)
            if let doc = container.pdfView.document, let p = doc.page(at: min(page, max(0, doc.pageCount - 1))) {
                container.pdfView.go(to: p)
            }
            container.setNeedsLayout()
            Task { @MainActor in model.pageChanged() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject {
        let model: ReaderModel
        var token = 0
        init(model: ReaderModel) { self.model = model }
        @objc func pageChanged() {
            Task { @MainActor in self.model.pageChanged() }
        }
        @objc func selectionChanged() {
            Task { @MainActor in self.model.selectionChanged() }
        }
    }
}

/// Ações do botão "Ferramentas" do leitor (todas as funções do app).
enum ReaderAction: Identifiable {
    case textMode, pageMode, goToPage, crop, number, sign, ocr, organize, insert, remove, extract, split, merge, dewarp,
         protect, unprotect, duplicate, favorite, rename, move, details, undo, delete, openSummary
    var id: String { "\(self)" }
}

struct PDFReaderScreen: View {
    let itemID: String
    var initialMode: ReaderMode = .original
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @EnvironmentObject private var jobs: JobCenter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var model = ReaderModel()
    @StateObject private var textModel = TextReaderModel()
    @StateObject private var actions = ItemActions()
    @StateObject private var history = ReaderHistory()
    @State private var mode: ReaderMode = .original
    @State private var didSetMode = false
    @State private var query = ""
    @State private var searchShown = false
    @FocusState private var searchFocused: Bool
    @State private var askPage = false
    @State private var pageText = ""
    @State private var password: String?
    @State private var askPassword = false
    @State private var passwordText = ""
    @State private var wrongPassword = false
    @State private var showThumbs = false
    @State private var showTools = false
    @State private var pendingAction: ReaderAction?
    @State private var sheetAction: ReaderAction?
    @State private var reloadToken = 0
    @State private var expectedVersion: String?
    @State private var saveTasks: [String: Task<Void, Never>] = [:]
    @State private var saving = false
    @State private var confirmUndo = false
    @State private var askUnprotect = false
    @State private var unprotectText = ""
    @State private var showInsertMenu = false
    @State private var addingSummary = false
    @State private var fileBefore: Data?

    private var item: PDFItem? { library.item(id: itemID) }
    private var locked: Bool { item?.meta.locked == true }

    /// De onde vem o texto do modo leitor: o próprio PDF, ou a cópia com OCR de um PDF escaneado.
    private var textSource: PDFItem? {
        guard let item else { return nil }
        if item.meta.isOCRResult || item.meta.textStatus == .digital || item.meta.textStatus == .mixed {
            return item
        }
        if let copyID = item.meta.ocrCopyID, let copy = library.item(id: copyID) { return copy }
        return nil
    }

    /// O PDF que está sendo lido agora (no modo leitor, pode ser a cópia com OCR).
    private var activeItem: PDFItem? { mode == .text ? textSource : item }
    private var summaryItem: PDFItem? { activeItem.flatMap { Summary.find(in: library, for: $0) } }

    // O corpo fica dividido em partes: numa expressão só, o compilador não dá conta de conferir os tipos.
    var body: some View {
        lifecycle(dialogs(sheets(chrome)))
    }

    /// O leitor, a barra flutuante e as barras de cima e de baixo.
    private var chrome: some View {
        ZStack(alignment: .bottom) {
            content
            VStack(spacing: 8) {
                floatingBar
                bottomRow
            }
        }
        .overlay(alignment: .top) { searchBar }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(item?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .toolbar { ToolbarItemGroup(placement: .bottomBar) { bottomBar } }
        .toolbarBackground(.visible, for: .bottomBar)
        .modifier(ItemActionsModifier(actions: actions, onDeleted: { dismiss() }))
    }

    /// Páginas (sempre carregadas, para manter a posição e os destaques) e, por cima, o texto.
    private var content: some View {
        HStack(spacing: 0) {
            if mode == .text && showThumbs, let source = textSource {
                TextThumbnails(url: source.url, version: source.version, count: textModel.pageCount,
                               current: textModel.currentPage) { textModel.scrollTo(page: $0, animated: true) }
            }
            ZStack(alignment: .topTrailing) {
                originalPane
                    .opacity(mode == .original ? 1 : 0)
                    .allowsHitTesting(mode == .original)
                if mode == .text {
                    TextReaderPane(model: textModel)
                }
                pageBadge
            }
        }
    }

    private var markDialogShown: Binding<Bool> {
        Binding(get: { model.tappedMark != nil || textModel.tappedMark != nil },
                set: { if !$0 { model.tappedMark = nil; textModel.tappedMark = nil } })
    }

    private var tappedMark: PDFAnnotation? { model.tappedMark ?? textModel.tappedMark }

    /// "Ir para a página", o toque num destaque, Ferramentas e as folhas das ferramentas.
    private func sheets<V: View>(_ content: V) -> some View {
        content
            .alert("Ir para a página", isPresented: $askPage) {
                TextField("Número da página", text: $pageText)
                    .keyboardType(.numberPad)
                Button("Cancelar", role: .cancel) {}
                Button("Ir") { goToTypedPage() }
            } message: {
                Text("O documento tem \(totalPages.pagesText).")
            }
            .confirmationDialog("Destaque", isPresented: markDialogShown, titleVisibility: .visible,
                                presenting: tappedMark) { mark in
                markActions(mark)
            } message: { mark in
                Text(markMessage(mark))
            }
            .sheet(isPresented: $showTools, onDismiss: runPendingAction) { toolsSheet }
            .sheet(item: $sheetAction, onDismiss: sheetClosed) { action in
                actionSheetIfPossible(action)
            }
    }

    @ViewBuilder private func actionSheetIfPossible(_ action: ReaderAction) -> some View {
        if let target = activeItem { actionSheet(action, item: target) }
    }

    @ViewBuilder private func markActions(_ mark: PDFAnnotation) -> some View {
        Button("Apagar o destaque", role: .destructive) { guardEditable { removeMark(mark) } }
        ForEach(HighlightColor.allCases) { c in
            Button("Mudar para \(c.label.lowercased())") { guardEditable { recolorMark(mark, c) } }
        }
        Button("Cancelar", role: .cancel) {}
    }

    private func markMessage(_ mark: PDFAnnotation) -> String {
        let text = mark.contents ?? ""
        return text.isEmpty ? "Trecho destacado." : "“\(text.prefix(120))”"
    }

    private var toolsSheet: some View {
        ReaderToolsSheet(item: activeItem, mode: mode, locked: locked, hasTextMode: textSource != nil,
                         hasSummary: summaryItem != nil, canUndo: activeItem.map { library.canUndo($0) } ?? false,
                         onPick: { action in
                             pendingAction = action
                             showTools = false
                         })
            .appEnvironment()
    }

    private func goToTypedPage() {
        guard let n = Int(pageText) else { return }
        if mode == .original {
            model.go(toPage: n)
        } else {
            textModel.scrollTo(page: n, animated: true)
        }
    }

    /// Desfazer a última alteração do arquivo, remover a senha e incluir páginas.
    private func dialogs<V: View>(_ content: V) -> some View {
        content
            .confirmationDialog("Desfazer a última alteração?", isPresented: $confirmUndo, titleVisibility: .visible) {
                Button("Desfazer") { undoLastChange() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("O PDF volta a ficar como estava antes da última mudança (páginas, destaques, corte ou numeração).")
            }
            .alert("Remover a senha", isPresented: $askUnprotect) {
                SecureField("Senha atual", text: $unprotectText)
                Button("Cancelar", role: .cancel) { unprotectText = "" }
                Button("Remover") { removePassword() }
            } message: {
                Text("Cria uma cópia sem senha, para destacar, fazer OCR, organizar ou dividir. O PDF com senha continua guardado.")
            }
            .confirmationDialog("Incluir páginas", isPresented: $showInsertMenu, titleVisibility: .visible) {
                Button("Escanear páginas") { insertPages("scan") }
                Button("De outro PDF da biblioteca") { insertPages("insertLibrary") }
                Button("Do app Arquivos") { insertPages("insertFile") }
                Button("Cancelar", role: .cancel) {}
            }
    }

    private func insertPages(_ source: String) {
        guard let item else { return }
        if source == "scan" {
            flow.startScan(.insert(itemID: item.id))
        } else {
            flow.openTool(source, on: item)
        }
    }

    private func undoLastChange() {
        guard let target = activeItem else { return }
        do {
            cancelSaves()
            try library.undo(target)
            history.clear()
            reloadDocument()
            flow.toast("Alteração desfeita.")
        } catch {
            flow.show(error: error)
        }
    }

    private func removePassword() {
        guard let item else { return }
        do {
            let new = try library.unprotect(item, password: unprotectText)
            flow.toast("Cópia sem senha: \(new.name)", actionTitle: "Abrir") { flow.open(.reader(new.id)) }
        } catch {
            flow.show(error: error)
        }
        unprotectText = ""
    }

    /// Ao abrir, ao sair, quando o arquivo muda e ao trocar entre original e texto.
    private func lifecycle<V: View>(_ content: V) -> some View {
        content
            .onAppear { appeared() }
            .onDisappear { saveAllNow() }
            .onChange(of: item?.version) { _, new in versionChanged(new) }
            .task(id: mode) { await loadTextIfNeeded() }
            .onChange(of: mode) { old, new in modeChanged(from: old, to: new) }
    }

    private func appeared() {
        if let item {
            library.markOpened(item)
            if expectedVersion == nil { expectedVersion = item.version }
            model.docID = item.id
        }
        if !didSetMode {
            didSetMode = true
            if initialMode == .text && textSource != nil {
                mode = .text
            } else {
                mode = .original
            }
            if let saved = UserDefaults.standard.object(forKey: "readerThumbs") as? Bool {
                showThumbs = saved
            } else {
                showThumbs = sizeClass == .regular   // iPad: miniaturas à mostra; iPhone: escondidas
            }
        }
        if DemoSeeder.isActive && DemoSeeder.consumeReaderSelection() {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                model.demoSelection()
            }
        }
        model.onEdit = { label, change in recordEdit(label, change) }
        textModel.onEdit = { label, change in recordEdit(label, change) }
        textModel.onSummary = { addToSummary() }
        let m = model
        textModel.color = { [weak m] in m?.color ?? .yellow }
    }

    private func recordEdit(_ label: String, _ change: ReaderHistory.Change) {
        history.record(label, change)
        switch change {
        case .marks(let docID, _, _), .recolor(let docID, _, _, _, _): scheduleSave(docID)
        default: break
        }
    }

    /// O arquivo mudou por outra ferramenta (organizar, remover, desfazer): lê de novo.
    private func versionChanged(_ new: String?) {
        guard let new, !saving, saveTasks.isEmpty, new != expectedVersion else { return }
        expectedVersion = new
        reloadDocument()
    }

    private func loadTextIfNeeded() async {
        guard mode == .text, let source = textSource else { return }
        let shared = source.id == item?.id ? model.pdfView?.document : nil
        await textModel.load(url: source.url, version: source.version, pdf: shared, id: source.id,
                             reviewPages: source.meta.reviewPages ?? [])
    }

    /// Mantém a mesma página ao trocar de modo.
    private func modeChanged(from old: ReaderMode, to new: ReaderMode) {
        if new == .text {
            model.setMarking(false)
            if searchShown { closeSearch() }
            let page = model.currentPage
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                textModel.scrollTo(page: page)
            }
        } else if old == .text {
            textModel.setMarking(false)
            let page = textModel.currentPage
            Task { @MainActor in
                // o PDF estava escondido e acabou de voltar: a primeira tentativa pode cair antes de a
                // vista ter o tamanho final (e ficar na primeira página), então confere e tenta de novo
                for attempt in 0..<5 {
                    try? await Task.sleep(nanoseconds: attempt == 0 ? 150_000_000 : 120_000_000)
                    guard mode == .original else { return }
                    model.go(toPage: page)
                    model.pageChanged()
                    if model.currentPage == page { return }
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
                Button("Abrir") { tryPassword(item) }
            } message: {
                Text(wrongPassword ? "Tente de novo (maiúsculas e minúsculas fazem diferença)." : "Digite a senha para abrir.")
            }
        } else if let item {
            PDFKitView(url: item.url, model: model, password: password, showThumbnails: showThumbs,
                       reloadToken: reloadToken)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func tryPassword(_ item: PDFItem) {
        if Library.checkPassword(item.url, passwordText) {
            password = passwordText
            wrongPassword = false
        } else {
            wrongPassword = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { askPassword = true }
        }
        passwordText = ""
    }

    // MARK: - Barras

    /// Número da página, no canto de cima à direita das páginas (toque para ir a outra).
    private var pageBadge: some View {
        Button {
            pageText = ""
            askPage = true
        } label: {
            Text("\(shownPage) / \(totalPages)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(.regularMaterial))
        }
        .padding(.top, searchShown ? 64 : 8)
        .padding(.trailing, 10)
        .opacity(totalPages > 0 ? 1 : 0)
        .accessibilityLabel("Página \(shownPage) de \(totalPages). Toque para ir para outra página.")
    }

    /// Desfazer (sempre à mão, no lugar onde ficava o número da página) e refazer (logo acima, quando houver).
    private var bottomRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(spacing: 10) {
                if history.canRedo {
                    circleButton("arrow.uturn.forward", label: "Refazer") { redo() }
                        .transition(.scale.combined(with: .opacity))
                }
                circleButton("arrow.uturn.backward", label: "Desfazer") { undo() }
                    .opacity(history.canUndo ? 1 : 0.4)
                    .disabled(!history.canUndo)
            }
            .animation(.easeOut(duration: 0.2), value: history.canRedo)
            Spacer()
            if mode == .original && model.searched && !searchShown { resultsPill }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, 10)
    }

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 46, height: 46)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
        .accessibilityLabel(label)
    }

    private var resultsPill: some View {
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

    /// Busca do modo Original: um campo próprio, que só aparece pela lupa (a busca presa à barra do
    /// alto mudava o tamanho da área do PDF ao rolar e fazia o leitor pular de página).
    @ViewBuilder private var searchBar: some View {
        if searchShown && mode == .original {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
                TextField("Buscar no documento", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit { model.search(query) }
                if model.searched {
                    Text(model.results.isEmpty ? "0" : "\(model.resultIndex + 1)/\(model.results.count)")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    Button { model.previous() } label: { Image(systemName: "chevron.up") }
                        .disabled(model.results.isEmpty)
                    Button { model.next() } label: { Image(systemName: "chevron.down") }
                        .disabled(model.results.isEmpty)
                }
                Button("OK") { closeSearch() }.fontWeight(.semibold)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
            .padding(.horizontal, Theme.margin)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func openSearch() {
        if mode == .text {
            textModel.presentFind()
            return
        }
        withAnimation { searchShown = true }
        searchFocused = true
    }

    private func closeSearch() {
        searchFocused = false
        withAnimation { searchShown = false }
        query = ""
        model.clearSearch()
    }

    // seleção e marca-texto do modo ativo
    private var marking: Bool { mode == .original ? model.marking : textModel.marking }
    private var hasSelection: Bool { mode == .original ? model.hasSelection : textModel.hasSelection }
    private var marksInSelection: Bool { mode == .original ? model.hasMarksInSelection : textModel.hasMarksInSelection }

    private func setMarking(_ on: Bool) {
        if mode == .original { model.setMarking(on) } else { textModel.setMarking(on) }
    }

    private func highlightSelection(_ c: HighlightColor) {
        model.color = c
        if mode == .original { model.highlightSelection(c) } else { textModel.highlightSelection(c) }
    }

    private func unmarkSelection() {
        if mode == .original { model.unmarkSelection() } else { textModel.unmarkSelection() }
    }

    private func copySelection() -> Bool {
        mode == .original ? model.copySelection() : textModel.copySelection()
    }

    private func removeMark(_ a: PDFAnnotation) {
        if mode == .original { model.removeMark(a) } else { textModel.removeMark(a) }
    }

    private func recolorMark(_ a: PDFAnnotation, _ c: HighlightColor) {
        if mode == .original { model.recolorMark(a, c) } else { textModel.recolorMark(a, c) }
    }

    /// Barra flutuante: ações do texto selecionado, ou o aviso do marca-texto ligado.
    @ViewBuilder private var floatingBar: some View {
        if marking {
            HStack(spacing: 12) {
                Circle().fill(Color(model.color.uiColor)).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 1))
                Text("Passe o dedo sobre o texto. Dois dedos rolam.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button("OK") { setMarking(false) }.fontWeight(.semibold)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Capsule().fill(.regularMaterial))
            .padding(.horizontal, Theme.margin)
        } else if hasSelection {
            selectionBar
        }
    }

    private static func dot(_ c: HighlightColor) -> UIImage {
        UIImage(systemName: "circle.fill")?.withTintColor(c.uiColor, renderingMode: .alwaysOriginal) ?? UIImage()
    }

    private var selectionBar: some View {
        HStack(spacing: 4) {
            Button {
                if copySelection() { flow.toast("Texto copiado.") }
            } label: { Label("Copiar", systemImage: "doc.on.doc") }
            Divider().frame(height: 20)
            // tocar abre todas as cores; escolher uma destaca e fecha tudo (como a barra do Word)
            Menu {
                ForEach(HighlightColor.allCases) { c in
                    Button { guardEditable { highlightSelection(c) } } label: {
                        Label { Text(c.label) } icon: { Image(uiImage: Self.dot(c)) }
                    }
                }
            } label: {
                Label("Destacar", systemImage: "highlighter")
            }
            if marksInSelection {
                Divider().frame(height: 20)
                Button { guardEditable { unmarkSelection() } } label: { Label("Tirar", systemImage: "eraser") }
                    .accessibilityLabel("Desfazer destaque")
            }
            Divider().frame(height: 20)
            Button { addToSummary() } label: { Label("Resumo", systemImage: "text.badge.plus") }
                .disabled(addingSummary)
                .accessibilityLabel("Adicionar ao resumo")
        }
        .font(.system(size: 13.5, weight: .semibold))
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Capsule().fill(.regularMaterial))
        .padding(.horizontal, Theme.margin)
    }

    /// Barra de baixo, no estilo do app Notas: tudo à mão sem tirar espaço do texto (igual nos dois modos).
    @ViewBuilder private var bottomBar: some View {
        Button {
            showThumbs.toggle()
            UserDefaults.standard.set(showThumbs, forKey: "readerThumbs")
        } label: {
            Image(systemName: showThumbs ? "sidebar.left" : "sidebar.squares.left")
        }
        .accessibilityLabel(showThumbs ? "Esconder as miniaturas" : "Mostrar as miniaturas")
        Spacer()
        Menu {
            Button {
                guardEditable { setMarking(!marking) }
            } label: {
                Label(marking ? "Desligar o marca-texto" : "Ligar o marca-texto", systemImage: "highlighter")
            }
            Picker("Cor", selection: $model.color) {
                ForEach(HighlightColor.allCases) { c in Text(c.label).tag(c) }
            }
        } label: {
            Image(systemName: "highlighter")
                .foregroundStyle(marking ? Color(model.color.uiColor) : Color.accentColor)
        } primaryAction: {
            guardEditable { setMarking(!marking) }
        }
        .accessibilityLabel("Destacar")
        Spacer()
        Button { openSearch() } label: { Image(systemName: "magnifyingglass") }
            .accessibilityLabel("Buscar no documento")
        Spacer()
        Menu {
            Button { addToSummary() } label: { Label("Adicionar a seleção ao resumo", systemImage: "text.badge.plus") }
                .disabled(!hasSelection)
            if let s = summaryItem {
                Button { flow.open(.reader(s.id)) } label: { Label("Abrir o resumo", systemImage: "doc.text") }
            }
        } label: {
            Image(systemName: "text.badge.plus")
        }
        .accessibilityLabel("Resumo")
        Spacer()
        Button { showTools = true } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("Ferramentas")
        Spacer()
        if let target = activeItem { ShareLink(item: target.url) { Image(systemName: "square.and.arrow.up") } }
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
                textOptionsMenu
            } else if saving {
                ProgressView()
            }
        }
    }

    private var textOptionsMenu: some View {
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
    }

    // MARK: - Ações

    /// Destaques, cortes e numeração mudam o arquivo: não valem para PDF com senha nem para PDF assinado.
    private func guardEditable(_ action: () -> Void) {
        if let target = activeItem, target.meta.isSigned {
            flow.toast("Este PDF está assinado digitalmente: qualquer alteração invalidaria a assinatura.")
        } else if locked && mode == .original {
            flow.toast("Este PDF tem senha. Para destacar, crie antes uma cópia sem senha (Ferramentas › Remover senha).")
        } else {
            action()
        }
    }

    private func addToSummary() {
        guard let source = activeItem else { return }
        let ex = mode == .original ? model.excerpt() : textModel.excerpt()
        guard let ex else {
            flow.toast("Selecione o trecho (toque e segure no texto) e depois toque em “Resumo”.")
            return
        }
        addingSummary = true
        let rel = Summary.relativePath(for: source)
        let storeURL = Summary.storeURL(root: library.root, rel: rel)
        let existing = Summary.find(in: library, for: source)
        let before = existing.flatMap { try? Data(contentsOf: $0.url) }
        let storeBefore = try? Data(contentsOf: storeURL)
        Task {
            do {
                let s = try await Summary.add([ex], from: source, library: library)
                if let after = try? Data(contentsOf: s.url) {
                    history.record("Adicionar ao resumo", .summary(summaryID: s.id, rel: s.relativePath, folder: s.folder,
                                                                    name: s.name, before: before, after: after,
                                                                    storeBefore: storeBefore,
                                                                    storeAfter: try? Data(contentsOf: storeURL)))
                }
                if mode == .original { model.clearSelection() } else { textModel.clearSelection() }
                flow.toast("Trecho adicionado a “\(s.name)”.", actionTitle: "Abrir") { flow.open(.reader(s.id)) }
            } catch {
                flow.show(error: error)
            }
            addingSummary = false
        }
    }

    // MARK: desfazer e refazer

    private func undo() { step(forward: false) }
    private func redo() { step(forward: true) }

    private func step(forward: Bool) {
        guard let s = forward ? history.popRedo() : history.popUndo() else { return }
        Task {
            do {
                try await apply(s.change, forward: forward)
                if forward { history.pushUndo(s) } else { history.pushRedo(s) }
                flow.toast(forward ? "Refeito: \(s.label.lowercased())." : "Desfeito: \(s.label.lowercased()).")
            } catch {
                flow.show(error: error)
            }
        }
    }

    private func document(for docID: String) -> PDFDocument? {
        if docID == item?.id, let d = model.pdfView?.document { return d }
        if docID == textModel.docID { return textModel.pdf }
        return nil
    }

    private func apply(_ change: ReaderHistory.Change, forward: Bool) async throws {
        switch change {
        case .marks(let docID, _, _), .recolor(let docID, _, _, _, _):
            guard let doc = document(for: docID) else { throw UserFacingError("O PDF desse destaque não está aberto.") }
            ReaderHistory.apply(change, forward: forward, in: doc)
            model.pdfView?.setNeedsDisplay()
            model.pdfView?.layoutDocumentView()
            textModel.applyMarks()
            model.selectionChanged()
            scheduleSave(docID)
        case .file(let itemID, let before, let after):
            guard let target = library.item(id: itemID) else { return }
            cancelSaves()
            try await library.replaceContents(target, with: forward ? after : before)
            reloadDocument()
        case .summary(_, let rel, let folder, let name, let before, let after, let storeBefore, let storeAfter):
            let storeURL = Summary.storeURL(root: library.root, rel: rel)
            let current = library.item(path: rel)
            let data = forward ? after : before
            if let data {
                if let current {
                    try await library.replaceContents(current, with: data)
                } else {
                    _ = try library.save(newData: data, name: name, folder: folder)
                }
            } else if let current {
                try library.delete([current])
            }
            let store = forward ? storeAfter : storeBefore
            if let store {
                try? store.write(to: storeURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: storeURL)
            }
        }
    }

    // MARK: gravar

    /// Grava os destaques pouco depois da última mudança (e ao sair do leitor).
    private func scheduleSave(_ docID: String) {
        saveTasks[docID]?.cancel()
        saveTasks[docID] = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await save(docID)
        }
    }

    private func cancelSaves() {
        for t in saveTasks.values { t.cancel() }
        saveTasks = [:]
    }

    private func saveAllNow() {
        let ids = Array(saveTasks.keys)
        guard !ids.isEmpty else { return }
        cancelSaves()
        Task { for id in ids { await save(id) } }
    }

    /// Grava agora o que estiver pendente (antes de cortar, numerar ou assinar).
    private func flushSaves() async {
        let ids = Array(saveTasks.keys)
        cancelSaves()
        for id in ids { await save(id) }
    }

    private func save(_ docID: String) async {
        defer { saveTasks[docID] = nil }
        guard let target = library.item(id: docID), target.meta.locked != true, !target.meta.isSigned,
              let doc = document(for: docID) else { return }
        saving = true
        do {
            try await library.saveEdited(target, document: doc)
            if docID == itemID { expectedVersion = library.item(id: itemID)?.version }
        } catch {
            flow.show(error: error)
        }
        saving = false
    }

    private func reloadDocument() {
        expectedVersion = library.item(id: itemID)?.version
        reloadToken += 1
        model.clearSearch()
        if mode == .text, let source = textSource {
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                let shared = source.id == item?.id ? model.pdfView?.document : nil
                let fresh = library.item(id: source.id) ?? source
                await textModel.load(url: fresh.url, version: fresh.version, pdf: shared, id: fresh.id,
                                     reviewPages: fresh.meta.reviewPages ?? [], force: true)
            }
        }
    }

    private func runPendingAction() {
        guard let action = pendingAction, let target = activeItem else { return }
        pendingAction = nil
        switch action {
        case .textMode: mode = .text
        case .pageMode: mode = .original
        case .goToPage:
            pageText = ""
            askPage = true
        case .crop, .number:
            guardEditable {
                Task {
                    await flushSaves()
                    fileBefore = try? Data(contentsOf: target.url)
                    sheetAction = action
                }
            }
        case .split, .dewarp, .protect:
            if action != .split, target.meta.isSigned {
                flow.toast("Este PDF está assinado digitalmente: qualquer alteração invalidaria a assinatura.")
            } else {
                sheetAction = action
            }
        case .sign:
            Task {
                await flushSaves()
                sheetAction = .sign
            }
        case .ocr:
            if jobs.isBusy(with: target.id) {
                flow.toast("O OCR deste PDF já está em andamento.")
            } else if target.meta.textStatus == .digital {
                flow.toast("Todas as páginas já têm texto selecionável. O OCR não é necessário.")
            } else {
                jobs.startOCR(target, library: library, flow: flow)
            }
        case .organize: guardEditable { flow.open(.organize(target.id)) }
        case .insert: guardEditable { showInsertMenu = true }
        case .remove: guardEditable { flow.openTool("remove", on: target) }
        case .extract: flow.openTool("extract", on: target)
        case .merge:
            flow.mergePreselection = [target.id]
            flow.open(.merge)
        case .unprotect: askUnprotect = true
        case .duplicate:
            do {
                if let copy = try library.duplicate(target) { flow.toast("Cópia criada: \(copy.name)") }
            } catch { flow.show(error: error) }
        case .favorite:
            library.setFavorite(target, !target.meta.favorite)
            flow.toast(target.meta.favorite ? "Removido dos Favoritos." : "Adicionado aos Favoritos.")
        case .rename: actions.rename(target)
        case .move: actions.move([target])
        case .details: flow.open(.document(target.id))
        case .undo: confirmUndo = true
        case .delete: actions.delete([target])
        case .openSummary:
            if let s = summaryItem { flow.open(.reader(s.id)) }
        }
    }

    /// Depois de cortar ou numerar: guarda o antes e o depois para o desfazer.
    private func sheetClosed() {
        guard let before = fileBefore, let target = activeItem else { return }
        fileBefore = nil
        if let after = try? Data(contentsOf: target.url), after != before {
            history.record("Corte ou numeração", .file(itemID: target.id, before: before, after: after))
        }
    }

    @ViewBuilder
    private func actionSheet(_ action: ReaderAction, item: PDFItem) -> some View {
        switch action {
        case .crop:
            CropSheet(item: item, startPage: shownPage, onDone: { reloadDocument() })
                .appEnvironment()
        case .number:
            NumberSheet(item: item, onDone: { reloadDocument() })
                .appEnvironment()
        case .split:
            SplitSheet(item: item).appEnvironment()
        case .dewarp:
            DewarpSheet(item: item).appEnvironment()
        case .sign:
            SignSheet(item: item).appEnvironment()
        default:
            ProtectSheet(item: item).appEnvironment()
        }
    }
}

/// Todas as funções do app, a partir do leitor.
struct ReaderToolsSheet: View {
    let item: PDFItem?
    let mode: ReaderMode
    let locked: Bool
    let hasTextMode: Bool
    let hasSummary: Bool
    let canUndo: Bool
    let onPick: (ReaderAction) -> Void
    @Environment(\.dismiss) private var dismiss

    private var signed: Bool { item?.meta.isSigned == true }

    var body: some View {
        NavigationStack {
            List {
                Section(mode == .original ? "Página" : "Texto") {
                    if mode == .text {
                        row("Ver as páginas (original)", "doc", .pageMode)
                    } else if hasTextMode {
                        row("Modo leitor (só o texto)", "text.alignleft", .textMode)
                    }
                    row("Ir para a página…", "arrow.right.doc.on.clipboard", .goToPage)
                    row("Cortar e girar páginas", "crop.rotate", .crop, disabled: locked || signed)
                    row("Numerar páginas", "number", .number, disabled: locked || signed)
                    if hasSummary { row("Abrir o resumo deste PDF", "doc.text", .openSummary) }
                }
                Section("Documento") {
                    row(signed ? "Assinar de novo (outra assinatura)" : "Assinar digitalmente", "signature", .sign,
                        disabled: locked)
                    row("Fazer OCR", "text.viewfinder", .ocr, disabled: locked || signed)
                    row("Organizar páginas", "rectangle.grid.2x2", .organize, disabled: locked || signed)
                    row("Incluir páginas", "plus.rectangle.on.rectangle", .insert, disabled: locked || signed)
                    row("Remover páginas", "minus.rectangle", .remove, disabled: locked || signed)
                    row("Extrair páginas", "doc.badge.plus", .extract, disabled: locked)
                    row("Dividir em partes", "scissors", .split, disabled: locked)
                    row("Combinar com outros PDFs", "square.stack.3d.down.right", .merge)
                    row("Corrigir páginas curvas", "book.pages", .dewarp, disabled: locked || signed)
                    if locked {
                        row("Remover senha", "lock.open", .unprotect)
                    } else {
                        row("Proteger com senha", "lock", .protect, disabled: signed)
                    }
                    row("Duplicar", "plus.square.on.square", .duplicate)
                }
                Section("Arquivo") {
                    if let item {
                        ShareLink(item: item.url) { Label("Compartilhar", systemImage: "square.and.arrow.up") }
                        row(item.meta.favorite ? "Remover dos favoritos" : "Favoritar",
                            item.meta.favorite ? "star.slash" : "star", .favorite)
                    }
                    row("Renomear", "pencil", .rename)
                    row("Mover para pasta", "folder", .move)
                    row("Ver detalhes do PDF", "info.circle", .details)
                    row("Desfazer última alteração", "arrow.uturn.backward", .undo, disabled: !canUndo)
                    Button(role: .destructive) { onPick(.delete) } label: { Label("Excluir", systemImage: "trash") }
                }
            }
            .navigationTitle("Ferramentas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ title: String, _ icon: String, _ action: ReaderAction, disabled: Bool = false) -> some View {
        Button { onPick(action) } label: { Label(title, systemImage: icon) }
            .disabled(disabled)
    }
}

import PDFKit
import SwiftUI
import UIKit

/// Estado do leitor: página, busca, seleção de texto, marca-texto e destaques novos.
@MainActor
final class ReaderModel: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    weak var pdfView: PDFView?
    @Published var currentPage = 1
    @Published var pageCount = 0
    @Published var results: [PDFSelection] = []
    @Published var resultIndex = 0
    @Published var searched = false
    @Published var hasSelection = false
    /// Marca-texto ligado: um dedo destaca, dois dedos rolam (como a Marcação da Apple).
    @Published private(set) var marking = false
    @Published var color: HighlightColor = HighlightColor(rawValue: UserDefaults.standard.string(forKey: "readerColor") ?? "") ?? .yellow {
        didSet { UserDefaults.standard.set(color.rawValue, forKey: "readerColor") }
    }
    @Published var canUndoMark = false
    /// Destaque tocado (para apagar ou mudar a cor).
    @Published var tappedMark: PDFAnnotation?
    /// Chamado quando o documento muda (destaque novo, apagado...), para gravar.
    var onChange: (() -> Void)?
    private var sessionMarks: [[PDFAnnotation]] = []
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
        currentPage = doc.index(for: page) + 1
        pageCount = doc.pageCount
    }

    func selectionChanged() {
        let text = pdfView?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        hasSelection = !text.isEmpty && !marking
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
                apply(sel)
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

    private func apply(_ selection: PDFSelection) {
        guard let doc = pdfView?.document else { return }
        let added = Highlights.add(selection, color: color, in: doc)
        guard !added.isEmpty else { return }
        sessionMarks.append(added)
        canUndoMark = true
        onChange?()
    }

    /// Destaca o texto selecionado (sem o marca-texto).
    func highlightSelection(_ c: HighlightColor) {
        guard let sel = pdfView?.currentSelection else { return }
        color = c
        apply(sel)
        pdfView?.clearSelection()
        selectionChanged()
    }

    func undoMark() {
        guard let last = sessionMarks.popLast() else { return }
        for a in last { Highlights.remove(a) }
        canUndoMark = !sessionMarks.isEmpty
        onChange?()
    }

    func removeMark(_ a: PDFAnnotation) {
        Highlights.remove(a)
        for k in sessionMarks.indices { sessionMarks[k].removeAll { $0 === a } }
        sessionMarks.removeAll { $0.isEmpty }
        canUndoMark = !sessionMarks.isEmpty
        onChange?()
    }

    func recolorMark(_ a: PDFAnnotation, _ c: HighlightColor) {
        Highlights.recolor(a, c)
        onChange?()
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
}

/// O PDFView e, à esquerda, a coluna de miniaturas (que aparece e some pela barra de baixo).
final class ReaderContainerView: UIView {
    let pdfView = PDFView()
    let thumbs = PDFThumbnailView()
    private var leading: NSLayoutConstraint!
    private var widthConstraint: NSLayoutConstraint!
    static let thumbsWidth: CGFloat = 92

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
    case textMode, goToPage, crop, number, ocr, organize, insert, remove, extract, split, merge, dewarp,
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
    @State private var mode: ReaderMode = .original
    @State private var didSetMode = false
    @State private var query = ""
    @State private var searchShown = false
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
    @State private var saveTask: Task<Void, Never>?
    @State private var saving = false
    @State private var confirmUndo = false
    @State private var askUnprotect = false
    @State private var unprotectText = ""
    @State private var showInsertMenu = false
    @State private var addingSummary = false

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

    private var summaryItem: PDFItem? { item.flatMap { Summary.find(in: library, for: $0) } }

    // O corpo fica dividido em partes: numa expressão só, o compilador não dá conta de conferir os tipos.
    var body: some View {
        lifecycle(dialogs(sheets(chrome)))
    }

    /// O leitor, a barra flutuante e as barras de cima e de baixo.
    private var chrome: some View {
        ZStack(alignment: .bottom) {
            if mode == .original {
                originalPane
            } else {
                TextReaderPane(model: textModel)
            }
            VStack(spacing: 8) {
                if mode == .original { floatingBar }
                pageBar
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(item?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .toolbar { ToolbarItemGroup(placement: .bottomBar) { bottomBar } }
        .toolbarBackground(.visible, for: .bottomBar)
        .modifier(ItemActionsModifier(actions: actions, onDeleted: { dismiss() }))
    }

    private var markDialogShown: Binding<Bool> {
        Binding(get: { model.tappedMark != nil }, set: { if !$0 { model.tappedMark = nil } })
    }

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
                                presenting: model.tappedMark) { mark in
                markActions(mark)
            } message: { mark in
                Text(markMessage(mark))
            }
            .sheet(isPresented: $showTools, onDismiss: runPendingAction) { toolsSheet }
            .sheet(item: $sheetAction) { action in
                actionSheetIfPossible(action)
            }
    }

    @ViewBuilder private func actionSheetIfPossible(_ action: ReaderAction) -> some View {
        if let item { actionSheet(action, item: item) }
    }

    @ViewBuilder private func markActions(_ mark: PDFAnnotation) -> some View {
        Button("Apagar o destaque", role: .destructive) { guardEditable { model.removeMark(mark) } }
        ForEach(HighlightColor.allCases) { c in
            Button("Mudar para \(c.label.lowercased())") { guardEditable { model.recolorMark(mark, c) } }
        }
        Button("Cancelar", role: .cancel) {}
    }

    private func markMessage(_ mark: PDFAnnotation) -> String {
        let text = mark.contents ?? ""
        return text.isEmpty ? "Trecho destacado." : "“\(text.prefix(120))”"
    }

    private var toolsSheet: some View {
        ReaderToolsSheet(item: item, locked: locked, hasTextMode: textSource != nil,
                         hasSummary: summaryItem != nil, canUndo: item.map { library.canUndo($0) } ?? false,
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

    /// Desfazer, remover a senha e incluir páginas.
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
        guard let item else { return }
        do {
            saveTask?.cancel()
            saveTask = nil
            try library.undo(item)
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
            .onDisappear { saveNow() }
            .onChange(of: item?.version) { _, new in versionChanged(new) }
            .task(id: mode) { await loadTextIfNeeded() }
            .onChange(of: mode) { old, new in modeChanged(from: old, to: new) }
    }

    private func appeared() {
        if let item {
            library.markOpened(item)
            if expectedVersion == nil { expectedVersion = item.version }
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
        model.onChange = { scheduleSave() }
    }

    /// O arquivo mudou por outra ferramenta (organizar, remover, desfazer): lê de novo.
    private func versionChanged(_ new: String?) {
        guard let new, !saving, saveTask == nil, new != expectedVersion else { return }
        expectedVersion = new
        reloadDocument()
    }

    private func loadTextIfNeeded() async {
        guard mode == .text, let source = textSource else { return }
        await textModel.load(url: source.url, reviewPages: source.meta.reviewPages ?? [])
    }

    /// Mantém a mesma página ao trocar de modo.
    private func modeChanged(from old: ReaderMode, to new: ReaderMode) {
        if new == .text {
            model.setMarking(false)
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
            PDFKitView(url: item.url, model: model, password: password, showThumbnails: showThumbs,
                       reloadToken: reloadToken)
                .ignoresSafeArea(edges: .bottom)
                .searchable(text: $query, isPresented: $searchShown, placement: .navigationBarDrawer(displayMode: .automatic),
                            prompt: "Buscar no documento")
                .onSubmit(of: .search) { model.search(query) }
                .onChange(of: query) { _, newValue in
                    if newValue.isEmpty { model.clearSearch() }
                }
        }
    }

    /// Barra flutuante: ações do texto selecionado, ou o aviso do marca-texto ligado.
    @ViewBuilder private var floatingBar: some View {
        if model.marking {
            HStack(spacing: 12) {
                Circle().fill(Color(model.color.uiColor)).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 1))
                Text("Passe o dedo sobre o texto. Dois dedos rolam.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if model.canUndoMark {
                    Button { model.undoMark() } label: { Image(systemName: "arrow.uturn.backward") }
                        .accessibilityLabel("Desfazer destaque")
                }
                Button("OK") { model.setMarking(false) }.fontWeight(.semibold)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Capsule().fill(.regularMaterial))
            .padding(.horizontal, Theme.margin)
        } else if model.hasSelection {
            HStack(spacing: 6) {
                Button {
                    if model.copySelection() { flow.toast("Texto copiado.") }
                } label: { Label("Copiar", systemImage: "doc.on.doc") }
                Divider().frame(height: 20)
                Menu {
                    ForEach(HighlightColor.allCases) { c in
                        Button { guardEditable { model.highlightSelection(c) } } label: { Text(c.label) }
                    }
                } label: {
                    Label("Destacar", systemImage: "highlighter")
                } primaryAction: {
                    guardEditable { model.highlightSelection(model.color) }
                }
                Divider().frame(height: 20)
                Button { addToSummary() } label: { Label("Ao resumo", systemImage: "text.badge.plus") }
                    .disabled(addingSummary)
            }
            .font(.system(size: 14, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Capsule().fill(.regularMaterial))
            .padding(.horizontal, Theme.margin)
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

    /// Barra de baixo, no estilo do app Notas: tudo à mão sem tirar espaço do texto.
    @ViewBuilder private var bottomBar: some View {
        if mode == .original {
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
                    guardEditable { model.setMarking(!model.marking) }
                } label: {
                    Label(model.marking ? "Desligar o marca-texto" : "Ligar o marca-texto", systemImage: "highlighter")
                }
                Picker("Cor", selection: $model.color) {
                    ForEach(HighlightColor.allCases) { c in Text(c.label).tag(c) }
                }
                if model.canUndoMark {
                    Button { model.undoMark() } label: { Label("Desfazer o último destaque", systemImage: "arrow.uturn.backward") }
                }
            } label: {
                Image(systemName: "highlighter")
                    .foregroundStyle(model.marking ? Color(model.color.uiColor) : Color.accentColor)
            } primaryAction: {
                guardEditable { model.setMarking(!model.marking) }
            }
            .accessibilityLabel("Destacar")
            Spacer()
            Button { searchShown = true } label: { Image(systemName: "magnifyingglass") }
                .accessibilityLabel("Buscar no documento")
            Spacer()
            Menu {
                Button { addToSummary() } label: { Label("Adicionar a seleção ao resumo", systemImage: "text.badge.plus") }
                    .disabled(!model.hasSelection)
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
            if let item { ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") } }
        } else {
            Button { textModel.presentFind() } label: { Image(systemName: "magnifyingglass") }
            Spacer()
            Button { showTools = true } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Ferramentas")
            Spacer()
            if let item { ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") } }
        }
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
            } else if saving {
                ProgressView()
            }
        }
    }

    // MARK: - Ações

    /// Destaques e cortes mudam o arquivo: não valem para PDF com senha (a cópia perderia a senha).
    private func guardEditable(_ action: () -> Void) {
        if locked {
            flow.toast("Este PDF tem senha. Para destacar, crie antes uma cópia sem senha (Ferramentas › Remover senha).")
        } else {
            action()
        }
    }

    private func addToSummary() {
        guard let item else { return }
        guard let ex = model.excerpt() else {
            flow.toast("Selecione o trecho (toque e segure no texto) e depois toque em “Ao resumo”.")
            return
        }
        addingSummary = true
        Task {
            do {
                let s = try await Summary.add([ex], from: item, library: library)
                model.pdfView?.clearSelection()
                model.selectionChanged()
                flow.toast("Trecho adicionado a “\(s.name)”.", actionTitle: "Abrir") { flow.open(.reader(s.id)) }
            } catch {
                flow.show(error: error)
            }
            addingSummary = false
        }
    }

    /// Grava os destaques pouco depois da última mudança (e ao sair do leitor).
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func saveNow() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        Task { await save() }
    }

    private func save() async {
        guard let item, let doc = model.pdfView?.document, !locked else {
            saveTask = nil
            return
        }
        saving = true
        do {
            try await library.saveEdited(item, document: doc)
            expectedVersion = library.item(id: itemID)?.version
        } catch {
            flow.show(error: error)
        }
        saving = false
        saveTask = nil
    }

    private func reloadDocument() {
        expectedVersion = library.item(id: itemID)?.version
        reloadToken += 1
        model.clearSearch()
    }

    private func runPendingAction() {
        guard let action = pendingAction, let item else { return }
        pendingAction = nil
        switch action {
        case .textMode: mode = .text
        case .goToPage:
            pageText = ""
            askPage = true
        case .crop, .number, .split, .dewarp, .protect:
            guardEditable { sheetAction = action }
        case .ocr:
            if jobs.isBusy(with: item.id) {
                flow.toast("O OCR deste PDF já está em andamento.")
            } else if item.meta.textStatus == .digital {
                flow.toast("Todas as páginas já têm texto selecionável. O OCR não é necessário.")
            } else {
                jobs.startOCR(item, library: library, flow: flow)
            }
        case .organize: guardEditable { flow.open(.organize(item.id)) }
        case .insert: guardEditable { showInsertMenu = true }
        case .remove: guardEditable { flow.openTool("remove", on: item) }
        case .extract: guardEditable { flow.openTool("extract", on: item) }
        case .merge:
            flow.mergePreselection = [item.id]
            flow.open(.merge)
        case .unprotect: askUnprotect = true
        case .duplicate:
            do {
                if let copy = try library.duplicate(item) { flow.toast("Cópia criada: \(copy.name)") }
            } catch { flow.show(error: error) }
        case .favorite:
            library.setFavorite(item, !item.meta.favorite)
            flow.toast(item.meta.favorite ? "Removido dos Favoritos." : "Adicionado aos Favoritos.")
        case .rename: actions.rename(item)
        case .move: actions.move([item])
        case .details: flow.open(.document(item.id))
        case .undo: confirmUndo = true
        case .delete: actions.delete([item])
        case .openSummary:
            if let s = summaryItem { flow.open(.reader(s.id)) }
        }
    }

    @ViewBuilder
    private func actionSheet(_ action: ReaderAction, item: PDFItem) -> some View {
        switch action {
        case .crop:
            CropSheet(item: item, startPage: model.currentPage, onDone: { reloadDocument() })
                .appEnvironment()
        case .number:
            NumberSheet(item: item, onDone: { reloadDocument() })
                .appEnvironment()
        case .split:
            SplitSheet(item: item).appEnvironment()
        case .dewarp:
            DewarpSheet(item: item).appEnvironment()
        default:
            ProtectSheet(item: item).appEnvironment()
        }
    }
}

/// Todas as funções do app, a partir do leitor.
struct ReaderToolsSheet: View {
    let item: PDFItem?
    let locked: Bool
    let hasTextMode: Bool
    let hasSummary: Bool
    let canUndo: Bool
    let onPick: (ReaderAction) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Página") {
                    if hasTextMode { row("Modo leitor (só o texto)", "text.alignleft", .textMode) }
                    row("Ir para a página…", "arrow.right.doc.on.clipboard", .goToPage)
                    row("Cortar e girar páginas", "crop.rotate", .crop, disabled: locked)
                    row("Numerar páginas", "number", .number, disabled: locked)
                    if hasSummary { row("Abrir o resumo deste PDF", "doc.text", .openSummary) }
                }
                Section("Documento") {
                    row("Fazer OCR", "text.viewfinder", .ocr, disabled: locked)
                    row("Organizar páginas", "rectangle.grid.2x2", .organize, disabled: locked)
                    row("Incluir páginas", "plus.rectangle.on.rectangle", .insert, disabled: locked)
                    row("Remover páginas", "minus.rectangle", .remove, disabled: locked)
                    row("Extrair páginas", "doc.badge.plus", .extract, disabled: locked)
                    row("Dividir em partes", "scissors", .split, disabled: locked)
                    row("Combinar com outros PDFs", "square.stack.3d.down.right", .merge)
                    row("Corrigir páginas curvas", "book.pages", .dewarp, disabled: locked)
                    if locked {
                        row("Remover senha", "lock.open", .unprotect)
                    } else {
                        row("Proteger com senha", "lock", .protect)
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

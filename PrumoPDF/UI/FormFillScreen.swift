import PDFKit
import SwiftUI
import UIKit

/// "Preencher formulário": campos do PDF (o PDFKit deixa tocar e preencher) e, em PDF sem campos, caixas de
/// texto e marcas (✓ ✗ ●) em qualquer lugar. A barra de baixo é a barra de formatação do Got It!
/// (ferramentas, Fonte, tamanho, negrito, cor). Salvar grava no próprio PDF; Finalizar cria uma cópia achatada.
@MainActor
final class FormModel: ObservableObject {
    @Published var tool: FormTool = .select
    @Published var style = FormStyle()
    @Published var selected: String?             // /NM da caixa escolhida
    @Published var editing: FormEditRequest?
    @Published var historyChanged = 0
    var document: PDFDocument?
    weak var pdfView: PDFView?
    private var history: [[FormBox]] = []
    private var position = 0
    private var savedBoxes: [FormBox] = []
    private var savedFields: [String] = []
    private var drag: (name: String, start: CGPoint, original: FormBox)?

    static let styleKey = "formStyle"

    func load(url: URL) throws {
        let doc = try PDFOps.open(url)
        FormBoxes.normalize(doc)
        document = doc
        if let data = UserDefaults.standard.data(forKey: Self.styleKey),
           let saved = try? JSONDecoder().decode(FormStyle.self, from: data) {
            style = saved
        }
        tool = FormFields.count(doc) > 0 ? .select : .text
        let boxes = FormBoxes.read(doc)
        history = [boxes]
        position = 0
        savedBoxes = boxes
        savedFields = FormFields.snapshot(doc)
    }

    var boxes: [FormBox] { document.map { FormBoxes.read($0) } ?? [] }
    var canUndo: Bool { position > 0 }
    var canRedo: Bool { position < history.count - 1 }
    var hasFields: Bool { document.map { FormFields.count($0) > 0 } ?? false }

    var dirty: Bool {
        guard let doc = document else { return false }
        return boxes != savedBoxes || FormFields.snapshot(doc) != savedFields
    }

    func markSaved() {
        guard let doc = document else { return }
        savedBoxes = boxes
        savedFields = FormFields.snapshot(doc)
        historyChanged += 1
    }

    // MARK: - Histórico (desfazer e refazer valem para as caixas; o texto dos campos tem o desfazer do teclado)

    func commit() {
        let now = boxes
        if history.isEmpty {
            history = [now]
            position = 0
            historyChanged += 1
            return
        }
        guard now != history[position] else { historyChanged += 1; return }
        history.removeSubrange((position + 1)...)
        history.append(now)
        if history.count > 200 { history.removeFirst() }
        position = history.count - 1
        historyChanged += 1
    }

    func undo() {
        guard canUndo, let doc = document else { return }
        position -= 1
        restore(history[position], doc)
    }

    func redo() {
        guard canRedo, let doc = document else { return }
        position += 1
        restore(history[position], doc)
    }

    private func restore(_ boxes: [FormBox], _ doc: PDFDocument) {
        hideSelection()
        FormBoxes.apply(boxes, to: doc)
        if let s = selected, !boxes.contains(where: { $0.name == s }) { selected = nil }
        showSelection()
        historyChanged += 1
    }

    // MARK: - Seleção (um retângulo tracejado que não vai para o arquivo)

    func hideSelection() {
        guard let doc = document else { return }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where FormBoxes.isSelection(a) { page.removeAnnotation(a) }
        }
    }

    func showSelection() {
        hideSelection()
        guard let name = selected, let doc = document, let b = boxes.first(where: { $0.name == name }) else { return }
        let r = b.bounds.insetBy(dx: -3, dy: -3)
        let a = PDFAnnotation(bounds: r, forType: .square, withProperties: nil)
        a.color = UIColor.systemBlue
        let border = PDFBorder()
        border.lineWidth = 1
        border.style = .dashed
        border.dashPattern = [4, 3]
        a.border = border
        _ = a.setValue(FormBoxes.selectionName, forAnnotationKey: .name)
        _ = a.setValue(FormBoxes.selectionName, forAnnotationKey: FormBoxes.idKey)
        doc.page(at: b.page)?.addAnnotation(a)
    }

    func select(_ name: String?) {
        selected = name
        if let name, let b = boxes.first(where: { $0.name == name }) {
            style.font = b.style.font
            style.bold = b.style.bold
            style.color = b.style.color
            if b.kind == "text" { style.size = b.style.size }
        }
        showSelection()
    }

    // MARK: - Toques na página

    private func pagePoint(_ location: CGPoint) -> (PDFPage, Int, CGPoint)? {
        guard let view = pdfView, let doc = document, let page = view.page(for: location, nearest: false) else { return nil }
        let p = view.convert(location, to: page)
        guard page.bounds(for: .cropBox).contains(p) else { return nil }
        return (page, doc.index(for: page), p)
    }

    private func box(at index: Int, _ p: CGPoint) -> FormBox? {
        boxes.last { $0.page == index && $0.bounds.insetBy(dx: -6, dy: -6).contains(p) }
    }

    func tap(_ location: CGPoint) {
        guard let (page, index, p) = pagePoint(location) else { return }
        if let b = box(at: index, p) {
            if b.kind == "text" && (tool == .text || selected == b.name) {
                select(b.name)
                editing = FormEditRequest(page: index, point: CGPoint(x: b.bounds.minX, y: b.bounds.maxY),
                                          name: b.name, text: b.text)
            } else {
                select(b.name)
            }
            return
        }
        // um toque num campo do PDF é do próprio PDFKit
        if let a = page.annotation(at: p), a.type == "Widget" { return }
        switch tool {
        case .select:
            select(nil)
        case .text:
            select(nil)
            let top = p.y + style.size * FormBoxes.line / 2 + FormBoxes.pad
            editing = FormEditRequest(page: index, point: CGPoint(x: p.x - FormBoxes.pad, y: top), name: nil, text: "")
        case .check, .cross, .dot:
            let s = max(10, style.size * 1.1)
            let b = FormBox(page: index, bounds: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s),
                            kind: tool.rawValue, text: "", style: style, name: FormBoxes.newName(kind: tool.rawValue))
            page.addAnnotation(FormBoxes.make(b))
            select(b.name)
            commit()
        }
    }

    /// Terminar a edição de uma caixa de texto (nova ou existente).
    func finishEditing(_ req: FormEditRequest, text: String) {
        guard let doc = document, let page = doc.page(at: req.page) else { return }
        hideSelection()
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
        if let name = req.name, let old = page.annotations.first(where: { FormBoxes.name(of: $0) == name }) {
            page.removeAnnotation(old)
        }
        if !clean.isEmpty {
            let size = FormBoxes.size(text: clean, style: style)
            let b = FormBox(page: req.page, bounds: CGRect(x: req.point.x, y: req.point.y - size.height,
                                                           width: size.width, height: size.height),
                            kind: "text", text: clean, style: style, name: req.name ?? FormBoxes.newName(kind: "text"))
            page.addAnnotation(FormBoxes.make(b))
            selected = b.name
        } else if req.name == selected {
            selected = nil
        }
        showSelection()
        commit()
    }

    // MARK: - Arrastar (tocar e segurar sobre a caixa)

    func dragBegan(_ location: CGPoint) -> Bool {
        guard let (_, index, p) = pagePoint(location), let b = box(at: index, p) else { return false }
        select(b.name)
        drag = (b.name, p, b)
        return true
    }

    func dragChanged(_ location: CGPoint) {
        guard let d = drag, let doc = document, let page = doc.page(at: d.original.page), let view = pdfView else { return }
        let p = view.convert(location, to: page)
        var b = d.original
        let crop = page.bounds(for: .cropBox)
        var r = b.bounds.offsetBy(dx: p.x - d.start.x, dy: p.y - d.start.y)
        r.origin.x = min(max(crop.minX, r.origin.x), crop.maxX - r.width)
        r.origin.y = min(max(crop.minY, r.origin.y), crop.maxY - r.height)
        b.bounds = r
        hideSelection()
        if let old = page.annotations.first(where: { FormBoxes.name(of: $0) == d.name }) { page.removeAnnotation(old) }
        page.addAnnotation(FormBoxes.make(b))
        showSelection()
    }

    func dragEnded() {
        guard drag != nil else { return }
        drag = nil
        commit()
    }

    // MARK: - Formatação e apagar

    func setStyle(_ change: (inout FormStyle) -> Void) {
        change(&style)
        if let data = try? JSONEncoder().encode(style) { UserDefaults.standard.set(data, forKey: Self.styleKey) }
        guard let name = selected, let doc = document, var b = boxes.first(where: { $0.name == name }),
              let page = doc.page(at: b.page) else { return }
        let top = b.bounds.maxY
        if b.kind == "text" {
            b.style = style
            let size = FormBoxes.size(text: b.text, style: style)
            b.bounds = CGRect(x: b.bounds.minX, y: top - size.height, width: size.width, height: size.height)
        } else {
            let s = max(10, style.size * 1.1)
            b.style = style
            b.style.size = s
            b.bounds = CGRect(x: b.bounds.midX - s / 2, y: b.bounds.midY - s / 2, width: s, height: s)
        }
        hideSelection()
        if let old = page.annotations.first(where: { FormBoxes.name(of: $0) == name }) { page.removeAnnotation(old) }
        page.addAnnotation(FormBoxes.make(b))
        showSelection()
        commit()
    }

    func deleteSelected() {
        guard let name = selected, let doc = document else { return }
        hideSelection()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where FormBoxes.name(of: a) == name { page.removeAnnotation(a) }
        }
        selected = nil
        commit()
    }
}

struct FormEditRequest: Identifiable {
    let id = UUID()
    let page: Int
    let point: CGPoint          // canto de cima à esquerda (coordenadas da página)
    let name: String?
    let text: String
}

/// O PDFView da tela, com toque (criar, escolher) e tocar e segurar (arrastar a caixa).
struct FormPDFView: UIViewRepresentable {
    @ObservedObject var model: FormModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = Theme.backgroundUI
        view.document = model.document
        model.pdfView = view
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = 0.25
        hold.delegate = context.coordinator
        view.addGestureRecognizer(hold)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== model.document { view.document = model.document }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let model: FormModel
        init(model: FormModel) { self.model = model }

        @MainActor @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            model.tap(g.location(in: v))
        }

        @MainActor @objc func held(_ g: UILongPressGestureRecognizer) {
            guard let v = g.view else { return }
            switch g.state {
            case .began:
                if !model.dragBegan(g.location(in: v)) {
                    g.isEnabled = false
                    g.isEnabled = true
                }
            case .changed: model.dragChanged(g.location(in: v))
            case .ended, .cancelled, .failed: model.dragEnded()
            default: break
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            g is UITapGestureRecognizer
        }
    }
}

struct FormFillScreen: View {
    let itemID: String
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = FormModel()
    @State private var loadError: String?
    @State private var askLeave = false
    @State private var askFinalize = false
    @State private var busy = false

    private var item: PDFItem? { library.item(id: itemID) }

    var body: some View {
        Group {
            if let loadError {
                EmptyStateView(systemImage: "exclamationmark.triangle", title: L("Não foi possível abrir o formulário"),
                               message: loadError)
            } else if model.document != nil {
                FormPDFView(model: model)
                    .ignoresSafeArea(edges: .bottom)
                    .safeAreaInset(edge: .bottom) { FormatBar(model: model) }
                    .accessibilityIdentifier("formView")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(item?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { leave() } label: { Image(systemName: "chevron.backward") }
                    .accessibilityLabel(L("Voltar"))
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.canUndo).accessibilityLabel(L("Desfazer"))
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.canRedo).accessibilityLabel(L("Refazer"))
                Menu {
                    Button { Task { await save() } } label: { Label(L("Salvar"), systemImage: "square.and.arrow.down") }
                    Button { askFinalize = true } label: { Label(L("Finalizar"), systemImage: "checkmark.seal") }
                } label: {
                    Text(verbatim: L("Salvar")).fontWeight(.semibold)
                } primaryAction: {
                    Task { await save() }
                }
            }
        }
        .sheet(item: $model.editing) { req in
            FormTextSheet(model: model, request: req)
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog(L("Salvar o preenchimento?"), isPresented: $askLeave, titleVisibility: .visible) {
            Button(L("Salvar")) { Task { if await save(quiet: true) { dismiss() } } }
            Button(L("Descartar"), role: .destructive) { dismiss() }
            Button(L("Continuar editando"), role: .cancel) {}
        } message: {
            Text(verbatim: L("O que foi preenchido ainda não foi gravado no PDF."))
        }
        .confirmationDialog(L("Finalizar o formulário?"), isPresented: $askFinalize, titleVisibility: .visible) {
            Button(L("Finalizar")) { Task { await finalize() } }
            Button(L("Cancelar"), role: .cancel) {}
        } message: {
            Text(verbatim: L("O Prumo cria uma cópia em que os campos e o texto viram parte da página e não podem mais ser alterados. O original continua editável."))
        }
        .overlay { if busy { ProgressView().controlSize(.large) } }
        .task { load() }
    }

    private func load() {
        guard model.document == nil, loadError == nil, let item else { return }
        do {
            try model.load(url: item.url)
            if !model.hasFields {
                flow.toast(L("Este PDF não tem campos: toque na página para escrever."))
            }
            if DemoSeeder.isActive { DemoSeeder.fillFormDemo(model) }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func leave() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if model.dirty { askLeave = true } else { dismiss() }
    }

    @discardableResult
    private func save(quiet: Bool = false) async -> Bool {
        guard let item, let doc = model.document else { return false }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        guard model.dirty else { return true }
        busy = true
        defer { busy = false }
        model.hideSelection()
        defer { model.showSelection() }
        do {
            try await library.saveEdited(item, document: doc)
            model.markSaved()
            if !quiet { flow.toast(L("Formulário salvo no PDF.")) }
            return true
        } catch {
            flow.show(error: error)
            return false
        }
    }

    private func finalize() async {
        guard await save(quiet: true), let item, let doc = model.document else { return }
        busy = true
        defer { busy = false }
        do {
            model.hideSelection()
            defer { model.showSelection() }
            let data = try FormFields.flattened(doc)
            let tmp = library.newTempURL()
            try data.write(to: tmp)
            let base = AppLanguages.stripSuffix(item.name, template: "{} - preenchido")   // i18n: em qualquer idioma
            let new = try library.adopt(fileAt: tmp, name: LF("{} - preenchido", base), folder: item.folder)
            flow.toast(L("Formulário finalizado: cópia criada."), actionTitle: L("Abrir")) {
                flow.open(.document(new.id))
            }
        } catch {
            flow.show(error: error)
        }
    }
}

/// Barra de formatação no formato da do Got It!: rola de lado, ícones de 16 pt, separadores finos.
struct FormatBar: View {
    @ObservedObject var model: FormModel
    private let sizes: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 36]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(FormTool.allCases) { t in
                    Button { model.tool = t } label: {
                        Image(systemName: t.symbol)
                            .frame(minWidth: 28, minHeight: 40)
                            .foregroundStyle(model.tool == t ? Theme.blue : Theme.text)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(model.tool == t ? Theme.blue.opacity(0.14) : .clear))
                    }
                    .accessibilityLabel(t.label)
                }
                separator
                Menu(L("Fonte")) {
                    ForEach(FormFont.allCases) { f in
                        Button { model.setStyle { $0.font = f } } label: {
                            if model.style.font == f { Label(f.label, systemImage: "checkmark") } else { Text(verbatim: f.label) }
                        }
                    }
                }.font(.subheadline)
                Menu {
                    ForEach(sizes, id: \.self) { s in
                        Button { model.setStyle { $0.size = s } } label: {
                            let t = LF("{} pt", Int(s))
                            if model.style.size == s { Label(t, systemImage: "checkmark") } else { Text(verbatim: t) }
                        }
                    }
                } label: { Image(systemName: "textformat.size") }
                    .accessibilityLabel(L("Tamanho da letra"))
                separator
                Button { model.setStyle { $0.bold.toggle() } } label: {
                    Image(systemName: "bold").frame(minWidth: 28, minHeight: 40)
                        .foregroundStyle(model.style.bold ? Theme.blue : Theme.text)
                }
                .accessibilityLabel(L("Negrito"))
                Menu {
                    ForEach(FormColor.allCases) { c in
                        Button { model.setStyle { $0.color = c } } label: {
                            Label(c.label, systemImage: model.style.color == c ? "checkmark.circle.fill" : "circle.fill")
                        }
                    }
                } label: {
                    Image(systemName: "circle.fill").foregroundStyle(Color(model.style.color.uiColor))
                }
                .accessibilityLabel(L("Cor do texto"))
                separator
                Button { model.deleteSelected() } label: { Image(systemName: "trash") }
                    .disabled(model.selected == nil)
                    .accessibilityLabel(L("Apagar a caixa escolhida"))
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                } label: { Image(systemName: "keyboard.chevron.compact.down") }
                    .accessibilityLabel(L("Fechar teclado"))
            }
            .font(.system(size: 16))
            .padding(.horizontal, 18)
            .frame(height: 44)
        }
        .background(.bar)
    }

    private var separator: some View { Divider().frame(height: 20) }
}

/// Escrever o texto de uma caixa (nova ou existente), com a mesma barra de formatação.
struct FormTextSheet: View {
    @ObservedObject var model: FormModel
    let request: FormEditRequest
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(Font(model.style.font.uiFont(size: max(14, model.style.size), bold: model.style.bold) as CTFont))
                    .foregroundStyle(Color(model.style.color.uiColor))
                    .focused($focused)
                    .padding(12)
                    .accessibilityIdentifier("formText")
                FormatBar(model: model)
            }
            .navigationTitle(L("Texto"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancelar")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Concluir")) {
                        model.finishEditing(request, text: text)
                        dismiss()
                    }.fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            text = request.text
            focused = true
        }
    }
}

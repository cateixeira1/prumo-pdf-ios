import PDFKit
import SwiftUI
import UIKit

enum ReaderMode: String, Hashable {
    case original
    case text
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case white = "Branco"
    case sepia = "Sépia"
    case dark = "Escuro"
    var id: String { rawValue }

    var background: UIColor {
        switch self {
        case .white: return .white
        case .sepia: return UIColor(red: 0.98, green: 0.95, blue: 0.88, alpha: 1)
        case .dark: return UIColor(white: 0.1, alpha: 1)
        }
    }
    var text: UIColor {
        switch self {
        case .white: return UIColor(white: 0.1, alpha: 1)
        case .sepia: return UIColor(red: 0.27, green: 0.21, blue: 0.14, alpha: 1)
        case .dark: return UIColor(white: 0.9, alpha: 1)
        }
    }
    var secondary: UIColor {
        switch self {
        case .dark: return UIColor(white: 0.55, alpha: 1)
        default: return UIColor(white: 0.5, alpha: 1)
        }
    }
}

/// Estado do modo leitor: texto montado, preferências de leitura, página visível e — como no modo
/// Página — seleção, destaques (gravados no PDF), marca-texto e trechos para o resumo. Cada letra do
/// texto corrido sabe de que letra do PDF veio.
@MainActor
final class TextReaderModel: NSObject, ObservableObject, UITextViewDelegate, UIGestureRecognizerDelegate {
    @Published private(set) var document: ReaderDocument?
    @Published private(set) var loading = false
    @Published private(set) var revision = 0
    @Published var currentPage = 1
    @Published var hasSelection = false
    @Published var hasMarksInSelection = false
    @Published private(set) var marking = false
    @Published var tappedMark: PDFAnnotation?

    @Published var fontSize: CGFloat {
        didSet { UserDefaults.standard.set(Double(fontSize), forKey: "readerFontSize"); revision += 1 }
    }
    @Published var serif: Bool {
        didSet { UserDefaults.standard.set(serif, forKey: "readerSerif"); revision += 1 }
    }
    @Published var theme: ReaderTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "readerTheme"); revision += 1 }
    }

    weak var textView: UITextView?
    /// O PDF do texto: o mesmo documento do modo Página, quando é o mesmo arquivo.
    private(set) var pdf: PDFDocument?
    private(set) var docID = ""
    private(set) var pageStarts: [Int] = []   // posição (em caracteres) do início de cada página
    private var segments: [(start: Int, length: Int, page: Int, map: [Int])] = []
    private var positions: [Int: [Int: Int]] = [:]   // página → caractere do PDF → posição no texto
    var reviewPages: Set<Int> = []
    private var loadedKey: String?
    /// Destaque feito, apagado ou recolorido (para o desfazer).
    var onEdit: ((String, ReaderHistory.Change) -> Void)?
    var onSummary: (() -> Void)?
    var color: () -> HighlightColor = { .yellow }
    private var markPan: UIPanGestureRecognizer?
    private var markStart: Int?

    override init() {
        let size = UserDefaults.standard.double(forKey: "readerFontSize")
        fontSize = size > 0 ? CGFloat(size) : 19
        serif = UserDefaults.standard.object(forKey: "readerSerif") as? Bool ?? true
        theme = ReaderTheme(rawValue: UserDefaults.standard.string(forKey: "readerTheme") ?? "") ?? .white
        super.init()
    }

    var pageCount: Int { document?.pages.count ?? 0 }

    /// Monta o texto do arquivo (em segundo plano) e usa `pdf` (ou abre o arquivo) para os destaques.
    func load(url: URL, version: String, pdf shared: PDFDocument?, id: String, reviewPages: [Int], force: Bool = false) async {
        let key = "\(url.path)|\(version)"
        if !force, loadedKey == key, pdf != nil, shared == nil || shared === pdf { return }
        loadedKey = key
        docID = id
        self.reviewPages = Set(reviewPages)
        if let shared {
            pdf = shared
        } else {
            pdf = (try? Data(contentsOf: url)).flatMap { PDFDocument(data: $0) }
        }
        loading = true
        let doc = await Task.detached(priority: .userInitiated) { ReaderTextBuilder.build(url: url) }.value
        document = doc
        loading = false
        revision += 1
    }

    func biggerFont() { fontSize = min(fontSize + 2, 34) }
    func smallerFont() { fontSize = max(fontSize - 2, 13) }

    /// Monta o texto formatado e guarda onde começa cada página e de onde veio cada letra.
    func attributedText() -> NSAttributedString {
        guard let document else { return NSAttributedString() }
        let out = NSMutableAttributedString()
        var starts: [Int] = []
        segments = []
        positions = [:]

        let base = UIFont.systemFont(ofSize: fontSize, weight: .regular)
        let bodyFont: UIFont = serif
            ? UIFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: fontSize)
            : base
        let body = NSMutableParagraphStyle()
        body.lineSpacing = fontSize * 0.32
        body.paragraphSpacing = fontSize * 0.75
        body.hyphenationFactor = 0.3
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: theme.text, .paragraphStyle: body]

        let header = NSMutableParagraphStyle()
        header.alignment = .center
        header.paragraphSpacingBefore = fontSize * 0.9
        header.paragraphSpacing = fontSize * 0.8
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(12, fontSize * 0.68), weight: .semibold),
            .foregroundColor: theme.secondary, .paragraphStyle: header, .kern: 0.6,
        ]
        let warnAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(12, fontSize * 0.68), weight: .semibold),
            .foregroundColor: UIColor.systemOrange, .paragraphStyle: header,
        ]
        let emptyAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.italicSystemFont(ofSize: fontSize * 0.85),
            .foregroundColor: theme.secondary, .paragraphStyle: body,
        ]

        for page in document.pages {
            starts.append(out.length)
            out.append(NSAttributedString(string: "PÁGINA \(page.number)\n", attributes: headerAttrs))
            if reviewPages.contains(page.number) {
                out.append(NSAttributedString(string: "Baixa confiança no OCR: confira esta página no original\n",
                                              attributes: warnAttrs))
            }
            if page.isEmpty {
                out.append(NSAttributedString(string: "Nenhum texto nesta página.\n", attributes: emptyAttrs))
            } else {
                var map = positions[page.number - 1] ?? [:]
                for (k, paragraph) in page.paragraphs.enumerated() {
                    let start = out.length
                    out.append(NSAttributedString(string: paragraph + "\n", attributes: bodyAttrs))
                    let idx = k < page.maps.count ? page.maps[k] : []
                    segments.append((start, (paragraph as NSString).length, page.number - 1, idx))
                    for (off, c) in idx.enumerated() where c >= 0 && map[c] == nil { map[c] = start + off }
                }
                positions[page.number - 1] = map
            }
        }
        pageStarts = starts
        return out
    }

    func page(atCharacter index: Int) -> Int {
        guard !pageStarts.isEmpty else { return 1 }
        var page = 1
        for (i, start) in pageStarts.enumerated() where start <= index { page = i + 1 }
        return page
    }

    func scrollTo(page: Int, animated: Bool = false) {
        guard let tv = textView, page >= 1, page <= pageStarts.count else { return }
        let start = pageStarts[page - 1]
        tv.layoutManager.ensureLayout(for: tv.textContainer)
        let glyph = tv.layoutManager.glyphIndexForCharacter(at: start)
        let rect = tv.layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tv.textContainer)
        let y = max(0, min(rect.minY + tv.textContainerInset.top - 8,
                           tv.contentSize.height - tv.bounds.height + tv.adjustedContentInset.bottom))
        tv.setContentOffset(CGPoint(x: 0, y: y - tv.adjustedContentInset.top), animated: animated)
        currentPage = page
    }

    func updateCurrentPage() {
        guard let tv = textView else { return }
        let point = CGPoint(x: tv.textContainerInset.left + 4,
                            y: tv.contentOffset.y + tv.adjustedContentInset.top + 40 - tv.textContainerInset.top)
        let index = tv.layoutManager.characterIndex(for: point, in: tv.textContainer,
                                                    fractionOfDistanceBetweenInsertionPoints: nil)
        let page = self.page(atCharacter: index)
        if page != currentPage { currentPage = page }
    }

    func presentFind() {
        textView?.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    // MARK: Posições: texto corrido ↔ PDF

    /// Trechos do PDF de uma faixa do texto: [(página, trecho em `page.string`)].
    func ranges(for r: NSRange) -> [(page: Int, range: NSRange)] {
        guard r.length > 0 else { return [] }
        var per: [Int: (Int, Int)] = [:]
        for s in segments {
            let a = max(r.location, s.start), b = min(NSMaxRange(r), s.start + s.length)
            guard a < b else { continue }
            for off in (a - s.start)..<(b - s.start) where off < s.map.count {
                let c = s.map[off]
                guard c >= 0 else { continue }
                if let cur = per[s.page] { per[s.page] = (min(cur.0, c), max(cur.1, c)) } else { per[s.page] = (c, c) }
            }
        }
        return per.keys.sorted().map { p in (p, NSRange(location: per[p]!.0, length: per[p]!.1 - per[p]!.0 + 1)) }
    }

    func selectionRanges() -> [(page: Int, range: NSRange)] {
        guard let tv = textView else { return [] }
        return ranges(for: tv.selectedRange)
    }

    private func textPositions(_ page: Int, _ idx: [Int]) -> [Int] {
        guard let map = positions[page] else { return [] }
        return idx.compactMap { map[$0] }
    }

    /// Mostra os destaques do PDF como fundo colorido no texto.
    func applyMarks() {
        guard let tv = textView, let pdf else { return }
        let storage = tv.textStorage
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: full)
        for p in 0..<pdf.pageCount {
            guard let page = pdf.page(at: p), positions[p] != nil else { continue }
            for a in page.annotations where Highlights.isHighlight(a) {
                let color = (a.color).withAlphaComponent(0.45)
                for run in Highlights.runs(textPositions(p, Highlights.indices(of: a, on: page)))
                where NSMaxRange(run) <= storage.length {
                    storage.addAttribute(.backgroundColor, value: color, range: run)
                }
            }
        }
        storage.endEditing()
    }

    private func mark(atText index: Int) -> PDFAnnotation? {
        guard let pdf, let s = segments.first(where: { $0.start <= index && index < $0.start + $0.length }) else { return nil }
        let off = index - s.start
        guard off < s.map.count, s.map[off] >= 0, let page = pdf.page(at: s.page) else { return nil }
        let c = s.map[off]
        return page.annotations.last { Highlights.isHighlight($0) && Highlights.indices(of: $0, on: page).contains(c) }
    }

    // MARK: Seleção

    func textViewDidChangeSelection(_ textView: UITextView) {
        let r = textView.selectedRange
        hasSelection = r.length > 0 && !marking
        hasMarksInSelection = hasSelection && pdf.map { Highlights.hasMarks(selectionRanges(), in: $0) } == true
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCurrentPage()
    }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                  suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.length > 0 else { return nil }
        var mine: [UIMenuElement] = []
        let colors = HighlightColor.allCases.map { c in
            UIAction(title: c.label, image: UIImage(systemName: "circle.fill")?.withTintColor(c.uiColor, renderingMode: .alwaysOriginal)) { [weak self] _ in
                self?.highlightSelection(c)
            }
        }
        mine.append(UIMenu(title: "Destacar", image: UIImage(systemName: "highlighter"), children: colors))
        if hasMarksInSelection {
            mine.append(UIAction(title: "Desfazer destaque", image: UIImage(systemName: "eraser")) { [weak self] _ in
                self?.unmarkSelection()
            })
        }
        mine.append(UIAction(title: "Adicionar ao resumo", image: UIImage(systemName: "text.badge.plus")) { [weak self] _ in
            self?.onSummary?()
        })
        return UIMenu(children: mine + suggestedActions)
    }

    func copySelection() -> Bool {
        guard let tv = textView, tv.selectedRange.length > 0 else { return false }
        UIPasteboard.general.string = (tv.text as NSString).substring(with: tv.selectedRange)
        return true
    }

    /// A seleção como trecho para o resumo: páginas e texto corrido.
    func excerpt() -> (pages: [Int], text: String)? {
        guard let tv = textView, tv.selectedRange.length > 0 else { return nil }
        let text = Summary.clean((tv.text as NSString).substring(with: tv.selectedRange))
        let pages = selectionRanges().map { $0.page + 1 }
        guard !text.isEmpty, !pages.isEmpty else { return nil }
        return (pages.sorted(), text)
    }

    func clearSelection() {
        guard let tv = textView else { return }
        tv.selectedRange = NSRange(location: tv.selectedRange.location, length: 0)
        textViewDidChangeSelection(tv)
    }

    // MARK: Destaques

    private func highlight(_ ranges: [(page: Int, range: NSRange)], color c: HighlightColor) {
        guard let pdf else { return }
        var added: [(Int, PDFAnnotation)] = []
        for (p, r) in ranges {
            guard let page = pdf.page(at: p), let sel = page.selection(for: r) else { continue }
            for a in Highlights.add(sel, color: c, in: pdf) { added.append((p, a)) }
        }
        guard !added.isEmpty else { return }
        onEdit?("Destaque", .marks(docID: docID, removed: [], added: added))
        applyMarks()
    }

    func highlightSelection(_ c: HighlightColor) {
        highlight(selectionRanges(), color: c)
        clearSelection()
    }

    func unmarkSelection() {
        guard let pdf else { return }
        let change = Highlights.unmark(selectionRanges(), in: pdf)
        guard !change.removed.isEmpty else { return }
        onEdit?("Desfazer destaque", .marks(docID: docID, removed: change.removed, added: change.added))
        applyMarks()
        clearSelection()
    }

    func removeMark(_ a: PDFAnnotation) {
        guard let pdf, let page = a.page else { return }
        let p = pdf.index(for: page)
        Highlights.remove(a)
        onEdit?("Apagar destaque", .marks(docID: docID, removed: [(p, a)], added: []))
        applyMarks()
    }

    func recolorMark(_ a: PDFAnnotation, _ c: HighlightColor) {
        guard let pdf, let page = a.page else { return }
        let from = a.color
        Highlights.recolor(a, c)
        onEdit?("Cor do destaque", .recolor(docID: docID, page: pdf.index(for: page), mark: a, from: from, to: c.uiColor))
        applyMarks()
    }

    // MARK: Marca-texto (um dedo destaca, dois dedos rolam)

    func attach(_ tv: UITextView) {
        textView = tv
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleMark(_:)))
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = marking
        pan.delegate = self
        tv.addGestureRecognizer(pan)
        markPan = pan
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        tv.addGestureRecognizer(tap)
    }

    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g is UITapGestureRecognizer
    }

    func setMarking(_ on: Bool) {
        marking = on
        markPan?.isEnabled = on
        textView?.panGestureRecognizer.minimumNumberOfTouches = on ? 2 : 1
        if on { clearSelection() }
        if let tv = textView { textViewDidChangeSelection(tv) }
    }

    private func index(at g: UIGestureRecognizer) -> Int? {
        guard let tv = textView else { return nil }
        var p = g.location(in: tv)
        p.x -= tv.textContainerInset.left
        p.y -= tv.textContainerInset.top
        let i = tv.layoutManager.characterIndex(for: p, in: tv.textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        return i < tv.textStorage.length ? i : nil
    }

    @objc private func handleMark(_ g: UIPanGestureRecognizer) {
        guard let tv = textView else { return }
        switch g.state {
        case .began:
            markStart = index(at: g)
        case .changed:
            guard let a = markStart, let b = index(at: g) else { return }
            let r = NSRange(location: min(a, b), length: abs(b - a) + 1)
            applyMarks()
            tv.textStorage.addAttribute(.backgroundColor, value: color().uiColor.withAlphaComponent(0.55), range: r)
        case .ended:
            if let a = markStart, let b = index(at: g) {
                let r = NSRange(location: min(a, b), length: abs(b - a) + 1)
                highlight(ranges(for: r), color: color())
            }
            markStart = nil
            applyMarks()
        default:
            markStart = nil
            applyMarks()
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, let tv = textView, tv.selectedRange.length == 0, !marking,
              let i = index(at: g), let a = mark(atText: i) else { return }
        tappedMark = a
    }
}

struct ReaderTextView: UIViewRepresentable {
    @ObservedObject var model: TextReaderModel

    func makeUIView(context: Context) -> UITextView {
        // TextKit 1: permite medir onde começa cada página para manter a posição.
        let tv = UITextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isFindInteractionEnabled = true
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 22, bottom: 90, right: 22)
        tv.dataDetectorTypes = []
        tv.delegate = model
        model.attach(tv)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        tv.backgroundColor = model.theme.background
        tv.indicatorStyle = model.theme == .dark ? .white : .black
        guard context.coordinator.renderedRevision != model.revision else { return }
        let page = model.currentPage
        context.coordinator.renderedRevision = model.revision
        tv.attributedText = model.attributedText()
        tv.tintColor = .systemBlue
        model.applyMarks()
        // Mantém a mesma página depois de mudar a letra ou o fundo.
        Task { @MainActor in model.scrollTo(page: page) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderedRevision = -1
    }
}

/// Conteúdo do modo leitor, com mensagens de carregamento.
struct TextReaderPane: View {
    @ObservedObject var model: TextReaderModel

    var body: some View {
        ZStack {
            Color(model.theme.background).ignoresSafeArea()
            if model.loading {
                ProgressView("Preparando o texto…")
            } else if let doc = model.document, doc.isEmpty {
                EmptyStateView(systemImage: "doc.text.magnifyingglass", title: "Sem texto",
                               message: "Este PDF não tem texto reconhecido. Faça o OCR para usar o modo leitor.")
            } else {
                ReaderTextView(model: model)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
    }
}

/// Miniaturas das páginas à esquerda do modo leitor (tocar leva à página no texto).
struct TextThumbnails: View {
    let url: URL
    let version: String
    let count: Int
    let current: Int
    let onPick: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(1...max(1, count), id: \.self) { n in
                        Button { onPick(n) } label: {
                            VStack(spacing: 3) {
                                ThumbImage(url: url, version: version, page: n - 1)
                                    .frame(width: 64, height: 86)
                                    .overlay(RoundedRectangle(cornerRadius: 2)
                                        .stroke(n == current ? Theme.blue : Color.black.opacity(0.15),
                                                lineWidth: n == current ? 2.5 : 0.8))
                                Text("\(n)").font(.system(size: 11, weight: n == current ? .bold : .medium))
                                    .foregroundStyle(n == current ? Theme.blue : Theme.secondaryText)
                            }
                        }
                        .buttonStyle(.plain)
                        .id(n)
                    }
                }
                .padding(.vertical, 8)
                .padding(.bottom, 60)
            }
            .onChange(of: current) { _, n in withAnimation { proxy.scrollTo(n, anchor: .center) } }
        }
        .frame(width: 92)
        .background(Color(Theme.tileUI))
    }
}

private struct ThumbImage: View {
    let url: URL
    let version: String
    let page: Int
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let image { Image(uiImage: image).resizable().scaledToFit() }
        }
        .task(id: "\(version)-\(page)") {
            image = await ThumbnailCache.shared.image(url: url, version: version, page: page, pixelWidth: 200)
        }
    }
}

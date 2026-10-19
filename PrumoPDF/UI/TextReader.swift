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

/// Estado do modo leitor: texto montado, preferências de leitura e página visível.
@MainActor
final class TextReaderModel: ObservableObject {
    @Published private(set) var document: ReaderDocument?
    @Published private(set) var loading = false
    @Published private(set) var revision = 0
    @Published var currentPage = 1

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
    private(set) var pageStarts: [Int] = []   // posição (em caracteres) do início de cada página
    var reviewPages: Set<Int> = []
    private var loadedURL: URL?

    init() {
        let size = UserDefaults.standard.double(forKey: "readerFontSize")
        fontSize = size > 0 ? CGFloat(size) : 19
        serif = UserDefaults.standard.object(forKey: "readerSerif") as? Bool ?? true
        theme = ReaderTheme(rawValue: UserDefaults.standard.string(forKey: "readerTheme") ?? "") ?? .white
    }

    var pageCount: Int { document?.pages.count ?? 0 }

    func load(url: URL, reviewPages: [Int]) async {
        guard loadedURL != url else { return }
        loadedURL = url
        self.reviewPages = Set(reviewPages)
        loading = true
        let doc = await Task.detached(priority: .userInitiated) { ReaderTextBuilder.build(url: url) }.value
        document = doc
        loading = false
        revision += 1
    }

    func biggerFont() { fontSize = min(fontSize + 2, 34) }
    func smallerFont() { fontSize = max(fontSize - 2, 13) }

    /// Monta o texto formatado e guarda onde começa cada página.
    func attributedText() -> NSAttributedString {
        guard let document else { return NSAttributedString() }
        let out = NSMutableAttributedString()
        var starts: [Int] = []

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
                for paragraph in page.paragraphs {
                    out.append(NSAttributedString(string: paragraph + "\n", attributes: bodyAttrs))
                }
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
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 22, bottom: 60, right: 22)
        tv.dataDetectorTypes = []
        tv.delegate = context.coordinator
        model.textView = tv
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
        // Mantém a mesma página depois de mudar a letra ou o fundo.
        Task { @MainActor in model.scrollTo(page: page) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let model: TextReaderModel
        var renderedRevision = -1
        init(model: TextReaderModel) { self.model = model }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            Task { @MainActor in self.model.updateCurrentPage() }
        }
    }
}

/// Conteúdo do modo leitor, com barra de página e mensagens de carregamento.
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

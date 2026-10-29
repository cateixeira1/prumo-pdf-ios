import PDFKit
import SwiftUI

/// A quais páginas aplicar (cortar, girar).
enum PageScope: String, CaseIterable, Identifiable {
    case this = "Esta"
    case all = "Todas"
    case odd = "Ímpares"
    case even = "Pares"
    case custom = "Escolher"
    var id: String { rawValue }

    func pages(current: Int, total: Int, text: String) throws -> [Int] {
        switch self {
        case .this: return [current]
        case .all: return Array(1...max(1, total))
        case .odd: return Array(stride(from: 1, through: total, by: 2))
        case .even: return Array(stride(from: 2, through: total, by: 2))
        case .custom: return try PageSelection.parse(text, pageCount: total)
        }
    }
}

// MARK: - Cortar e girar

/// Cortar margens (arrastando a moldura ou em milímetros) e girar páginas. O corte vira o CropBox,
/// o recorte padrão do PDF: nada é apagado, e "Página inteira" mostra tudo de novo.
struct CropSheet: View {
    let item: PDFItem
    var startPage = 1
    var onDone: () -> Void = {}
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @Environment(\.dismiss) private var dismiss
    @State private var doc: PDFDocument?
    @State private var page = 1
    @State private var image: UIImage?
    @State private var rotation = 0          // giro a aplicar (sentido horário)
    @State private var margins = PageMargins.zero
    @State private var touched = false
    @State private var scope: PageScope = .this
    @State private var customText = ""
    @State private var working = false
    @State private var dragStart: PageMargins?

    private var total: Int { doc?.pageCount ?? 0 }

    /// Tamanho da página inteira como vai aparecer (com o giro atual e o pendente).
    private var displaySize: CGSize {
        guard let p = doc?.page(at: page - 1) else { return CGSize(width: 595, height: 842) }
        return PageTools.displaySize(media: p.bounds(for: .mediaBox), rotation: p.rotation + rotation)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    preview
                        .frame(height: 360)
                    HStack {
                        Button { go(-1) } label: { Image(systemName: "chevron.left") }.disabled(page <= 1)
                        Spacer()
                        Text(total > 0 ? "Página \(page) de \(total)" : "Carregando…")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button { go(1) } label: { Image(systemName: "chevron.right") }.disabled(page >= total)
                    }
                    .padding(.horizontal, 4)
                    TileCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Margens").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                            Text("Arraste as bordas da moldura azul ou ajuste em milímetros.")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
                            marginStepper("Esquerda", \.left)
                            marginStepper("Alto", \.top)
                            marginStepper("Direita", \.right)
                            marginStepper("Baixo", \.bottom)
                            HStack(spacing: 10) {
                                Button("Margens automáticas") { autoMargins() }.buttonStyle(.bordered)
                                Button("Página inteira") { setMargins(.zero) }.buttonStyle(.bordered)
                            }
                            .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    TileCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Girar").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                            HStack(spacing: 10) {
                                Button { rotate(-90) } label: { Label("90°", systemImage: "rotate.left") }
                                Button { rotate(90) } label: { Label("90°", systemImage: "rotate.right") }
                                Button { rotate(180) } label: { Text("180°") }
                            }
                            .buttonStyle(.bordered)
                            Text(rotation == 0 ? "Sem giro a aplicar." : "Giro a aplicar: \(rotation)°")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    TileCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Aplicar a").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                            Picker("Aplicar a", selection: $scope) {
                                ForEach(PageScope.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            if scope == .custom {
                                TextField("Ex.: 1, 3-5, 10-fim", text: $customText)
                                    .keyboardType(.numbersAndPunctuation)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Text(scopeText).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.teal)
                        }
                    }
                    PrimaryButton(title: working ? "Salvando…" : "Aplicar", color: Theme.indigo,
                                  enabled: !working && total > 0 && (touched || rotation != 0)) { apply() }
                    Text("O corte não apaga nada do PDF: “Página inteira” mostra tudo de novo. Também dá para usar “Desfazer última alteração”.")
                        .font(.footnote).foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal, Theme.margin)
                .padding(.vertical, 8)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Cortar e girar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
        .interactiveDismissDisabled(working)
        .task { await load() }
    }

    private var scopeText: String {
        guard total > 0 else { return "" }
        switch Result(catching: { try scope.pages(current: page, total: total, text: customText) }) {
        case .success(let pages): return pages.count == 1 ? "1 página" : "\(pages.count) páginas"
        case .failure(let e): return e.localizedDescription
        }
    }

    private func marginStepper(_ title: String, _ key: WritableKeyPath<PageMargins, CGFloat>) -> some View {
        Stepper(value: Binding(get: { Double((margins[keyPath: key] / PageTools.mm).rounded()) },
                               set: { v in
                                   var m = margins
                                   m[keyPath: key] = CGFloat(max(0, v)) * PageTools.mm
                                   setMargins(m)
                               }),
                in: 0...300, step: 1) {
            Text("\(title): \(Int((margins[keyPath: key] / PageTools.mm).rounded())) mm")
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
        }
    }

    // MARK: Prévia com a moldura

    private var preview: some View {
        GeometryReader { geo in
            let size = displaySize
            let s = min((geo.size.width - 20) / size.width, (geo.size.height - 20) / size.height)
            let pr = CGRect(x: (geo.size.width - size.width * s) / 2, y: (geo.size.height - size.height * s) / 2,
                            width: size.width * s, height: size.height * s)
            let f = CGRect(x: pr.minX + margins.left * s, y: pr.minY + margins.top * s,
                           width: pr.width - (margins.left + margins.right) * s,
                           height: pr.height - (margins.top + margins.bottom) * s)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.white)
                    .frame(width: pr.width, height: pr.height)
                    .offset(x: pr.minX, y: pr.minY)
                if let image {
                    Image(uiImage: image).resizable()
                        .frame(width: pr.width, height: pr.height)
                        .offset(x: pr.minX, y: pr.minY)
                }
                Path { p in
                    p.addRect(pr)
                    p.addRect(f)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                Rectangle().stroke(Theme.blue, lineWidth: 2)
                    .frame(width: max(1, f.width), height: max(1, f.height))
                    .offset(x: f.minX, y: f.minY)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(scale: s, edges: [.leading, .trailing, .top, .bottom], move: true))
                ForEach(Handle.allCases) { h in
                    Circle().fill(Color.white)
                        .overlay(Circle().stroke(Theme.blue, lineWidth: 2))
                        .frame(width: 22, height: 22)
                        .position(h.point(in: f))
                        .gesture(dragGesture(scale: s, edges: h.edges, move: false))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(RoundedRectangle(cornerRadius: Theme.tileRadius).fill(Theme.tile))
    }

    private enum Handle: String, CaseIterable, Identifiable {
        case tl, t, tr, r, br, b, bl, l
        var id: String { rawValue }
        var edges: Set<Edge> {
            switch self {
            case .tl: return [.top, .leading]
            case .t: return [.top]
            case .tr: return [.top, .trailing]
            case .r: return [.trailing]
            case .br: return [.bottom, .trailing]
            case .b: return [.bottom]
            case .bl: return [.bottom, .leading]
            case .l: return [.leading]
            }
        }
        func point(in f: CGRect) -> CGPoint {
            switch self {
            case .tl: return CGPoint(x: f.minX, y: f.minY)
            case .t: return CGPoint(x: f.midX, y: f.minY)
            case .tr: return CGPoint(x: f.maxX, y: f.minY)
            case .r: return CGPoint(x: f.maxX, y: f.midY)
            case .br: return CGPoint(x: f.maxX, y: f.maxY)
            case .b: return CGPoint(x: f.midX, y: f.maxY)
            case .bl: return CGPoint(x: f.minX, y: f.maxY)
            case .l: return CGPoint(x: f.minX, y: f.midY)
            }
        }
    }

    private func dragGesture(scale s: CGFloat, edges: Set<Edge>, move: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                let start = dragStart ?? margins
                if dragStart == nil { dragStart = margins }
                let dx = v.translation.width / s, dy = v.translation.height / s
                var m = start
                let size = displaySize
                let minSide: CGFloat = 36
                if move {
                    let mx = max(-start.left, min(start.right, dx))
                    let my = max(-start.top, min(start.bottom, dy))
                    m.left = start.left + mx; m.right = start.right - mx
                    m.top = start.top + my; m.bottom = start.bottom - my
                } else {
                    if edges.contains(.leading) { m.left = max(0, min(size.width - start.right - minSide, start.left + dx)) }
                    if edges.contains(.trailing) { m.right = max(0, min(size.width - start.left - minSide, start.right - dx)) }
                    if edges.contains(.top) { m.top = max(0, min(size.height - start.bottom - minSide, start.top + dy)) }
                    if edges.contains(.bottom) { m.bottom = max(0, min(size.height - start.top - minSide, start.bottom - dy)) }
                }
                margins = m
                touched = true
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: Ações

    private func load() async {
        let url = item.url
        let d = await Task.detached(priority: .userInitiated) { try? PDFOps.open(url) }.value
        guard let d else {
            flow.toast("Não foi possível abrir o PDF.")
            dismiss()
            return
        }
        doc = d
        page = max(1, min(startPage, d.pageCount))
        if let p = d.page(at: page - 1) {
            margins = PageTools.margins(media: p.bounds(for: .mediaBox), rotation: p.rotation, box: p.bounds(for: .cropBox))
        }
        renderPreview()
    }

    private func renderPreview() {
        guard let p = doc?.page(at: page - 1) else { return }
        let media = p.bounds(for: .mediaBox)
        let current = PageTools.displaySize(media: media, rotation: p.rotation)
        let target = CGSize(width: 700, height: 700 * current.height / max(1, current.width))
        var img = p.thumbnail(of: target, for: .mediaBox)
        // Se o sistema não aplicou o giro da página na miniatura, aplica aqui.
        let r = PDFOps.normalized(p.rotation)
        if (r == 90 || r == 270) && (img.size.width > img.size.height) != (current.width > current.height) {
            img = img.rotatedBy(degrees: r)
        }
        if rotation != 0 { img = img.rotatedBy(degrees: rotation) }
        image = img
    }

    private func go(_ d: Int) {
        page = max(1, min(total, page + d))
        renderPreview()
    }

    private func setMargins(_ m: PageMargins) {
        let size = displaySize
        var c = m
        c.left = min(max(0, c.left), size.width - 36)
        c.right = min(max(0, c.right), max(0, size.width - 36 - c.left))
        c.top = min(max(0, c.top), size.height - 36)
        c.bottom = min(max(0, c.bottom), max(0, size.height - 36 - c.top))
        margins = c
        touched = true
    }

    private func rotate(_ delta: Int) {
        margins = PageTools.rotate(margins, by: delta)
        rotation = PDFOps.normalized(rotation + delta)
        renderPreview()
    }

    private func autoMargins() {
        guard let image, let m = PageTools.contentMargins(of: image, pointWidth: displaySize.width) else {
            flow.toast("Não foi possível achar o conteúdo da página.")
            return
        }
        setMargins(m)
    }

    private func apply() {
        guard total > 0 else { return }
        let pages: [Int]
        do { pages = try scope.pages(current: page, total: total, text: customText) } catch {
            flow.show(error: error)
            return
        }
        let m: PageMargins? = touched ? margins : nil
        let r = rotation
        working = true
        Task {
            do {
                var count = 0
                try await library.modify(item, keepReview: true) { doc in
                    count = try PageTools.cropAndRotate(doc, pages: pages, margins: m, rotateBy: r)
                }
                working = false
                onDone()
                dismiss()
                let n = count
                flow.toast("\(n == 1 ? "1 página alterada" : "\(n) páginas alteradas"). Use “Desfazer última alteração” se precisar.")
            } catch {
                working = false
                flow.show(error: error)
            }
        }
    }
}

// MARK: - Numerar

struct NumberSheet: View {
    let item: PDFItem
    var onDone: () -> Void = {}
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @Environment(\.dismiss) private var dismiss
    @State private var format: PageTools.NumberFormat = .n
    @State private var position: PageTools.NumberPosition = .bottomCenter
    @State private var start = 1
    @State private var firstPage = 1
    @State private var size = 10
    @State private var marginMM = 10
    @State private var working = false

    private var total: Int { max(1, item.pageCount ?? 1) }
    private var last: Int { start + (total - firstPage) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        numberPreview
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Onde e como") {
                    Picker("Posição", selection: $position) {
                        ForEach(PageTools.NumberPosition.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Formato", selection: $format) {
                        ForEach(PageTools.NumberFormat.allCases) { Text($0.label).tag($0) }
                    }
                    Stepper("Tamanho da letra: \(size) pt", value: $size, in: 6...28)
                    Stepper("Distância da borda: \(marginMM) mm", value: $marginMM, in: 3...60)
                }
                Section {
                    Stepper("Primeiro número: \(start)", value: $start, in: 0...99999)
                    Stepper("Começar na página \(firstPage)", value: $firstPage, in: 1...total)
                } footer: {
                    Text("\(total - firstPage + 1) página\(total - firstPage + 1 == 1 ? "" : "s"): de “\(format.text(start, total: last))” até “\(format.text(last, total: last))”. O número fica gravado como texto na página; para tirar, use “Desfazer última alteração”.")
                }
                Section {
                    PrimaryButton(title: working ? "Numerando…" : "Numerar", color: Theme.indigo, enabled: !working) { apply() }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Numerar páginas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
        .interactiveDismissDisabled(working)
    }

    private var numberPreview: some View {
        let w: CGFloat = 130, h: CGFloat = 184
        let s = w / 595
        let m = CGFloat(marginMM) * PageTools.mm * s
        return ZStack(alignment: position.isTop ? .top : .bottom) {
            Rectangle().fill(Color.white)
                .overlay(Rectangle().stroke(Color.black.opacity(0.15), lineWidth: 1))
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<8, id: \.self) { k in
                    Capsule().fill(Color.gray.opacity(0.3)).frame(height: 3)
                        .padding(.trailing, k % 3 == 2 ? 26 : 0)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            Text(format.text(start, total: last))
                // fora de escala: no tamanho real, o número seria um ponto quase invisível na prévia
                .font(.system(size: max(11, CGFloat(size) * s * 2.5), weight: .semibold))
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity, alignment: position.horizontal < 0 ? .leading : (position.horizontal > 0 ? .trailing : .center))
                .padding(.horizontal, m)
                .padding(position.isTop ? .top : .bottom, max(2, m - 4))
        }
        .frame(width: w, height: h)
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }

    private func apply() {
        let options = PageTools.NumberOptions(format: format, position: position, start: start, firstPage: firstPage,
                                              size: CGFloat(size), margin: CGFloat(marginMM) * PageTools.mm)
        let url = item.url
        working = true
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try PageTools.numberedData(try PDFOps.open(url), options: options)
                }.value
                try await library.replaceContents(item, with: data, keepReview: true)
                working = false
                onDone()
                dismiss()
                let n = total - firstPage + 1
                flow.toast("\(n == 1 ? "1 página numerada" : "\(n) páginas numeradas"). Use “Desfazer última alteração” se precisar.")
            } catch {
                working = false
                flow.show(error: error)
            }
        }
    }
}

import PDFKit
import SwiftUI
import UIKit

/// Estado da tela de organização (ordem, giros, seleção e tamanho das miniaturas).
@MainActor
final class OrganizerModel: ObservableObject {
    @Published var entries: [PageArrangementEntry] = []
    @Published var selecting = false
    @Published var selected = Set<UUID>()
    @Published var columns = 3
    /// Página aberta em tela cheia (toque numa página fora do modo de seleção).
    @Published var preview: PagePreviewRequest?
    /// Muda quando a grade precisa ser recarregada por inteiro (girar, excluir, carregar).
    @Published private(set) var structureRevision = 0
    private(set) var originalCount = 0
    private(set) var loaded = false

    var hasChanges: Bool {
        guard loaded else { return false }
        if entries.count != originalCount { return true }
        for (i, e) in entries.enumerated() where e.sourceIndex != i || PDFOps.normalized(e.extraRotation) != 0 {
            return true
        }
        return false
    }

    func load(pageCount: Int) {
        guard !loaded else { return }
        entries = (0..<pageCount).map { PageArrangementEntry(sourceIndex: $0) }
        originalCount = pageCount
        loaded = true
        structureRevision += 1
    }

    /// Chamado pela grade depois de arrastar (a grade já está atualizada).
    func move(from: Int, to: Int) {
        guard from != to, entries.indices.contains(from) else { return }
        let e = entries.remove(at: from)
        entries.insert(e, at: min(to, entries.count))
    }

    func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func rotateSelected(by degrees: Int) {
        for i in entries.indices where selected.contains(entries[i].id) {
            entries[i].extraRotation = PDFOps.normalized(entries[i].extraRotation + degrees)
        }
        structureRevision += 1
    }

    /// Exclui as selecionadas. Sempre deixa ao menos uma página.
    @discardableResult
    func deleteSelected() -> Bool {
        guard !selected.isEmpty, selected.count < entries.count else { return false }
        entries.removeAll { selected.contains($0.id) }
        selected.removeAll()
        structureRevision += 1
        return true
    }

    func reset() {
        entries = (0..<originalCount).map { PageArrangementEntry(sourceIndex: $0) }
        selected.removeAll()
        structureRevision += 1
    }
}

struct PagePreviewRequest: Identifiable {
    let id = UUID()
    let index: Int
}

struct PageOrganizerScreen: View {
    let itemID: String
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = OrganizerModel()
    @AppStorage("organizerHintHidden") private var hintHidden = false
    @State private var saving = false
    @State private var confirmDiscard = false
    @State private var confirmDelete = false

    private var item: PDFItem? { library.item(id: itemID) }

    var body: some View {
        VStack(spacing: 0) {
            if !hintHidden {
                hint
            }
            if let item {
                PageGridRepresentable(model: model, url: item.url, version: item.version)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(model.entries.isEmpty ? "Organizar páginas" : "Organizar \(model.entries.count) páginas")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.hasChanges || saving)
        .toolbar {
            if model.hasChanges {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { confirmDiscard = true }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Salvar") { save() }.fontWeight(.semibold)
                    }
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                bottomBarContent
            }
        }
        .toolbarBackground(Theme.background, for: .bottomBar)
        .toolbarBackground(.visible, for: .bottomBar)
        .task {
            if let item {
                let url = item.url
                let count = await Task.detached { PDFDocument(url: url)?.pageCount ?? 0 }.value
                model.load(pageCount: count)
            }
        }
        .fullScreenCover(item: $model.preview) { request in
            if let item {
                OrganizerPagePreview(url: item.url, entries: model.entries, start: request.index)
            }
        }
        .confirmationDialog("Descartar as alterações?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Descartar", role: .destructive) {
                model.reset()
                dismiss()
            }
            Button("Continuar editando", role: .cancel) {}
        }
        .confirmationDialog("Excluir \(model.selected.count == 1 ? "1 página" : "\(model.selected.count) páginas")?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Excluir", role: .destructive) {
                if !model.deleteSelected() {
                    flow.toast("O documento precisa ter pelo menos uma página.")
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("A exclusão só vale depois de tocar em Salvar.")
        }
    }

    private var hint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.point.up.left.fill")
                .foregroundStyle(Theme.purple)
                .font(.system(size: 18))
            Text("Toque numa página para vê-la grande. Para mudar a ordem, segure a página até ela levantar e arraste; perto da borda de cima ou de baixo, a tela rola sozinha. Use a pinça para mudar o tamanho das páginas.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { withAnimation { hintHidden = true } } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.secondaryText)
            }
            .accessibilityLabel("Fechar dica")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).fill(Theme.tile))
        .padding(.horizontal, Theme.margin)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var bottomBarContent: some View {
        if model.selecting {
            Button {
                model.selecting = false
                model.selected.removeAll()
            } label: { Text("OK").fontWeight(.semibold) }
            Spacer()
            Button { model.rotateSelected(by: -90) } label: { Image(systemName: "rotate.left") }
                .disabled(model.selected.isEmpty)
                .accessibilityLabel("Girar para a esquerda")
            Button { model.rotateSelected(by: 90) } label: { Image(systemName: "rotate.right") }
                .disabled(model.selected.isEmpty)
                .accessibilityLabel("Girar para a direita")
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .disabled(model.selected.isEmpty)
                .accessibilityLabel("Excluir páginas selecionadas")
        } else {
            Button("Selecionar") { model.selecting = true }
            Spacer()
            Menu {
                Picker("Páginas por linha", selection: $model.columns) {
                    Text("1 por linha").tag(1)
                    Text("2 por linha").tag(2)
                    Text("3 por linha").tag(3)
                    Text("4 por linha").tag(4)
                }
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .accessibilityLabel("Tamanho das páginas")
        }
    }

    private func save() {
        guard let item else { return }
        let arrangement = model.entries
        saving = true
        Task {
            do {
                try await library.modify(item) { doc in
                    try PDFOps.apply(arrangement: arrangement, to: doc)
                }
                saving = false
                model.reset()
                dismiss()
                flow.toast("Páginas reorganizadas e salvas.")
            } catch {
                saving = false
                flow.show(error: error)
            }
        }
    }
}

// MARK: - Grade em UIKit (arrastar e soltar com rolagem automática)

struct PageGridRepresentable: UIViewControllerRepresentable {
    @ObservedObject var model: OrganizerModel
    let url: URL
    let version: String

    func makeUIViewController(context: Context) -> PageGridViewController {
        PageGridViewController(model: model, url: url, version: version)
    }

    func updateUIViewController(_ vc: PageGridViewController, context: Context) {
        vc.sync()
    }
}

final class PageGridViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
                                    UICollectionViewDragDelegate, UICollectionViewDropDelegate,
                                    UIGestureRecognizerDelegate {
    let model: OrganizerModel
    let url: URL
    let version: String
    private var collectionView: UICollectionView!
    private var lastRevision = -1
    private var currentColumns = 0
    private var currentSelecting = false
    private var pinchStartColumns = 3
    private var isDropping = false
    // Seleção deslizando o dedo (no modo de seleção), como no app Fotos.
    private var selectPan: UIPanGestureRecognizer!
    private var panStart: Int?
    private var panMode = true
    private var panOriginal: [Int: Bool] = [:]
    private var scrollLink: CADisplayLink?

    init(model: OrganizerModel, url: URL, version: String) {
        self.model = model
        self.url = url
        self.version = version
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.backgroundUI
        currentColumns = model.columns
        let cv = UICollectionView(frame: view.bounds, collectionViewLayout: Self.layout(columns: currentColumns))
        cv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cv.backgroundColor = .clear
        cv.alwaysBounceVertical = true
        cv.register(PageGridCell.self, forCellWithReuseIdentifier: PageGridCell.reuseID)
        cv.dataSource = self
        cv.delegate = self
        cv.dragDelegate = self
        cv.dropDelegate = self
        // No iPhone o arrastar vem desligado por padrão nas grades; aqui é ligado.
        cv.dragInteractionEnabled = true
        cv.reorderingCadence = .immediate
        cv.contentInset = UIEdgeInsets(top: 6, left: 0, bottom: 24, right: 0)
        view.addSubview(cv)
        collectionView = cv

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        cv.addGestureRecognizer(pinch)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSelectPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        cv.addGestureRecognizer(pan)
        // A rolagem espera o arraste decidir: ele só começa na horizontal e no modo de seleção.
        cv.panGestureRecognizer.require(toFail: pan)
        selectPan = pan
        sync()
    }

    static func layout(columns: Int) -> UICollectionViewLayout {
        let c = CGFloat(max(1, min(columns, 4)))
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / c), heightDimension: .fractionalHeight(1.0)))
        let inset: CGFloat = columns == 1 ? 10 : 6
        item.contentInsets = NSDirectionalEdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset)
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                               heightDimension: .fractionalWidth(1.414 / c)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        return UICollectionViewCompositionalLayout(section: section)
    }

    /// Aplica mudanças vindas da parte SwiftUI (giro, exclusão, colunas, modo de seleção).
    func sync() {
        guard let collectionView, !isDropping else { return }
        if model.structureRevision != lastRevision {
            lastRevision = model.structureRevision
            collectionView.reloadData()
        }
        if model.columns != currentColumns {
            currentColumns = model.columns
            collectionView.setCollectionViewLayout(Self.layout(columns: currentColumns), animated: true)
            collectionView.reloadData()
        }
        if model.selecting != currentSelecting {
            currentSelecting = model.selecting
            refreshVisibleCells()
        } else if model.selecting {
            refreshVisibleCells()
        }
    }

    private func refreshVisibleCells() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            if let cell = collectionView.cellForItem(at: indexPath) as? PageGridCell,
               model.entries.indices.contains(indexPath.item) {
                let entry = model.entries[indexPath.item]
                cell.setNumber(indexPath.item + 1)
                cell.setSelectionState(selecting: model.selecting, selected: model.selected.contains(entry.id))
            }
        }
    }

    // MARK: Dados

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        model.entries.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PageGridCell.reuseID, for: indexPath) as! PageGridCell
        let entry = model.entries[indexPath.item]
        cell.representedID = entry.id
        cell.setNumber(indexPath.item + 1)
        cell.setSelectionState(selecting: model.selecting, selected: model.selected.contains(entry.id))
        cell.setImage(nil, rotation: 0)
        let width = (collectionView.bounds.width - 20) / CGFloat(max(1, currentColumns)) * traitCollection.displayScale
        let id = entry.id
        let rotation = entry.extraRotation
        ThumbnailCache.shared.load(url: url, version: version, page: entry.sourceIndex, pixelWidth: width) { [weak cell] image in
            guard let cell, cell.representedID == id else { return }
            cell.setImage(image, rotation: rotation)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard model.entries.indices.contains(indexPath.item) else { return }
        guard model.selecting else {
            // Fora do modo de seleção, tocar abre a página grande.
            model.preview = PagePreviewRequest(index: indexPath.item)
            return
        }
        let entry = model.entries[indexPath.item]
        model.toggle(entry.id)
        UISelectionFeedbackGenerator().selectionChanged()
        if let cell = collectionView.cellForItem(at: indexPath) as? PageGridCell {
            cell.setSelectionState(selecting: true, selected: model.selected.contains(entry.id))
        }
    }

    // MARK: Arrastar

    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        guard model.entries.indices.contains(indexPath.item) else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = model.entries[indexPath.item].id
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        return [item]
    }

    func collectionView(_ collectionView: UICollectionView,
                        dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
        guard let cell = collectionView.cellForItem(at: indexPath) as? PageGridCell else { return nil }
        let params = UIDragPreviewParameters()
        params.visiblePath = UIBezierPath(roundedRect: cell.pageFrame, cornerRadius: 6)
        params.backgroundColor = .clear
        return params
    }

    func collectionView(_ collectionView: UICollectionView,
                        dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool {
        true
    }

    // MARK: Soltar

    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        session.localDragSession != nil
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                        withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        guard collectionView.hasActiveDrag else { return UICollectionViewDropProposal(operation: .forbidden) }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard coordinator.proposal.operation == .move,
              let dropItem = coordinator.items.first,
              let source = dropItem.sourceIndexPath else { return }
        let lastIndex = max(0, model.entries.count - 1)
        let destinationItem = min(coordinator.destinationIndexPath?.item ?? lastIndex, lastIndex)
        let destination = IndexPath(item: destinationItem, section: 0)
        isDropping = true
        collectionView.performBatchUpdates({
            model.move(from: source.item, to: destination.item)
            collectionView.deleteItems(at: [source])
            collectionView.insertItems(at: [destination])
        }, completion: { [weak self] _ in
            self?.isDropping = false
            self?.refreshVisibleCells()
        })
        coordinator.drop(dropItem.dragItem, toItemAt: destination)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: Selecionar deslizando o dedo

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === selectPan else { return true }
        guard model.selecting, let cv = collectionView else { return false }
        let v = selectPan.velocity(in: cv)
        guard abs(v.x) > abs(v.y) else { return false }
        let p = selectPan.location(in: cv)
        let t = selectPan.translation(in: cv)
        return cv.indexPathForItem(at: CGPoint(x: p.x - t.x, y: p.y - t.y)) != nil
    }

    @objc private func handleSelectPan(_ g: UIPanGestureRecognizer) {
        guard let cv = collectionView else { return }
        let p = g.location(in: cv)
        switch g.state {
        case .began:
            let t = g.translation(in: cv)
            guard let ip = cv.indexPathForItem(at: CGPoint(x: p.x - t.x, y: p.y - t.y)),
                  model.entries.indices.contains(ip.item) else { return }
            panStart = ip.item
            panMode = !model.selected.contains(model.entries[ip.item].id)
            panOriginal = [:]
            applyPan(to: ip.item)
            if let cur = cv.indexPathForItem(at: p) { applyPan(to: cur.item) }
            UISelectionFeedbackGenerator().selectionChanged()
            startAutoScroll()
        case .changed:
            if let ip = cv.indexPathForItem(at: p) { applyPan(to: ip.item) }
        default:
            panStart = nil
            panOriginal = [:]
            stopAutoScroll()
        }
    }

    private func applyPan(to current: Int) {
        guard let s = panStart else { return }
        let range = min(s, current)...max(s, current)
        for (k, was) in panOriginal where !range.contains(k) {
            setSelected(k, was)
            panOriginal[k] = nil
        }
        for k in range where model.entries.indices.contains(k) {
            if panOriginal[k] == nil { panOriginal[k] = model.selected.contains(model.entries[k].id) }
            setSelected(k, panMode)
        }
    }

    private func setSelected(_ k: Int, _ on: Bool) {
        guard model.entries.indices.contains(k) else { return }
        let id = model.entries[k].id
        guard on != model.selected.contains(id) else { return }
        if on { model.selected.insert(id) } else { model.selected.remove(id) }
        if let cell = collectionView.cellForItem(at: IndexPath(item: k, section: 0)) as? PageGridCell {
            cell.setSelectionState(selecting: true, selected: on)
        }
    }

    private func startAutoScroll() {
        stopAutoScroll()
        let link = CADisplayLink(target: self, selector: #selector(autoScrollTick))
        link.add(to: .main, forMode: .common)
        scrollLink = link
    }

    private func stopAutoScroll() {
        scrollLink?.invalidate()
        scrollLink = nil
    }

    @objc private func autoScrollTick() {
        guard let cv = collectionView, panStart != nil else { return }
        let y = selectPan.location(in: cv).y - cv.bounds.minY
        let h = cv.bounds.height
        let edge: CGFloat = 70
        var speed: CGFloat = 0
        if y < edge { speed = -14 * min(1, (edge - y) / edge) }
        if y > h - edge { speed = 14 * min(1, (y - (h - edge)) / edge) }
        guard speed != 0 else { return }
        let minY = -cv.adjustedContentInset.top
        let maxY = max(minY, cv.contentSize.height - h + cv.adjustedContentInset.bottom)
        let newY = min(maxY, max(minY, cv.contentOffset.y + speed))
        guard newY != cv.contentOffset.y else { return }
        cv.contentOffset.y = newY
        if let ip = cv.indexPathForItem(at: selectPan.location(in: cv)) { applyPan(to: ip.item) }
    }

    // MARK: Pinça

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStartColumns = model.columns
        case .changed:
            let steps = Int((log(g.scale) / log(1.45)).rounded(.towardZero))
            let target = max(1, min(4, pinchStartColumns - steps))
            if target != model.columns {
                model.columns = target
                UISelectionFeedbackGenerator().selectionChanged()
            }
        default:
            break
        }
    }
}

final class PageGridCell: UICollectionViewCell {
    static let reuseID = "PageGridCell"
    var representedID: UUID?

    private let pageView = UIView()
    private let imageView = UIImageView()
    private let numberLabel = UILabel()
    private let numberBackground = UIView()
    private let checkView = UIImageView()

    /// Retângulo da página dentro da célula (para a prévia ao arrastar).
    var pageFrame: CGRect { pageView.frame }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear

        pageView.backgroundColor = .white
        pageView.layer.cornerRadius = 6
        pageView.layer.cornerCurve = .continuous
        pageView.layer.shadowColor = UIColor.black.cgColor
        pageView.layer.shadowOpacity = 0.16
        pageView.layer.shadowRadius = 3
        pageView.layer.shadowOffset = CGSize(width: 0, height: 1)
        contentView.addSubview(pageView)

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 6
        pageView.addSubview(imageView)

        numberBackground.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        numberBackground.layer.cornerRadius = 9
        contentView.addSubview(numberBackground)
        numberLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        numberLabel.textColor = .white
        numberLabel.textAlignment = .center
        numberBackground.addSubview(numberLabel)

        checkView.contentMode = .scaleAspectFit
        checkView.isHidden = true
        contentView.addSubview(checkView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    override func layoutSubviews() {
        super.layoutSubviews()
        pageView.frame = contentView.bounds
        imageView.frame = pageView.bounds
        pageView.layer.shadowPath = UIBezierPath(roundedRect: pageView.bounds, cornerRadius: 6).cgPath
        let size = numberLabel.sizeThatFits(CGSize(width: 80, height: 18))
        let w = max(26, size.width + 14)
        numberBackground.frame = CGRect(x: (contentView.bounds.width - w) / 2, y: contentView.bounds.height - 26,
                                        width: w, height: 18)
        numberLabel.frame = numberBackground.bounds
        checkView.frame = CGRect(x: contentView.bounds.width - 30, y: 6, width: 24, height: 24)
    }

    func setNumber(_ n: Int) {
        numberLabel.text = "\(n)"
        setNeedsLayout()
    }

    func setImage(_ image: UIImage?, rotation: Int) {
        guard let image else {
            imageView.image = nil
            return
        }
        imageView.image = rotation == 0 ? image : image.rotatedBy(degrees: rotation)
    }

    func setSelectionState(selecting: Bool, selected: Bool) {
        checkView.isHidden = !selecting
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        checkView.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle", withConfiguration: config)
        checkView.tintColor = selected ? .systemBlue : .systemGray
        checkView.backgroundColor = .white
        checkView.layer.cornerRadius = 12
        pageView.layer.borderWidth = selecting && selected ? 3 : 0
        pageView.layer.borderColor = UIColor.systemBlue.cgColor
        imageView.alpha = selecting && !selected ? 0.85 : 1
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedID = nil
        imageView.image = nil
    }
}

extension UIImage {
    func rotatedBy(degrees: Int) -> UIImage {
        let d = PDFOps.normalized(degrees)
        guard d != 0 else { return self }
        let radians = CGFloat(d) * .pi / 180
        let newSize = (d == 90 || d == 270) ? CGSize(width: size.height, height: size.width) : size
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: newSize, format: format).image { ctx in
            ctx.cgContext.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            ctx.cgContext.rotate(by: radians)
            draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        }
    }
}

// MARK: - Página grande (na ordem e com o giro ainda não salvos)

/// Mostra as páginas do Organizar em tela cheia: deslizar passa para a anterior ou a próxima,
/// a pinça amplia. Monta um documento temporário com a ordem e os giros atuais.
struct OrganizerPagePreview: View {
    let url: URL
    let entries: [PageArrangementEntry]
    let start: Int
    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var current = 0
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.1).ignoresSafeArea()
                if let document {
                    PagedPDFView(document: document, startIndex: start, current: $current)
                        .ignoresSafeArea(edges: .bottom)
                } else if failed {
                    Text("Não foi possível abrir a página.")
                        .foregroundStyle(Color.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .task { await load() }
    }

    private var title: String {
        guard entries.indices.contains(current) else { return "Página" }
        let e = entries[current]
        var t = "Página \(current + 1) de \(entries.count)"
        if e.sourceIndex != current { t += " · era a \(e.sourceIndex + 1)" }
        return t
    }

    private func load() async {
        let entries = entries
        let url = url
        current = start
        let doc = await Task.detached(priority: .userInitiated) { () -> PDFDocument? in
            guard let source = try? PDFOps.open(url) else { return nil }
            let out = PDFDocument()
            for e in entries {
                guard let page = source.page(at: e.sourceIndex)?.copy() as? PDFPage else { continue }
                page.rotation = PDFOps.normalized(page.rotation + e.extraRotation)
                out.insert(page, at: out.pageCount)
            }
            return out.pageCount > 0 ? out : nil
        }.value
        if let doc { document = doc } else { failed = true }
    }
}

/// PDFView de uma página por vez, deslizando para o lado (como as Fotos), com pinça para ampliar.
struct PagedPDFView: UIViewRepresentable {
    let document: PDFDocument
    let startIndex: Int
    @Binding var current: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.backgroundColor = UIColor(white: 0.1, alpha: 1)
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.usePageViewController(true, withViewOptions: nil)
        view.autoScales = true
        view.pageShadowsEnabled = true
        view.document = document
        if let page = document.page(at: max(0, min(startIndex, document.pageCount - 1))) {
            view.go(to: page)
        }
        context.coordinator.view = view
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.changed),
                                               name: .PDFViewPageChanged, object: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(current: $current) }

    final class Coordinator: NSObject {
        var current: Binding<Int>
        weak var view: PDFView?
        init(current: Binding<Int>) { self.current = current }
        @objc func changed() {
            guard let view, let page = view.currentPage, let doc = view.document else { return }
            let index = doc.index(for: page)
            DispatchQueue.main.async { self.current.wrappedValue = index }
        }
    }
}

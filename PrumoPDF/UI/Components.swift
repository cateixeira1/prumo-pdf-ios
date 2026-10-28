import PDFKit
import SwiftUI
import UIKit
import VisionKit

// MARK: - Miniatura de página

struct PageThumbnailView: View {
    let url: URL
    let version: String
    var page: Int = 0
    var width: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .task(id: "\(url.path)|\(version)|\(page)") {
            let pixels = width * displayScale
            if let cached = ThumbnailCache.shared.cached(url: url, version: version, page: page, pixelWidth: pixels) {
                image = cached
            } else {
                image = await ThumbnailCache.shared.image(url: url, version: version, page: page, pixelWidth: pixels)
            }
        }
    }
}

// MARK: - Cartão de documento

struct DocTileLabel: View {
    let item: PDFItem
    var needsOCR = false
    var showFolder = false
    var selection: Bool? = nil   // nil = fora do modo de seleção
    /// Deixa espaço, no canto inferior direito, para a estrela e os três pontos (desenhados por cima).
    var reserveActions = false
    @Environment(\.tileHighlighted) private var highlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                PageThumbnailView(url: item.url, version: item.version, width: 34)
                    .frame(width: 34, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.black.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                Spacer(minLength: 4)
                if let selection {
                    Image(systemName: selection ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(selection ? Theme.blue : Theme.secondaryText)
                } else if let n = item.pageCount {
                    VStack(alignment: .trailing, spacing: -2) {
                        Text("\(n)")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(highlighted ? Color.white : Theme.text)
                        Text(n == 1 ? "página" : "páginas")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(highlighted ? Color.white.opacity(0.9) : Theme.secondaryText)
                    }
                } else {
                    ProgressView().scaleEffect(0.7)
                }
            }
            Spacer(minLength: 8)
            Text(item.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(highlighted ? Color.white : Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 0) {
                badges
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
            .padding(.trailing, reserveActions ? 70 : 0)
            .frame(minHeight: reserveActions ? 26 : 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var badges: some View {
        let review = !(item.meta.reviewPages ?? []).isEmpty
        if (item.meta.favorite && !reserveActions) || item.meta.isOCRResult || needsOCR || review || showFolder {
            HStack(spacing: 4) {
                if item.meta.favorite && !reserveActions {
                    Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(highlighted ? Color.white : Theme.yellow)
                }
                if item.meta.isOCRResult { Badge(text: "OCR", color: Theme.green, inverted: highlighted) }
                if review { Badge(text: "Revisar", color: Theme.orange, inverted: highlighted) }
                if needsOCR { Badge(text: "Sem OCR", color: Theme.orange, inverted: highlighted) }
                if showFolder {
                    Text(item.folderName)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(highlighted ? Color.white.opacity(0.9) : Theme.secondaryText)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var inverted = false
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(inverted ? color : Color.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(inverted ? Color.white : color))
    }
}

/// Cartão de documento com toque (abrir ou selecionar), menu de contexto (toque longo) e,
/// no canto inferior direito, a estrela de favorito e os três pontos que abrem as opções.
struct DocTile: View {
    let item: PDFItem
    var showFolder = false
    var selection: Bool? = nil
    var actions: ItemActions? = nil
    /// Mostra a estrela e os três pontos (fica desligado nas telas de escolher PDF).
    var showActions = true
    let onTap: () -> Void
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @EnvironmentObject private var jobs: JobCenter

    private var actionsVisible: Bool { showActions && selection == nil }

    var body: some View {
        Button(action: onTap) {
            DocTileLabel(item: item, needsOCR: library.needsOCRAttention(item), showFolder: showFolder,
                         selection: selection, reserveActions: actionsVisible)
        }
        .buttonStyle(TileButtonStyle(color: Theme.blue, selected: selection == true))
        .contextMenu {
            if selection == nil { menuItems }
        }
        .overlay(alignment: .bottomTrailing) {
            if actionsVisible {
                HStack(spacing: 0) {
                    Button { toggleFavorite() } label: {
                        Image(systemName: item.meta.favorite ? "star.fill" : "star")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(item.meta.favorite ? Theme.yellow : Theme.secondaryText)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.meta.favorite ? "Remover dos favoritos" : "Favoritar")
                    Menu { menuItems } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .bold))
                            .rotationEffect(.degrees(90))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 34, height: 36)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Opções")
                }
                .padding(.trailing, 4)
                .padding(.bottom, 3)
            }
        }
    }

    private func toggleFavorite() {
        let on = !item.meta.favorite
        library.setFavorite(item, on)
        flow.toast(on ? "Adicionado aos Favoritos." : "Removido dos Favoritos.")
    }

    @ViewBuilder private var menuItems: some View {
        Button { flow.open(.reader(item.id)) } label: { Label("Ler", systemImage: "book") }
        if item.meta.isOCRResult || item.meta.ocrCopyID.flatMap({ library.item(id: $0) }) != nil {
            Button { flow.open(.reader(item.id, mode: .text)) } label: {
                Label("Modo leitor", systemImage: "text.alignleft")
            }
        }
        ShareLink(item: item.url) { Label("Compartilhar", systemImage: "square.and.arrow.up") }
        if library.needsOCRAttention(item) {
            Button { jobs.startOCR(item) } label: { Label("Fazer OCR", systemImage: "text.viewfinder") }
        }
        Button { flow.open(.organize(item.id)) } label: {
            Label("Organizar páginas", systemImage: "rectangle.grid.2x2")
        }
        Button { toggleFavorite() } label: {
            Label(item.meta.favorite ? "Remover dos favoritos" : "Favoritar",
                  systemImage: item.meta.favorite ? "star.slash" : "star")
        }
        if let actions {
            Button { actions.rename(item) } label: { Label("Renomear", systemImage: "pencil") }
            Button { actions.move([item]) } label: { Label("Mover para pasta", systemImage: "folder") }
            Button(role: .destructive) { actions.delete([item]) } label: { Label("Excluir", systemImage: "trash") }
        }
    }
}

// MARK: - Cartão de pasta

struct FolderTile: View {
    let folder: FolderItem
    var actions: FolderActions? = nil
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            TileLabel(title: folder.name, systemImage: "folder.fill", color: Theme.indigo,
                      count: "\(folder.totalDocCount)", shape: .rounded,
                      subtitle: folder.subfolderCount > 0 ? "\(folder.subfolderCount) subpasta\(folder.subfolderCount == 1 ? "" : "s")" : nil)
        }
        .buttonStyle(TileButtonStyle(color: Theme.indigo))
        .contextMenu {
            if let actions {
                Button { actions.rename(folder) } label: { Label("Renomear", systemImage: "pencil") }
                Button(role: .destructive) { actions.delete(folder) } label: { Label("Excluir pasta", systemImage: "trash") }
            }
        }
    }
}

// MARK: - Ações com confirmação (renomear, mover, excluir)

struct MoveRequest: Identifiable {
    let id = UUID()
    let items: [PDFItem]
}

@MainActor
final class ItemActions: ObservableObject {
    @Published var renaming: PDFItem?
    @Published var renameText = ""
    @Published var moving: MoveRequest?
    @Published var deleting: [PDFItem]?

    func rename(_ item: PDFItem) {
        renameText = item.name
        renaming = item
    }
    func move(_ items: [PDFItem]) { moving = MoveRequest(items: items) }
    func delete(_ items: [PDFItem]) { deleting = items }
}

struct ItemActionsModifier: ViewModifier {
    @ObservedObject var actions: ItemActions
    var onDeleted: () -> Void = {}
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow

    func body(content: Content) -> some View {
        content
            .alert("Renomear PDF", isPresented: Binding(get: { actions.renaming != nil },
                                                        set: { if !$0 { actions.renaming = nil } }),
                   presenting: actions.renaming) { item in
                TextField("Nome", text: $actions.renameText)
                Button("Cancelar", role: .cancel) {}
                Button("Salvar") {
                    do { try library.rename(item, to: actions.renameText) } catch { flow.show(error: error) }
                }
            }
            .sheet(item: $actions.moving) { request in
                FolderPickerView(title: "Mover \(request.items.count == 1 ? "PDF" : "\(request.items.count) PDFs")",
                                 current: request.items.count == 1 ? request.items[0].folder : nil) { folder in
                    do {
                        try library.move(request.items, toFolder: folder)
                        flow.toast("Movido para \(folder.isEmpty ? "Sem pasta" : (folder as NSString).lastPathComponent).")
                    } catch {
                        flow.show(error: error)
                    }
                }
                .appEnvironment()
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { actions.deleting != nil },
                                                                  set: { if !$0 { actions.deleting = nil } }),
                                titleVisibility: .visible, presenting: actions.deleting) { items in
                Button("Excluir", role: .destructive) {
                    do {
                        try library.delete(items)
                        onDeleted()
                    } catch {
                        flow.show(error: error)
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: { _ in
                Text("O arquivo será apagado deste iPhone. Esta ação não pode ser desfeita.")
            }
    }

    private var deleteTitle: String {
        let n = actions.deleting?.count ?? 0
        return n == 1 ? "Excluir “\(actions.deleting?.first?.name ?? "")”?" : "Excluir \(n) PDFs?"
    }
}

@MainActor
final class FolderActions: ObservableObject {
    @Published var renaming: FolderItem?
    @Published var renameText = ""
    @Published var deleting: FolderItem?
    @Published var creatingIn: String?
    @Published var newName = ""

    func rename(_ f: FolderItem) {
        renameText = f.name
        renaming = f
    }
    func delete(_ f: FolderItem) { deleting = f }
    func create(in parent: String) {
        newName = ""
        creatingIn = parent
    }
}

struct FolderActionsModifier: ViewModifier {
    @ObservedObject var actions: FolderActions
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow

    func body(content: Content) -> some View {
        content
            .alert("Nova pasta", isPresented: Binding(get: { actions.creatingIn != nil },
                                                      set: { if !$0 { actions.creatingIn = nil } }),
                   presenting: actions.creatingIn) { parent in
                TextField("Nome da pasta", text: $actions.newName)
                Button("Cancelar", role: .cancel) {}
                Button("Criar") {
                    do {
                        let path = try library.createFolder(named: actions.newName, in: parent)
                        flow.pendingAddToFolder = path
                        flow.open(.folder(path))
                    } catch { flow.show(error: error) }
                }
            }
            .alert("Renomear pasta", isPresented: Binding(get: { actions.renaming != nil },
                                                          set: { if !$0 { actions.renaming = nil } }),
                   presenting: actions.renaming) { folder in
                TextField("Nome", text: $actions.renameText)
                Button("Cancelar", role: .cancel) {}
                Button("Salvar") {
                    do { try library.renameFolder(folder.path, to: actions.renameText) } catch { flow.show(error: error) }
                }
            }
            .confirmationDialog("Excluir a pasta “\(actions.deleting?.name ?? "")”?",
                                isPresented: Binding(get: { actions.deleting != nil },
                                                     set: { if !$0 { actions.deleting = nil } }),
                                titleVisibility: .visible, presenting: actions.deleting) { folder in
                Button(folder.totalDocCount > 0 ? "Excluir pasta e \(folder.totalDocCount) PDF\(folder.totalDocCount == 1 ? "" : "s")" : "Excluir pasta",
                       role: .destructive) {
                    do { try library.deleteFolder(folder.path) } catch { flow.show(error: error) }
                }
                Button("Cancelar", role: .cancel) {}
            } message: { folder in
                Text(folder.totalDocCount > 0
                     ? "Todos os PDFs dentro dela serão apagados deste iPhone. Esta ação não pode ser desfeita."
                     : "A pasta está vazia.")
            }
    }
}

// MARK: - Escolher pasta

struct FolderPickerView: View {
    let title: String
    var current: String? = nil
    let onPick: (String) -> Void
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @StateObject private var folderActions = FolderActions()

    var body: some View {
        NavigationStack {
            Screen {
                WideTile(title: "Sem pasta", systemImage: "tray.fill", color: Theme.gray,
                         subtitle: current == "" ? "Pasta atual" : nil) {
                    pick("")
                }
                ForEach(library.folders) { folder in
                    WideTile(title: folder.name, systemImage: "folder.fill", color: Theme.indigo,
                             count: "\(folder.docCount)",
                             subtitle: current == folder.path ? "Pasta atual" : (folder.parent.isEmpty ? nil : folder.parent)) {
                        pick(folder.path)
                    }
                    .padding(.leading, CGFloat(folder.depth) * 18)
                }
                WideTile(title: "Nova pasta", systemImage: "folder.badge.plus", color: Theme.blue) {
                    folderActions.create(in: "")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            }
            .modifier(FolderActionsModifier(actions: folderActions))
        }
    }

    private func pick(_ path: String) {
        dismiss()
        onPick(path)
    }
}

// MARK: - Escolher onde inserir

enum PositionChoice: String, CaseIterable, Identifiable {
    case end = "No final"
    case start = "No início"
    case after = "Depois da pág."
    var id: String { rawValue }
}

struct PositionPicker: View {
    @Binding var choice: PositionChoice
    @Binding var afterPage: Int
    let pageCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Posição", selection: $choice) {
                ForEach(PositionChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if choice == .after {
                HStack {
                    Text("Depois da página")
                        .foregroundStyle(Theme.text)
                    TextField("", value: $afterPage, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .frame(width: 64)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.search))
                    Stepper("", value: $afterPage, in: 1...max(1, pageCount))
                        .labelsHidden()
                    Spacer()
                }
                Text("O documento tem \(pageCount.pagesText).")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .onChange(of: afterPage) { _, value in
            if value < 1 { afterPage = 1 } else if value > max(1, pageCount) { afterPage = max(1, pageCount) }
        }
    }

    static func position(_ choice: PositionChoice, afterPage: Int) -> InsertPosition {
        switch choice {
        case .start: return .start
        case .end: return .end
        case .after: return .after(afterPage)
        }
    }
}

/// Pergunta onde entram as páginas recém-escaneadas.
struct InsertPositionSheet: View {
    let pending: PendingScanInsert
    let targetPageCount: Int
    let onConfirm: (InsertPosition) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choice: PositionChoice = .end
    @State private var afterPage = 1

    var body: some View {
        NavigationStack {
            Screen {
                TileCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Onde incluir \(pending.pageCount == 1 ? "a página escaneada" : "as \(pending.pageCount) páginas escaneadas")?")
                            .font(.headline)
                            .foregroundStyle(Theme.text)
                        PositionPicker(choice: $choice, afterPage: $afterPage, pageCount: targetPageCount)
                    }
                }
                PrimaryButton(title: "Incluir \(pending.pageCount.pagesText)") {
                    onConfirm(PositionPicker.position(choice, afterPage: afterPage))
                }
            }
            .navigationTitle("Incluir páginas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { afterPage = max(1, targetPageCount) }
    }
}

struct PrimaryButton: View {
    let title: String
    var color: Color = Theme.blue
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                    .fill(enabled ? color : Color.gray.opacity(0.45)))
        }
        .disabled(!enabled)
    }
}

// MARK: - Avisos na parte de baixo

struct BottomOverlays: View {
    @EnvironmentObject private var jobs: JobCenter
    @EnvironmentObject private var flow: AppFlow

    var body: some View {
        VStack(spacing: 8) {
            if let toast = flow.toastMessage {
                HStack(alignment: .center, spacing: 10) {
                    Text(toast.text)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let action = toast.actionTitle {
                        Button(action) { flow.runToastAction() }
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.yellow)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                    .fill(Color(white: 0.16).opacity(0.96)))
                .onTapGesture { flow.dismissToast() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let running = jobs.running {
                JobBanner(running: running) { jobs.cancel() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, 8)
        .animation(.spring(duration: 0.3), value: jobs.running?.itemID)
    }
}

struct JobBanner: View {
    let running: JobCenter.Running
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TileIcon(systemImage: "text.viewfinder", color: Theme.orange, shape: .rounded, size: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text("OCR: \(running.name)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if running.total > 0 {
                    ProgressView(value: Double(running.done), total: Double(running.total))
                        .tint(Theme.orange)
                    Text("\(running.done) de \(running.total) página\(running.total == 1 ? "" : "s")")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    Text("Preparando…")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.secondaryText)
            }
            .accessibilityLabel("Cancelar OCR")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                .fill(Theme.tile)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        )
    }
}

struct BusyOverlay: View {
    let message: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(minWidth: 180)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
        }
    }
}

// MARK: - Scanner de documentos (câmera)

struct DocumentScannerView: UIViewControllerRepresentable {
    let onFinish: (VNDocumentCameraScan) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: (VNDocumentCameraScan) -> Void
        let onCancel: () -> Void
        init(onFinish: @escaping (VNDocumentCameraScan) -> Void, onCancel: @escaping () -> Void) {
            self.onFinish = onFinish
            self.onCancel = onCancel
        }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            onFinish(scan)
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            onCancel()
        }
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Theme.secondaryText)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

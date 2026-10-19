import PDFKit
import SwiftUI

/// Escolha de páginas: tocando nas miniaturas, digitando números e trechos ("2, 5-15, 20-fim")
/// ou com o botão "Todas".
struct PagePickerScreen: View {
    enum Mode: Equatable {
        case insert(targetPageCount: Int)
        case remove
        case extract
    }

    let mode: Mode
    let sourceURL: URL
    let sourceVersion: String
    let sourceTitle: String
    var dismissAll: (() -> Void)? = nil
    let onConfirm: (_ pages: [Int], _ position: InsertPosition) async throws -> Void

    @EnvironmentObject private var flow: AppFlow
    @Environment(\.dismiss) private var dismiss
    @State private var pageCount = 0
    @State private var loadError: String?
    @State private var selected = Set<Int>()
    @State private var rangeText = ""
    @State private var rangeError: String?
    @State private var editingText = false
    @State private var positionChoice: PositionChoice = .end
    @State private var afterPage = 1
    @State private var working = false
    @State private var confirmRemove = false
    @FocusState private var fieldFocused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    selectionCard
                    if let loadError {
                        EmptyStateView(systemImage: "exclamationmark.triangle", title: "Não foi possível abrir", message: loadError)
                    } else if pageCount == 0 {
                        ProgressView().padding(40)
                    } else {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(1...pageCount, id: \.self) { n in
                                pageCell(n)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.margin)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            bottomBar
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancelar") { close() }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("OK") { fieldFocused = false }
            }
        }
        .task { await load() }
        .confirmationDialog(removeTitle, isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remover", role: .destructive) { confirm() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("As páginas saem deste PDF. Você pode usar “Desfazer última alteração” logo depois, se precisar.")
        }
        .interactiveDismissDisabled(working)
    }

    // MARK: - Partes da tela

    private var selectionCard: some View {
        TileCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(sourceTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text("Páginas")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.text)
                    TextField("ex.: 1, 5-15, 20-fim", text: $rangeText)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .submitLabel(.done)
                        .padding(.horizontal, 10)
                        .frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.search))
                        .onChange(of: rangeText) { _, newValue in
                            if fieldFocused { applyText(newValue) }
                        }
                }
                if let rangeError {
                    Text(rangeError)
                        .font(.footnote)
                        .foregroundStyle(Theme.red)
                }
                HStack(spacing: 8) {
                    smallButton("Todas") { setSelection(Set(1...max(pageCount, 1)).filter { $0 <= pageCount }) }
                    smallButton("Nenhuma") { setSelection([]) }
                    smallButton("Inverter") {
                        setSelection(Set((1...max(pageCount, 1)).filter { !selected.contains($0) && $0 <= pageCount }))
                    }
                    Spacer()
                    Text("\(selected.count) de \(pageCount)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
                .disabled(pageCount == 0)
            }
        }
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(Theme.search))
        }
        .buttonStyle(.plain)
    }

    private func pageCell(_ n: Int) -> some View {
        let isOn = selected.contains(n)
        return Button {
            fieldFocused = false
            var s = selected
            if isOn { s.remove(n) } else { s.insert(n) }
            setSelection(s)
        } label: {
            VStack(spacing: 4) {
                PageThumbnailView(url: sourceURL, version: sourceVersion, page: n - 1, width: 110)
                    .aspectRatio(0.707, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isOn ? accent : Color.black.opacity(0.12), lineWidth: isOn ? 3 : 0.5)
                    )
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(isOn ? accent : Color.gray.opacity(0.7))
                            .background(Circle().fill(Color.white).padding(2))
                            .padding(5)
                    }
                    .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                Text("\(n)")
                    .font(.system(size: 13, weight: isOn ? .bold : .medium))
                    .foregroundStyle(isOn ? accent : Theme.secondaryText)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Página \(n)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if case .insert(let targetCount) = mode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Incluir onde?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                    PositionPicker(choice: $positionChoice, afterPage: $afterPage, pageCount: targetCount)
                }
            }
            PrimaryButton(title: confirmTitle, color: accent, enabled: canConfirm && !working) {
                fieldFocused = false
                if mode == .remove { confirmRemove = true } else { confirm() }
            }
            .overlay { if working { ProgressView().tint(.white) } }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Theme.background.shadow(color: .black.opacity(0.08), radius: 6, y: -2).ignoresSafeArea())
    }

    // MARK: - Lógica

    private var accent: Color {
        switch mode {
        case .insert: return Theme.teal
        case .remove: return Theme.red
        case .extract: return Theme.indigo
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .insert: return "Escolher páginas"
        case .remove: return "Remover páginas"
        case .extract: return "Extrair páginas"
        }
    }

    private var confirmTitle: String {
        let n = selected.count
        let pages = n == 1 ? "1 página" : "\(n) páginas"
        switch mode {
        case .insert: return n == 0 ? "Escolha as páginas" : "Incluir \(pages)"
        case .remove: return n == 0 ? "Escolha as páginas" : "Remover \(pages)"
        case .extract: return n == 0 ? "Escolha as páginas" : "Extrair \(pages) para um novo PDF"
        }
    }

    private var removeTitle: String {
        "Remover \(selected.count == 1 ? "1 página" : "\(selected.count) páginas")?"
    }

    private var canConfirm: Bool {
        guard !selected.isEmpty, rangeError == nil else { return false }
        if mode == .remove { return selected.count < pageCount }
        return true
    }

    private func setSelection(_ s: Set<Int>) {
        selected = s
        rangeText = PageSelection.format(Array(s))
        rangeError = (mode == .remove && !s.isEmpty && s.count >= pageCount)
            ? "Não é possível remover todas as páginas. Para isso, exclua o documento." : nil
    }

    private func applyText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            selected = []
            rangeError = nil
            return
        }
        do {
            let pages = try PageSelection.parse(text, pageCount: pageCount)
            selected = Set(pages)
            rangeError = (mode == .remove && pages.count >= pageCount)
                ? "Não é possível remover todas as páginas. Para isso, exclua o documento." : nil
        } catch {
            rangeError = error.localizedDescription
        }
    }

    private func load() async {
        let url = sourceURL
        let count = await Task.detached(priority: .userInitiated) { () -> Int? in
            guard let doc = PDFDocument(url: url), !doc.isLocked else { return nil }
            return doc.pageCount
        }.value
        if let count, count > 0 {
            pageCount = count
            if case .insert(let targetCount) = mode { afterPage = max(1, targetCount) }
        } else {
            loadError = "O PDF pode estar protegido por senha ou corrompido."
        }
    }

    private func confirm() {
        let pages = selected.sorted()
        let position = PositionPicker.position(positionChoice, afterPage: afterPage)
        working = true
        Task {
            do {
                try await onConfirm(pages, position)
                working = false
                close()
            } catch {
                working = false
                flow.show(error: error)
            }
        }
    }

    private func close() {
        if let dismissAll { dismissAll() } else { dismiss() }
    }
}

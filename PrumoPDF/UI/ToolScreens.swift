import PDFKit
import SwiftUI

// MARK: - Dividir em partes iguais

struct SplitSheet: View {
    let item: PDFItem
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @Environment(\.dismiss) private var dismiss
    @State private var partsText = ""
    @State private var working = false
    @FocusState private var focused: Bool

    private var pageCount: Int { item.pageCount ?? 0 }
    private var parts: Int? { Int(partsText.trimmingCharacters(in: .whitespaces)) }

    private var validation: String? {
        guard let parts else { return partsText.isEmpty ? nil : "Digite um número inteiro." }
        do {
            _ = try SplitPlan.sizes(pageCount: pageCount, parts: parts)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        NavigationStack {
            Screen {
                TileCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("“\(item.name)” tem \(pageCount.pagesText).")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.text)
                        Text("Em quantas partes você quer dividir?")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        TextField("Número de partes", text: $partsText)
                            .keyboardType(.numberPad)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .focused($focused)
                            .frame(height: 58)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.search))
                        if let validation {
                            Text(validation).font(.footnote).foregroundStyle(Theme.red)
                        } else if let parts, let summary = SplitPlan.summary(pageCount: pageCount, parts: parts) {
                            Text(summary)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.teal)
                            preview(parts: parts)
                        }
                    }
                }
                PrimaryButton(title: working ? "Dividindo…" : "Dividir", color: Theme.pink,
                              enabled: parts != nil && validation == nil && !working) {
                    split()
                }
                Text("Os novos arquivos ficam na mesma pasta, com o nome do original e o número da parte. O original não muda.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Dividir em partes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(working) }
            }
            .onAppear { focused = true }
        }
        .interactiveDismissDisabled(working)
    }

    private func preview(parts: Int) -> some View {
        let ranges = (try? SplitPlan.ranges(pageCount: pageCount, parts: parts)) ?? []
        let shown = ranges.count <= 6 ? Array(ranges.enumerated()) : Array(ranges.enumerated().prefix(3)) + Array(ranges.enumerated().suffix(2))
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(shown, id: \.offset) { pair in
                if ranges.count > 6 && pair.offset == ranges.count - 2 {
                    Text("…").foregroundStyle(Theme.secondaryText)
                }
                HStack {
                    Image(systemName: "doc").foregroundStyle(Theme.secondaryText)
                    Text("\(item.name) - Parte \(pair.offset + 1)")
                        .lineLimit(1)
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text("págs. \(pair.element.lowerBound)–\(pair.element.upperBound)")
                        .foregroundStyle(Theme.secondaryText)
                }
                .font(.system(size: 13))
            }
        }
    }

    private func split() {
        guard let parts else { return }
        focused = false
        working = true
        let url = item.url
        let name = item.name
        let folder = item.folder
        Task {
            do {
                let docs = try await Task.detached(priority: .userInitiated) {
                    try PDFOps.split(try PDFOps.open(url), parts: parts)
                }.value
                var created: [PDFItem] = []
                for (i, doc) in docs.enumerated() {
                    created.append(try await library.save(newDocument: doc, name: "\(name) - Parte \(i + 1)", folder: folder))
                }
                working = false
                dismiss()
                flow.toast("\(created.count) arquivos criados em \(item.folderName).", actionTitle: "Ver") {
                    flow.open(.folder(folder))
                }
            } catch {
                working = false
                flow.show(error: error)
            }
        }
    }
}

// MARK: - Combinar PDFs

struct MergeScreen: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @State private var chosen: [String] = []
    @State private var name = "PDF combinado"
    @State private var showChooser = false
    @State private var working = false

    private var chosenItems: [PDFItem] { chosen.compactMap { library.item(id: $0) } }

    var body: some View {
        List {
            Section {
                Text("Escolha os PDFs e arraste pela alça (≡) para definir a ordem. O resultado é um PDF novo; os originais não mudam.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text)
                    .listRowBackground(tileBackground)
            }
            Section {
                ForEach(chosenItems) { item in
                    HStack(spacing: 12) {
                        PageThumbnailView(url: item.url, version: item.version, width: 30)
                            .frame(width: 30, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                            Text(item.pageCount.map { $0.pagesText } ?? "…")
                                .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .listRowBackground(tileBackground)
                }
                .onMove { chosen.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { chosen.remove(atOffsets: $0) }
                Button {
                    showChooser = true
                } label: {
                    Label(chosen.isEmpty ? "Escolher PDFs" : "Adicionar mais PDFs", systemImage: "plus.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                .listRowBackground(tileBackground)
            } header: {
                Text(chosen.isEmpty ? "PDFs" : "\(chosen.count) PDFs · \(totalPages.pagesText)")
            }
            Section("Nome do novo PDF") {
                TextField("Nome", text: $name)
                    .listRowBackground(tileBackground)
            }
            Section {
                PrimaryButton(title: working ? "Combinando…" : "Combinar", color: Theme.purple,
                              enabled: chosen.count >= 2 && !working) { merge() }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Combinar PDFs")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showChooser) {
            NavigationStack {
                DocumentChooser(title: "Escolher PDFs", multiple: true, excluding: Set(chosen), allowImport: true,
                                onDone: { items in
                                    chosen.append(contentsOf: items.map(\.id))
                                    showChooser = false
                                },
                                onCancel: { showChooser = false })
            }
            .appEnvironment()
        }
        .onAppear {
            if chosen.isEmpty && !flow.mergePreselection.isEmpty {
                chosen = flow.mergePreselection
                flow.mergePreselection = []
            }
        }
    }

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: 0).fill(Theme.tile)
    }

    private var totalPages: Int { chosenItems.compactMap(\.pageCount).reduce(0, +) }

    private func merge() {
        let urls = chosenItems.map(\.url)
        let folder = chosenItems.first?.folder ?? ""
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? "PDF combinado" : name
        working = true
        Task {
            do {
                let doc = try await Task.detached(priority: .userInitiated) {
                    PDFOps.merge(try urls.map { try PDFOps.open($0) })
                }.value
                let saved = try await library.save(newDocument: doc, name: finalName, folder: folder)
                working = false
                chosen = []
                flow.toast("PDF combinado: \(saved.name)", actionTitle: "Abrir") { flow.open(.document(saved.id)) }
            } catch {
                working = false
                flow.show(error: error)
            }
        }
    }
}

// MARK: - Ajustes

struct SettingsScreen: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @AppStorage(AppSettings.includeInBackupKey) private var includeInBackup = true
    @AppStorage(AppSettings.ocrLanguageKey) private var ocrLanguage = "por"
    @AppStorage("lastBackup") private var lastBackup: Double = 0
    @State private var exportDocument: LibraryFolderDocument?
    @State private var showExporter = false
    @State private var showRestore = false

    private var lastBackupText: String {
        guard lastBackup > 0 else { return "Nenhuma cópia feita ainda." }
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "dd/MM/yyyy, HH:mm"
        return "Última cópia: \(f.string(from: Date(timeIntervalSince1970: lastBackup)))."
    }

    var body: some View {
        Screen {
            SectionTitle(text: "Backup")
            TileCard {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $includeInBackup) {
                        Text("Incluir os PDFs no backup do iCloud")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.text)
                    }
                    Text(includeInBackup
                         ? "Os PDFs entram no backup do iPhone no iCloud, se ele estiver ligado nos Ajustes do iPhone. Se você trocar ou perder o aparelho, eles voltam com o backup."
                         : "Os PDFs ficam só neste iPhone e não entram em nenhum backup. Se o aparelho for perdido ou apagado, os PDFs se perdem junto.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            SectionTitle(text: "Cópia de segurança")
            TileCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Uma cópia completa (PDFs, pastas e favoritos) numa pasta comum, onde você escolher: iCloud Drive, Google Drive, OneDrive, pendrive… A cópia abre também no Prumo para Windows. \(lastBackupText)")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.text)
                    HStack(spacing: 10) {
                        Button("Salvar uma cópia em…") {
                            do {
                                exportDocument = LibraryFolderDocument(wrapper: try library.backupWrapper())
                                showExporter = true
                            } catch { flow.show(error: error) }
                        }
                        .buttonStyle(.bordered)
                        Button("Restaurar…") { showRestore = true }
                            .buttonStyle(.bordered)
                    }
                    .font(.system(size: 15, weight: .semibold))
                }
            }
            SectionTitle(text: "OCR")
            TileCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Idioma dos documentos")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Picker("Idioma", selection: $ocrLanguage) {
                        Text("Português").tag("por")
                        Text("Português + Inglês").tag("por+eng")
                    }
                    .pickerStyle(.segmented)
                    Text("O OCR usa o reconhecimento de texto da Apple e roda inteiramente neste iPhone. Páginas com baixa confiança são marcadas para revisão; mesmo assim, confira nomes, datas, números e valores no original.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            SectionTitle(text: "Sobre")
            TileCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Tudo é processado neste iPhone. O app não envia arquivos para a internet; só o que você compartilhar sai do aparelho.",
                          systemImage: "lock.shield.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text)
                    Label("Os PDFs ficam no app Arquivos, em No meu iPhone › Prumo PDF.", systemImage: "folder.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text)
                    Text("Prumo PDF \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .navigationTitle("Ajustes")
        .onChange(of: includeInBackup) { _, _ in library.applyBackupPreference() }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .folder,
                      defaultFilename: Library.backupName()) { result in
            switch result {
            case .success:
                lastBackup = Date().timeIntervalSince1970
                flow.toast("Cópia salva: \(library.items.count) PDF\(library.items.count == 1 ? "" : "s").")
            case .failure(let error):
                flow.show(error: error)
            }
            exportDocument = nil
        }
        .fileImporter(isPresented: $showRestore, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            do {
                let r = try library.restore(from: url)
                var msg = "\(r.added) PDF\(r.added == 1 ? "" : "s") restaurado\(r.added == 1 ? "" : "s")"
                if r.skipped > 0 { msg += "; \(r.skipped) já estava\(r.skipped == 1 ? "" : "m") aqui" }
                flow.toast(msg + ".")
            } catch { flow.show(error: error) }
        }
    }
}

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
    @AppStorage(AppSettings.dewarpPhotosKey) private var dewarpPhotos = false
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
            SectionTitle(text: "Fotos e páginas escaneadas")
            TileCard {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $dewarpPhotos) {
                        Text("Corrigir páginas curvas")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.text)
                    }
                    Text("Ao escanear e ao converter fotos: páginas de livros e revistas (curvatura perto da lombada) e papel ondulado ficam com o texto reto, e o OCR acerta mais. Em páginas já retas, deixe desligado: a margem pode ser cortada. Também dá para corrigir um PDF pronto, na tela dele. Usa o modelo UVDoc, no próprio iPhone.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
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

/// Corrigir páginas curvas de um PDF: prévia antes/depois, escolha das páginas e cópia corrigida.
struct DewarpSheet: View {
    let item: PDFItem
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @Environment(\.dismiss) private var dismiss
    @State private var page = 1
    @State private var before: UIImage?
    @State private var after: UIImage?
    @State private var previewError: String?
    @State private var pagesText = ""
    @State private var working = false

    private var total: Int { max(1, item.pageCount ?? 1) }

    private var selection: Result<[Int], Error> {
        let t = pagesText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .success(Array(1...total)) }
        return Result { try PageSelection.parse(t, pageCount: total) }
    }

    var body: some View {
        NavigationStack {
            Screen {
                TileCard {
                    Text("Para fotos de livros e revistas (página curvada perto da lombada), papel ondulado ou dobrado. O texto fica reto, o que também melhora o OCR. Em páginas que já estão retas, não use: a margem pode ser cortada.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
                HStack(spacing: 10) {
                    previewColumn("Antes", before)
                    previewColumn("Depois", after)
                }
                .frame(height: 300)
                HStack {
                    Button { page -= 1 } label: { Image(systemName: "chevron.left") }.disabled(page <= 1)
                    Spacer()
                    Text("Prévia da página \(page) de \(total)").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button { page += 1 } label: { Image(systemName: "chevron.right") }.disabled(page >= total)
                }
                .padding(.horizontal, 4)
                TileCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Quais páginas corrigir? Em branco = todas. Ex.: 1, 3-5")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                        TextField("Todas (1-\(total))", text: $pagesText)
                            .keyboardType(.numbersAndPunctuation)
                            .textFieldStyle(.roundedBorder)
                        switch selection {
                        case .success(let pages):
                            Text(pagesText.isEmpty ? "Todas as páginas serão corrigidas." : "\(pages.count) página\(pages.count == 1 ? "" : "s") será\(pages.count == 1 ? "" : "ão") corrigida\(pages.count == 1 ? "" : "s").")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.teal)
                        case .failure(let e):
                            Text(e.localizedDescription).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.red)
                        }
                    }
                }
                PrimaryButton(title: working ? "Corrigindo…" : "Corrigir e criar cópia", color: Theme.teal,
                              enabled: !working && (try? selection.get()) != nil) { run() }
                Text("O original não muda: o resultado é um PDF novo, com “- corrigido” no nome. Depois, o app pergunta se você quer fazer o OCR.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
            .navigationTitle("Corrigir páginas curvas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
            .task(id: page) { await loadPreview() }
        }
    }

    private func previewColumn(_ title: String, _ image: UIImage?) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.white)
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if let previewError {
                    Text(previewError).font(.footnote).foregroundStyle(Theme.secondaryText).padding(6)
                } else {
                    ProgressView()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func loadPreview() async {
        before = nil
        after = nil
        previewError = nil
        guard let doc = PDFDocument(url: item.url), let p = doc.page(at: page - 1) else {
            previewError = "Não foi possível abrir o PDF."
            return
        }
        let img = Dewarp.render(p, dpi: 100)
        before = img
        do { after = try Dewarp.unwarp(img) } catch { previewError = error.localizedDescription }
    }

    private func run() {
        guard let pages = try? selection.get(), let doc = PDFDocument(url: item.url) else { return }
        working = true
        flow.busyMessage = "Corrigindo \(pages.count) página\(pages.count == 1 ? "" : "s")…"
        Task {
            do {
                let data = try Dewarp.dewarpPDF(doc, pages: pages)
                let new = try library.save(newData: data, name: "\(item.name) - corrigido", folder: item.folder)
                flow.busyMessage = nil
                working = false
                dismiss()
                flow.askOCRItemID = new.id   // "Usar OCR agora?" e depois abre o PDF corrigido
            } catch {
                flow.busyMessage = nil
                working = false
                flow.show(error: error)
            }
        }
    }
}

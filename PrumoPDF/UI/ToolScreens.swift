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
    @AppStorage(AppLock.enabledKey) private var lockEnabled = false
    @State private var lockToggle = false
    @State private var exportDocument: LibraryFolderDocument?
    @State private var showExporter = false
    @State private var showRestore = false
    @State private var showCloud = false

    private var lastBackupText: String {
        guard lastBackup > 0 else { return "Nenhuma cópia feita ainda." }
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "dd/MM/yyyy, HH:mm"
        return "Última cópia: \(f.string(from: Date(timeIntervalSince1970: lastBackup)))."
    }

    var body: some View {
        Screen {
            SectionTitle(text: "Backup e sincronização")
            TileCard {
                VStack(alignment: .leading, spacing: 10) {
                    if let cloud = library.cloudName {
                        Label("Backup e sincronização no \(cloud)", systemImage: "checkmark.icloud.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.green)
                        Text("Os PDFs ficam na pasta “\(library.root.lastPathComponent)” do \(cloud). O que você salva aqui aparece no Prumo do Windows (e em outros iPhones) que usam a mesma pasta, e vice-versa.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                        if library.downloadingCount > 0 {
                            Label("Baixando \(library.downloadingCount) PDF\(library.downloadingCount == 1 ? "" : "s") da nuvem…",
                                  systemImage: "icloud.and.arrow.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.blue)
                        }
                    } else {
                        Label("Só neste iPhone", systemImage: "iphone")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.orange)
                        Text("Para ver os mesmos PDFs no iPhone e no Windows, escolha uma nuvem.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    if let problem = library.cloudProblem {
                        Text(problem).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.red)
                    }
                    PrimaryButton(title: library.isLocal ? "Escolher nuvem…" : "Trocar de nuvem…", color: Theme.blue) {
                        showCloud = true
                    }
                    if library.isLocal {
                        Toggle(isOn: $includeInBackup) {
                            Text("Incluir os PDFs no backup do iCloud")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.text)
                        }
                        Text(includeInBackup
                             ? "Os PDFs entram no backup do iPhone no iCloud, se ele estiver ligado nos Ajustes do iPhone. Se você trocar ou perder o aparelho, eles voltam com o backup (mas não aparecem no Windows)."
                             : "Os PDFs ficam só neste iPhone e não entram em nenhum backup. Se o aparelho for perdido ou apagado, os PDFs se perdem junto.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                    }
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
            SectionTitle(text: "Segurança")
            TileCard {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $lockToggle) {
                        Text("Pedir \(AppLock.methodName) para abrir")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.text)
                    }
                    .onChange(of: lockToggle) { _, on in
                        guard on != lockEnabled else { return }
                        Task {
                            let ok = await AppLock.shared.setEnabled(on)
                            if !ok {
                                lockToggle = lockEnabled
                                if let e = AppLock.shared.lastError { flow.toast(e) }
                            }
                        }
                    }
                    Text("O Prumo bloqueia ao sair do app e pede \(AppLock.methodName) (ou o código do iPhone) ao voltar. Para proteger um PDF em si, por exemplo antes de enviar, use “Proteger com senha” na tela dele: a senha vai junto com o arquivo e vale em qualquer leitor de PDF.")
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
                    Label(library.isLocal ? "Os PDFs ficam no app Arquivos, em No meu iPhone › Prumo PDF."
                                          : "Os PDFs ficam no app Arquivos, em \(library.cloudName ?? "nuvem") › \(library.root.lastPathComponent).",
                          systemImage: "folder.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text)
                    Text("Desenvolvido por Color Software")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Prumo PDF \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .navigationTitle("Ajustes")
        .onAppear { lockToggle = lockEnabled }
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
        .sheet(isPresented: $showCloud) { CloudChooserSheet() }
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

/// Escolher a nuvem do backup e da sincronização. A biblioteca passa a ficar numa pasta da nuvem,
/// escolhida no app Arquivos; o Prumo do Windows usa a mesma pasta.
struct CloudChooserSheet: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var pickFolder = false
    @State private var picked: URL?
    @State private var askBring = false
    @State private var askLocal = false

    /// Apps oficiais na App Store (ids conferidos na busca da Apple em 28/10/2026). Entrar na conta
    /// é feito no app de cada nuvem; o iCloud usa a conta Apple dos Ajustes do iPhone.
    private struct CloudApp: Identifiable {
        let name: String
        let appStore: String
        let note: String
        var id: String { name }
    }
    private let others = [
        CloudApp(name: "Dropbox", appStore: "https://apps.apple.com/br/app/id327630330",
                 note: "Funciona se o app do Dropbox deixar escolher a pasta no app Arquivos. No Windows, instale o Dropbox para computador."),
        CloudApp(name: "Google Drive", appStore: "https://apps.apple.com/br/app/id507874739",
                 note: "No iPhone, o app do Google Drive não deixa outros apps usarem uma pasta dele (só arquivos avulsos). Para sincronizar com o iPhone, prefira o iCloud Drive."),
        CloudApp(name: "OneDrive", appStore: "https://apps.apple.com/br/app/id477537958",
                 note: "No iPhone, o app do OneDrive não deixa outros apps usarem uma pasta dele (só arquivos avulsos). Para sincronizar com o iPhone, prefira o iCloud Drive."),
    ]

    var body: some View {
        NavigationStack {
            Screen {
                TileCard {
                    Text("Os PDFs passam a ficar numa pasta “Prumo PDF” na nuvem: é o backup e também a sincronização. No Windows, escolha a mesma nuvem no Prumo (Ajustes › Escolher nuvem) e os PDFs, as pastas e os favoritos aparecem nos dois.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.text)
                }
                TileCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("iCloud Drive").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                            Spacer()
                            Text("Recomendado").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.green)
                        }
                        Text("Para entrar: Ajustes do iPhone › seu nome › iCloud › iCloud Drive (ligado). No Windows: instale o iCloud para Windows e entre com a mesma conta Apple.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                        PrimaryButton(title: "Usar o iCloud Drive…", color: Theme.blue) { pickFolder = true }
                        Text("No seletor, toque em “iCloud Drive” e depois em “Abrir”. O Prumo cria a pasta “Prumo PDF” lá dentro.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                ForEach(others) { app in
                    TileCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(app.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(app.note).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                            HStack(spacing: 10) {
                                Button("Entrar ou instalar o app") {
                                    if let url = URL(string: app.appStore) { openURL(url) }
                                }
                                .buttonStyle(.bordered)
                                Button("Usar uma pasta…") { pickFolder = true }
                                    .buttonStyle(.bordered)
                            }
                            .font(.system(size: 14, weight: .semibold))
                        }
                    }
                }
                if !library.isLocal {
                    Button("Voltar a guardar só no iPhone") { askLocal = true }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.red)
                        .padding(.top, 4)
                }
            }
            .navigationTitle("Escolher a nuvem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
        }
        .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            picked = url
            if library.isLocal && !library.items.isEmpty { askBring = true } else { apply(bring: false) }
        }
        .confirmationDialog("Levar os PDFs deste iPhone para a nuvem?", isPresented: $askBring, titleVisibility: .visible) {
            Button("Levar os PDFs") { apply(bring: true) }
            Button("Não levar (ficam no iPhone)") { apply(bring: false) }
            Button("Cancelar", role: .cancel) { picked = nil }
        } message: {
            Text("Os PDFs, as pastas e os favoritos vão para a pasta da nuvem, sem duplicar os que já estão lá, e saem do iPhone depois de copiados.")
        }
        .confirmationDialog("Voltar a guardar só no iPhone?", isPresented: $askLocal, titleVisibility: .visible) {
            Button("Copiar os PDFs da nuvem para o iPhone") { backToLocal(bring: true) }
            Button("Não copiar") { backToLocal(bring: false) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Os PDFs continuam na nuvem. O iPhone deixa de sincronizar com o Windows.")
        }
    }

    private func apply(bring: Bool) {
        guard let url = picked else { return }
        picked = nil
        do {
            let r = try library.useCloudFolder(url, bringLocal: bring)
            var msg = "Pronto: a biblioteca agora está no \(library.cloudName ?? "nuvem")"
            if bring, r.added + r.skipped > 0 { msg += " (\(r.added) PDF\(r.added == 1 ? "" : "s") levado\(r.added == 1 ? "" : "s"))" }
            flow.toast(msg + ".")
            dismiss()
        } catch { flow.show(error: error) }
    }

    private func backToLocal(bring: Bool) {
        do {
            let r = try library.useLocalStorage(bringCloud: bring)
            flow.toast(bring ? "Pronto: \(r.added) PDF\(r.added == 1 ? "" : "s") copiado\(r.added == 1 ? "" : "s") para o iPhone." : "Pronto: os PDFs ficam só neste iPhone.")
            dismiss()
        } catch { flow.show(error: error) }
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

/// Proteger com senha: cópia do PDF que só abre com a senha, em qualquer leitor de PDF.
struct ProtectSheet: View {
    let item: PDFItem
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @Environment(\.dismiss) private var dismiss
    @State private var pw1 = ""
    @State private var pw2 = ""
    @State private var deleteOriginal = true

    private var problem: String? {
        if !pw1.isEmpty && pw1.count < 4 { return "Use pelo menos 4 caracteres." }
        if !pw2.isEmpty && pw1 != pw2 { return "As senhas não são iguais." }
        return nil
    }

    private var ready: Bool { pw1.count >= 4 && pw1 == pw2 }

    var body: some View {
        NavigationStack {
            Screen {
                TileCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("“\(item.name)”").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("A cópia protegida só abre com a senha, em qualquer leitor de PDF (iPhone, Adobe, Edge, Chrome).")
                            .font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                        SecureField("Senha", text: $pw1).textFieldStyle(.roundedBorder)
                        SecureField("Repita a senha", text: $pw2).textFieldStyle(.roundedBorder)
                        if let problem { Text(problem).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.red) }
                        Toggle("Apagar o original (sem senha)", isOn: $deleteOriginal)
                            .font(.system(size: 15))
                        Text("Importante: se você esquecer a senha, não há como abrir o PDF, nem pelo Prumo. Guarde a senha num lugar seguro. Evite acentos e “ç” na senha: alguns leitores de PDF não os entendem.")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.orange)
                    }
                }
                PrimaryButton(title: "Proteger", color: Theme.purple, enabled: ready) { run() }
            }
            .navigationTitle("Proteger com senha")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
    }

    private func run() {
        do {
            let new = try library.protect(item, password: pw1)
            if deleteOriginal, let original = library.item(id: item.id) { try library.delete([original]) }
            dismiss()
            if deleteOriginal { flow.popToRoot() }
            flow.toast("PDF protegido: \(new.name)", actionTitle: "Abrir") { flow.open(.document(new.id)) }
        } catch {
            flow.show(error: error)
        }
    }
}

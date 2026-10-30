import SwiftUI
import UniformTypeIdentifiers

/// Assinar um PDF com o certificado A1 guardado no iPhone.
struct SignSheet: View {
    let item: PDFItem
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @Environment(\.dismiss) private var dismiss
    @State private var certs: [SigningCertificate] = []
    @State private var selected: String = ""
    @State private var stamp = UserDefaults.standard.object(forKey: "signStamp") as? Bool ?? true
    @State private var page = SignOptions.Page(rawValue: UserDefaults.standard.string(forKey: "signPage") ?? "") ?? .last
    @State private var position = SignOptions.Position(rawValue: UserDefaults.standard.string(forKey: "signPosition") ?? "") ?? .bottomLeft
    @State private var reason = ""
    @State private var level = ProtectionLevel.saved
    @State private var why = ProtectionLevel.Why.standard
    @State private var lockedLevel: ProtectionLevel?
    @State private var askLevelOne = false
    @State private var working = false
    @StateObject private var importer = CertificateImporter()

    private var already: Int { item.meta.signed ?? 0 }
    private var cert: SigningCertificate? { certs.first { $0.id == selected } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(warning)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.orange)
                }
                Section("Certificado") {
                    if certs.isEmpty {
                        Text("Nenhum certificado A1 neste iPhone.").foregroundStyle(Theme.secondaryText)
                    } else {
                        Picker("Certificado", selection: $selected) {
                            ForEach(certs) { c in
                                Text(c.name + (c.expired ? " (vencido)" : "")).tag(c.id)
                            }
                        }
                        if let c = cert {
                            Text("Emitido por \(c.issuer). Válido até \(c.certificate.notAfter.formatted(date: .numeric, time: .omitted)).")
                                .font(.system(size: 13))
                                .foregroundStyle(c.expired ? Theme.red : Theme.secondaryText)
                        }
                    }
                    Button("Adicionar certificado A1 (.pfx ou .p12)…") { importer.start() }
                }
                levelSection
                Section("Carimbo na página") {
                    Toggle("Mostrar a assinatura na página", isOn: $stamp)
                    if stamp {
                        Picker("Página", selection: $page) {
                            ForEach(SignOptions.Page.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Posição", selection: $position) {
                            ForEach(SignOptions.Position.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }
                Section("Motivo (opcional)") {
                    TextField("Ex.: Sou o autor deste documento", text: $reason)
                }
                Section {
                    PrimaryButton(title: working ? "Assinando…" : "Assinar", color: Theme.blue,
                                  enabled: cert != nil && !working) { sign() }
                } footer: {
                    Text("Formato PAdES, reconhecido pelo Adobe Reader e por outros leitores de PDF. O Face ID (ou o código) confirma que é você. Com certificado ICP-Brasil, a assinatura tem a mesma validade jurídica da assinatura de próprio punho (MP 2.200-2/2001).")
                }
            }
            .navigationTitle("Assinar digitalmente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
            .modifier(CertificateImportModifier(importer: importer) { reload(select: $0) })
            .alert("Nível 1 em PDF com vários campos de assinatura?", isPresented: $askLevelOne) {
                Button("Voltar", role: .cancel) {}
                Button("Assinar no nível 1", role: .destructive) { start() }
            } message: {
                Text("Este PDF tem \(fieldCount) campos de assinatura. No nível 1, depois da sua assinatura ninguém mais poderá assinar os outros campos sem invalidar a sua. Para os outros poderem assinar, use o nível 2.")
            }
        }
        .interactiveDismissDisabled(working)
        .onAppear { reload(select: nil); loadLevel() }
    }

    private var fieldCount: Int {
        if case .fields(let n) = why { return n }
        return 0
    }

    @ViewBuilder private var levelSection: some View {
        Section {
            if why == .signed {
                Text(lockedLevel.map { "O nível de proteção foi definido pela primeira assinatura (\($0.title.components(separatedBy: ":")[0].lowercased())) e não muda mais." }
                     ?? "O nível de proteção foi definido pela primeira assinatura e não muda mais.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Picker("Nível", selection: $level) {
                    ForEach(ProtectionLevel.allCases) { Text($0.title).tag($0) }
                }
                if fieldCount > 1 {
                    Text("Este PDF tem \(fieldCount) campos de assinatura: o Prumo escolheu o nível 2, para os outros signatários ainda poderem assinar. Você pode mudar para o nível 1 ou 3.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.orange)
                }
                Text(level.explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
        } header: {
            Text("Proteção do documento")
        }
    }

    private func loadLevel() {
        guard let data = try? Data(contentsOf: item.url) else { return }
        let r = ProtectionLevel.offered(for: data, preferred: ProtectionLevel.saved)
        why = r.why
        lockedLevel = r.level
        if why != .signed, let l = r.level { level = l }
    }

    private var warning: String {
        if already > 0 {
            let n = already == 1 ? "1 assinatura" : "\(already) assinaturas"
            return "Este PDF já tem \(n). A nova assinatura entra no próprio arquivo, sem mudar o conteúdo: as anteriores continuam válidas. O PDF continua sem poder ser alterado."
        }
        return "Depois de assinado, o PDF não pode mais ser alterado: qualquer mudança (destaque, corte, numeração, páginas) invalida a assinatura. Por isso o Prumo assina uma cópia, “\(item.name)\(PDFSigner.suffix)”, e o original continua como está."
    }

    private func reload(select id: String?) {
        certs = CertificateStore.all()
        if let id, certs.contains(where: { $0.id == id }) {
            selected = id
        } else if cert == nil {
            selected = certs.first(where: { !$0.expired })?.id ?? certs.first?.id ?? ""
        }
    }

    private func sign() {
        if why != .signed, fieldCount > 1, level == .noChanges {
            askLevelOne = true
        } else {
            start()
        }
    }

    private func start() {
        guard let c = cert else { return }
        UserDefaults.standard.set(stamp, forKey: "signStamp")
        UserDefaults.standard.set(page.rawValue, forKey: "signPage")
        UserDefaults.standard.set(position.rawValue, forKey: "signPosition")
        let options = SignOptions(stamp: stamp, page: page, position: position,
                                  reason: reason.trimmingCharacters(in: .whitespaces),
                                  level: why == .signed ? .standard : level)
        working = true
        Task {
            defer { working = false }
            var confirmed = true
            if !DemoSeeder.isActive { confirmed = await SignConfirmation.confirm() }
            guard confirmed else { return }
            do {
                let result = try await library.sign(item, with: c, options: options)
                dismiss()
                flow.toast("PDF assinado: \(result.name)", actionTitle: "Abrir") { flow.open(.document(result.id)) }
            } catch {
                flow.show(error: error)
            }
        }
    }
}

/// Escolher o arquivo do certificado e digitar a senha.
@MainActor
final class CertificateImporter: ObservableObject {
    @Published var picking = false
    @Published var askPassword = false
    @Published var password = ""
    var data: Data?

    func start() { picking = true }
}

struct CertificateImportModifier: ViewModifier {
    @ObservedObject var importer: CertificateImporter
    let onImported: (String) -> Void
    @EnvironmentObject private var flow: AppFlow

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $importer.picking, allowedContentTypes: [.pkcs12, .data]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    importer.data = try Data(contentsOf: url)
                    importer.password = ""
                    importer.askPassword = true
                } catch {
                    flow.show(error: error)
                }
            }
            .alert("Senha do certificado", isPresented: $importer.askPassword) {
                SecureField("Senha", text: $importer.password)
                Button("Cancelar", role: .cancel) { importer.data = nil }
                Button("Adicionar") { add() }
            } message: {
                Text("A senha só serve para abrir o arquivo agora: o certificado vai para as Chaves do iPhone, só neste aparelho, e a senha não fica gravada.")
            }
    }

    private func add() {
        guard let data = importer.data else { return }
        importer.data = nil
        do {
            let c = try CertificateStore.importP12(data, password: importer.password)
            importer.password = ""
            flow.toast("Certificado adicionado: \(c.name)" + (c.expired ? " (vencido)" : ""))
            onImported(c.id)
        } catch {
            importer.password = ""
            flow.show(error: error)
        }
    }
}

/// Seção "Assinatura digital" dos Ajustes: certificados guardados, adicionar e remover.
struct CertificatesCard: View {
    @State private var certs: [SigningCertificate] = []
    @StateObject private var importer = CertificateImporter()
    @State private var removing: SigningCertificate?

    var body: some View {
        TileCard {
            VStack(alignment: .leading, spacing: 10) {
                if certs.isEmpty {
                    Label("Nenhum certificado A1 neste iPhone", systemImage: "signature")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                } else {
                    ForEach(certs) { c in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                                Text("Emitido por \(c.issuer) · válido até \(c.certificate.notAfter.formatted(date: .numeric, time: .omitted))" + (c.expired ? " · VENCIDO" : ""))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(c.expired ? Theme.red : Theme.secondaryText)
                            }
                            Spacer()
                            Button(role: .destructive) { removing = c } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Remover o certificado de \(c.name)")
                        }
                    }
                }
                Button("Adicionar certificado A1 (.pfx ou .p12)…") { importer.start() }
                    .buttonStyle(.bordered)
                    .font(.system(size: 15, weight: .semibold))
                Text("O certificado fica nas Chaves do iPhone, só neste aparelho (não vai para o iCloud nem para backups). A senha do arquivo não é gravada; cada assinatura pede o Face ID ou o código. Certificado A3 (token ou cartão) não funciona no iPhone: use o Prumo para Windows, que liga o token pelo Windows.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .modifier(CertificateImportModifier(importer: importer) { _ in certs = CertificateStore.all() })
        .confirmationDialog("Remover o certificado?", isPresented: Binding(get: { removing != nil },
                                                                          set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { c in
            Button("Remover", role: .destructive) {
                CertificateStore.remove(c)
                certs = CertificateStore.all()
            }
            Button("Cancelar", role: .cancel) {}
        } message: { c in
            Text("O certificado de \(c.name) sai deste iPhone. O arquivo .pfx que você tem continua onde estava, e os PDFs já assinados continuam válidos.")
        }
        .onAppear { certs = CertificateStore.all() }
    }
}

/// Ajustes: nível de proteção padrão da assinatura (DocMDP) e o que cada nível significa.
struct SignLevelCard: View {
    @AppStorage("signLevel") private var raw = ProtectionLevel.standard.rawValue

    private var level: ProtectionLevel { ProtectionLevel(rawValue: raw) ?? .standard }

    var body: some View {
        TileCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Nível padrão ao assinar")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Picker("Nível padrão", selection: $raw) {
                    ForEach(ProtectionLevel.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
                Text(level.explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                Text("O nível vale para a primeira assinatura do PDF (assinatura de certificação, DocMDP) e depois não muda. Na hora de assinar, dá para trocar o nível daquele PDF. PDF com mais de um campo de assinatura usa o nível 2 automaticamente, e o Prumo confirma com você antes de assinar. Nenhum nível impede que outro programa grave uma alteração no arquivo: o que muda é que a assinatura deixa de valer (ou é marcada como alterada), e leitores como o Adobe Acrobat avisam. Por isso o Prumo assina uma cópia (“Nome - assinado”), mantém o original editável e desliga as ferramentas de edição na cópia.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

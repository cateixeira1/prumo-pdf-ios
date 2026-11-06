import SwiftUI

/// Comprimir PDF: cópia menor ("Nome - comprimido"), em compressão média ou alta. O original não muda.
struct CompressSheet: View {
    let item: PDFItem
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var flow: AppFlow
    @Environment(\.dismiss) private var dismiss
    @AppStorage("compressLevel") private var saved = CompressionLevel.medium.rawValue
    @State private var level: CompressionLevel = .medium
    @State private var working = false
    @State private var alreadyCompact = false

    static func title(_ l: CompressionLevel) -> String {
        l == .medium ? L("Compressão média") : L("Compressão alta")
    }

    static func summary(_ l: CompressionLevel) -> String {
        l == .medium ? L("Preserva melhor a qualidade. O arquivo fica menor, mas reduz menos.")
            : L("Reduz bastante o tamanho do arquivo, sacrificando a qualidade das imagens.")
    }

    static func note(_ l: CompressionLevel) -> String {
        l == .medium
            ? L("Imagens com mais de 150 dpi são reduzidas para 150 dpi. Fica bom para ler na tela e para imprimir. Texto, destaques e o texto do OCR não mudam.")
            : L("Atenção: fotos e páginas escaneadas perdem nitidez (imagens reduzidas para 96 dpi). Letras pequenas podem ficar borradas ao ampliar ou imprimir. Use para enviar por e-mail ou anexar onde há limite de tamanho. Texto, destaques e o texto do OCR não mudam.")
    }

    var body: some View {
        NavigationStack {
            Screen {
                TileCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: "“\(item.name)”").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(verbatim: LF("Tamanho atual: {}", item.size.fileSizeText))
                            .font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                        ForEach(CompressionLevel.allCases) { l in
                            Button { level = l } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: level == l ? "largecircle.fill.circle" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundStyle(level == l ? Theme.teal : Theme.secondaryText)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(verbatim: CompressSheet.title(l))
                                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                                        Text(verbatim: CompressSheet.summary(l))
                                            .font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(level == l ? .isSelected : [])
                            .padding(.top, 4)
                        }
                        Text(verbatim: CompressSheet.note(level))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(level == .high ? Theme.orange : Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                        Text(verbatim: L("O original não muda: o Prumo cria uma cópia comprimida na mesma pasta."))
                            .font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                    }
                }
                PrimaryButton(title: L("Comprimir"), color: Theme.teal, enabled: !working) { run() }
            }
            .navigationTitle(L("Comprimir PDF"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
            .alert(L("O PDF já está compacto"), isPresented: $alreadyCompact) {
                Button("OK") { dismiss() }
            } message: {
                Text(verbatim: L("Não foi possível reduzir o tamanho deste PDF. Ele provavelmente já tem imagens em resolução baixa ou quase só texto. Nenhuma cópia foi criada."))
            }
        }
        .onAppear { level = CompressionLevel(rawValue: saved) ?? .medium }
    }

    private func run() {
        saved = level.rawValue
        working = true
        let chosen = level
        flow.busyMessage = L("Comprimindo…")
        Task {
            defer {
                working = false
                flow.busyMessage = nil
            }
            do {
                if let done = try await library.compressedCopy(item, level: chosen) {
                    let (new, result) = done
                    dismiss()
                    let pct = Int((result.savedRatio * 100).rounded())
                    flow.toast(LF("PDF comprimido: {} → {} ({}% menor)", Int64(result.before).fileSizeText,
                                  Int64(result.after).fileSizeText, pct),
                               actionTitle: L("Abrir")) { flow.open(.document(new.id)) }
                } else {
                    alreadyCompact = true
                }
            } catch {
                dismiss()
                flow.show(error: error)
            }
        }
    }
}

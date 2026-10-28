import Foundation
import PDFKit
import UIKit

/// Dados de demonstração usados só nas capturas de tela automáticas (argumento "-demo").
/// No app instalado, sem esse argumento, nada aqui é executado.
enum DemoSeeder {
    static var isActive: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-demo")
        #else
        return false
        #endif
    }

    static var startScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static var pendingDetailAction: String?
    private static var pendingSearch: String?
    private static var pendingPickerSource: String?
    private static var pendingHomeTool: String?

    static func consumeHomeTool() -> String? {
        defer { pendingHomeTool = nil }
        return pendingHomeTool
    }

    static func consumeSearch() -> String? {
        defer { pendingSearch = nil }
        return pendingSearch
    }

    static func consumePickerSource() -> String? {
        defer { pendingPickerSource = nil }
        return pendingPickerSource
    }

    /// Ação a executar quando a tela do documento abrir (ex.: abrir "Dividir").
    static func consumeDetailAction() -> String? {
        defer { pendingDetailAction = nil }
        return pendingDetailAction
    }

    @MainActor
    static func seed(library: Library) {
        #if DEBUG
        library.wipeEverything()
        for folder in ["Processos", "Laudos e prontuários", "Clientes", "Contratos"] {
            try? library.createFolder(named: folder)
        }
        try? library.createFolder(named: "Indenização - Hospital", in: "Processos")

        func save(_ data: Data, _ name: String, _ folder: String, _ configure: (inout DocMeta) -> Void = { _ in }) {
            let url = library.uniqueURL(folder: folder, baseName: name)
            try? data.write(to: url)
            library.reload()
            if let item = library.item(path: library.relativePath(of: url)) {
                if item.meta.favorite == false {
                    var meta = item.meta
                    configure(&meta)
                    if meta.favorite { library.setFavorite(item, true) }
                    if meta.pendingOCR { library.setPendingOCR(item, true) }
                }
            }
        }

        save(digitalPDF(title: "PETIÇÃO INICIAL", pages: 14), "Petição inicial - indenização", "Processos/Indenização - Hospital") { $0.favorite = true }
        save(digitalPDF(title: "CONTESTAÇÃO", pages: 22), "Contestação do hospital", "Processos/Indenização - Hospital")
        save(digitalPDF(title: "DECISÃO", pages: 3), "Decisão - tutela de urgência", "Processos")
        save(scannedPDF(pages: 6), "Prontuário médico", "Laudos e prontuários") { $0.pendingOCR = true }
        save(digitalPDF(title: "LAUDO PERICIAL", pages: 9), "Laudo pericial", "Laudos e prontuários")
        save(scannedPDF(pages: 2), "Procuração assinada", "Clientes")
        save(scannedPDF(pages: 3), "Documentos pessoais", "Clientes")
        save(digitalPDF(title: "CONTRATO DE HONORÁRIOS", pages: 5), "Contrato de honorários", "Contratos") { $0.favorite = true }
        save(scannedPDF(pages: 2), ScanService.defaultName(date: Date().addingTimeInterval(-3600)), "") { $0.pendingOCR = true }
        library.reload()
        #endif
    }

    @MainActor
    static func applyStartScreen(library: Library, flow: AppFlow, jobs: JobCenter) {
        #if DEBUG
        guard let screen = startScreen else { return }
        let prontuario = library.items.first { $0.name == "Prontuário médico" }
        let peticao = library.items.first { $0.name == "Petição inicial - indenização" }
        switch screen {
        case "all": flow.path = [.list(.all)]
        case "pending": flow.path = [.list(.pendingOCR)]
        case "folders": flow.path = [.folders]
        case "folder": flow.path = [.folders, .folder("Processos")]
        case "detail":
            if let p = peticao { flow.path = [.document(p.id)] }
        case "organize":
            if let p = peticao { flow.path = [.document(p.id), .organize(p.id)] }
        case "split":
            if let p = peticao {
                pendingDetailAction = "split"
                flow.path = [.document(p.id)]
            }
        case "reader":
            if let p = peticao { flow.path = [.document(p.id), .reader(p.id)] }
        case "settings": flow.path = [.settings]
        case "tools": pendingHomeTool = "organize"
        case "convert": pendingHomeTool = "convert"
        case "addfolder":
            flow.pendingAddToFolder = "Contratos"
            flow.path = [.folders, .folder("Contratos")]
        case "merge":
            flow.mergePreselection = library.items.filter { $0.folder.hasPrefix("Processos") }.map(\.id)
            flow.path = [.merge]
        case "ocrprompt":
            if let p = prontuario { flow.askOCRItemID = p.id }
        case "ocr":
            if let p = prontuario {
                flow.path = [.document(p.id)]
                jobs.startOCR(p, library: library, flow: flow)
            }
        case "search":
            pendingSearch = "sepse"
        case "readertext", "readchoice":
            // Faz um OCR de verdade para mostrar o modo leitor com texto reconhecido.
            guard let proc = library.items.first(where: { $0.name == "Procuração assinada" }) else { break }
            let out = library.newTempURL()
            let input = proc.url
            Task { @MainActor in
                let report = try? await Task.detached {
                    try await OCRService().run(input: input, output: out) { _, _ in }
                }.value
                guard let report, let result = try? library.adopt(fileAt: out, name: "\(proc.name) - OCR", folder: proc.folder) else { return }
                library.updateAfterOCR(original: proc, result: result, report: report)
                if screen == "readertext" {
                    flow.path = [.document(result.id), .reader(result.id, mode: .text)]
                } else {
                    pendingDetailAction = "readchoice"
                    flow.path = [.document(result.id)]
                }
            }
        case "picker":
            if let p = prontuario, let source = peticao {
                pendingDetailAction = "picker"
                pendingPickerSource = source.id
                flow.path = [.document(p.id)]
            }
        default:
            break
        }
        #endif
    }

    // MARK: - Geração dos PDFs de exemplo

    static let paragraphs = [
        "Excelentíssimo Senhor Doutor Juiz de Direito da Vara Cível do Foro Central da Comarca de São Paulo.",
        "A autora, devidamente qualificada nos autos, vem, respeitosamente, à presença de Vossa Excelência, por intermédio de seu advogado, propor a presente ação de indenização por danos materiais e morais em face do hospital réu, pelos fatos e fundamentos a seguir expostos.",
        "Em 12 de março de 2025, a autora foi internada para realização de procedimento cirúrgico eletivo. Após a cirurgia, apresentou febre persistente, dor abdominal intensa e alteração dos sinais vitais, sem que a equipe médica adotasse as providências diagnósticas necessárias.",
        "O prontuário demonstra que a reavaliação ocorreu somente 36 horas depois, quando já havia sinais de sepse. A demora no diagnóstico configura falha na prestação do serviço, nos termos do art. 14 do Código de Defesa do Consumidor.",
        "Diante do exposto, requer a condenação do réu ao pagamento de R$ 150.000,00 a título de danos morais, além do ressarcimento das despesas comprovadas, no valor de R$ 23.478,90.",
    ]

    static func digitalPDF(title: String, pages: Int) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            for n in 1...pages {
                ctx.beginPage()
                var y: CGFloat = 70
                let titleAttrs: [NSAttributedString.Key: Any] = [.font: UIFont(name: "TimesNewRomanPS-BoldMT", size: 15) ?? UIFont.boldSystemFont(ofSize: 15)]
                let heading = n == 1 ? title : "\(title) — continuação"
                heading.draw(at: CGPoint(x: 70, y: y), withAttributes: titleAttrs)
                y += 40
                let style = NSMutableParagraphStyle()
                style.alignment = .justified
                style.lineSpacing = 4
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont(name: "TimesNewRomanPSMT", size: 12) ?? UIFont.systemFont(ofSize: 12),
                                                            .paragraphStyle: style]
                for p in paragraphs {
                    let text = NSAttributedString(string: p, attributes: attrs)
                    let rect = text.boundingRect(with: CGSize(width: 455, height: 400), options: [.usesLineFragmentOrigin], context: nil)
                    text.draw(with: CGRect(x: 70, y: y, width: 455, height: rect.height + 4), options: [.usesLineFragmentOrigin], context: nil)
                    y += rect.height + 16
                }
                "Página \(n) de \(pages)".draw(at: CGPoint(x: 270, y: 790), withAttributes: [.font: UIFont.systemFont(ofSize: 9)])
            }
        }
    }

    /// Simula páginas escaneadas: texto transformado em imagem levemente torta.
    static func scannedPDF(pages: Int) -> Data {
        var images: [UIImage] = []
        for n in 1...pages {
            images.append(scanImage(page: n))
        }
        return ScanService.makePDF(from: images)
    }

    static func scanImage(page: Int, size: CGSize = CGSize(width: 1240, height: 1754)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.97, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.cgContext.rotate(by: CGFloat(page % 2 == 0 ? 0.6 : -0.4) * .pi / 180)
            ctx.cgContext.translateBy(x: -size.width / 2, y: -size.height / 2)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "TimesNewRomanPSMT", size: 26) ?? UIFont.systemFont(ofSize: 26),
                .foregroundColor: UIColor(white: 0.12, alpha: 1),
            ]
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "TimesNewRomanPS-BoldMT", size: 32) ?? UIFont.boldSystemFont(ofSize: 32),
                .foregroundColor: UIColor(white: 0.1, alpha: 1),
            ]
            "PRONTUÁRIO MÉDICO — FOLHA \(page)".draw(at: CGPoint(x: 140, y: 140), withAttributes: titleAttrs)
            var y: CGFloat = 230
            for p in paragraphs.dropFirst() {
                let text = NSAttributedString(string: p, attributes: attrs)
                let rect = text.boundingRect(with: CGSize(width: 960, height: 600), options: [.usesLineFragmentOrigin], context: nil)
                text.draw(with: CGRect(x: 140, y: y, width: 960, height: rect.height + 4), options: [.usesLineFragmentOrigin], context: nil)
                y += rect.height + 36
            }
        }
        return image
    }
}

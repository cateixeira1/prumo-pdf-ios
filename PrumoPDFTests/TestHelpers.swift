import PDFKit
import UIKit
@testable import PrumoPDF

enum TestPDF {
    /// PDF digital com N páginas; cada página contém o marcador "MARCADOR-<prefixo>-<n>".
    static func digital(pages: Int, prefix: String = "A") -> PDFDocument {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            for n in 1...pages {
                ctx.beginPage()
                let text = "MARCADOR-\(prefix)-\(n) Este é um texto digital com bastante conteúdo para a página \(n)."
                text.draw(in: CGRect(x: 60, y: 80, width: 470, height: 200),
                          withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            }
        }
        return PDFDocument(data: data)!
    }

    static func markers(_ doc: PDFDocument, prefix: String = "A") -> [String] {
        (0..<doc.pageCount).map { i in
            let s = doc.page(at: i)?.string ?? ""
            guard let r = s.range(of: "MARCADOR-[A-Z]+-[0-9]+", options: .regularExpression) else { return "?" }
            return String(s[r])
        }
    }

    static let sampleLines = [
        "EXCELENTÍSSIMO SENHOR DOUTOR JUIZ DE DIREITO",
        "A autora propõe a presente ação de indenização",
        "por danos materiais e morais em face do hospital réu.",
        "O prontuário demonstra a demora no diagnóstico.",
        "Valor da causa: R$ 150.000,00 em 12 de março de 2025.",
    ]

    /// Imagem de uma página "escaneada" com texto em português.
    static func scanImage(lines: [String] = sampleLines, size: CGSize = CGSize(width: 1240, height: 1754)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "TimesNewRomanPSMT", size: 34) ?? UIFont.systemFont(ofSize: 34),
                .foregroundColor: UIColor.black,
            ]
            var y: CGFloat = 160
            for line in lines {
                line.draw(at: CGPoint(x: 110, y: y), withAttributes: attrs)
                y += 70
            }
        }
    }

    static func scanned(pages: Int) -> PDFDocument {
        PDFDocument(data: ScanService.makePDF(from: (0..<pages).map { _ in scanImage() }))!
    }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prumo-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

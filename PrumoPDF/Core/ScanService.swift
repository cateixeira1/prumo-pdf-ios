import PDFKit
import UIKit
import VisionKit

/// Transforma imagens escaneadas em PDF.
enum ScanService {
    /// Lado maior das imagens guardadas no PDF. 3000 px mantém boa qualidade para OCR.
    static let maxLongSide: CGFloat = 3000
    static let jpegQuality: CGFloat = 0.8

    /// Largura das páginas em pontos (A4 = 595 x 842). A altura acompanha a proporção da foto.
    static let portraitWidth: CGFloat = 595.28
    static let landscapeWidth: CGFloat = 841.89

    static func makePDF(from scan: VNDocumentCameraScan) -> Data {
        makePDF(count: scan.pageCount) { scan.imageOfPage(at: $0) }
    }

    static func makePDF(from images: [UIImage]) -> Data {
        makePDF(count: images.count) { images[$0] }
    }

    /// Processa uma imagem por vez para economizar memória.
    static func makePDF(count: Int, image: (Int) -> UIImage) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: portraitWidth, height: 842))
        return renderer.pdfData { ctx in
            for i in 0..<count {
                autoreleasepool {
                    guard let prepared = prepare(image(i)) else { return }
                    let size = prepared.size
                    let pageWidth = size.width > size.height ? landscapeWidth : portraitWidth
                    let pageHeight = pageWidth * size.height / size.width
                    let rect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
                    ctx.beginPage(withBounds: rect, pageInfo: [:])
                    prepared.draw(in: rect)
                }
            }
        }
    }

    /// Endireita a orientação, reduz se for muito grande e comprime em JPEG.
    /// A imagem resultante é criada a partir do JPEG, para que o PDF guarde o JPEG
    /// em vez de uma imagem sem compressão.
    static func prepare(_ image: UIImage) -> UIImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let pixelW = size.width * image.scale
        let pixelH = size.height * image.scale
        let factor = min(1, maxLongSide / max(pixelW, pixelH))
        let target = CGSize(width: (pixelW * factor).rounded(), height: (pixelH * factor).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = normalized.jpegData(compressionQuality: jpegQuality),
              let provider = CGDataProvider(data: jpeg as CFData),
              let cgImage = CGImage(jpegDataProviderSource: provider, decode: nil,
                                    shouldInterpolate: true, intent: .defaultIntent) else {
            return normalized
        }
        return UIImage(cgImage: cgImage)
    }

    static var scannerAvailable: Bool { VNDocumentCameraViewController.isSupported }

    static func defaultName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "dd-MM-yyyy HH'h'mm"
        return "Escaneado \(f.string(from: date))"
    }
}

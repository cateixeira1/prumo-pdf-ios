import CoreML
import PDFKit
import UIKit
import Vision

/// Correção de páginas curvas (lombada de livro, papel ondulado ou dobrado) em fotos.
///
/// Usa o modelo UVDoc (Verhoeven, Magne e Sorkine-Hornung, SIGGRAPH Asia 2023; código e modelo
/// sob licença MIT, github.com/tanguymagne/UVDoc), convertido para Core ML e rodando no iPhone.
/// O modelo olha a foto reduzida (488 × 712) e devolve uma grade de 45 × 31 pontos que diz de
/// onde vem cada parte da página "desentortada". A foto original é redesenhada com essa grade,
/// em resolução cheia (o mesmo método da versão para Windows).
enum Dewarp {
    static let rows = 45
    static let cols = 31

    private static var cachedModel: VNCoreMLModel?

    static var isAvailable: Bool { Bundle.main.url(forResource: "UVDoc", withExtension: "mlmodelc") != nil }

    private static func model() throws -> VNCoreMLModel {
        if let m = cachedModel { return m }
        guard let url = Bundle.main.url(forResource: "UVDoc", withExtension: "mlmodelc") else {
            throw UserFacingError("O modelo de correção de curvatura não está no app.")
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let m = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
        cachedModel = m
        return m
    }

    /// Imagem já na orientação certa (sem depender do EXIF), como CGImage.
    static func upright(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    /// Grade 2 × 45 × 31 em coordenadas normalizadas (-1 a 1): primeiro os x, depois os y.
    static func predictGrid(_ cg: CGImage) throws -> [Float] {
        let request = VNCoreMLRequest(model: try model())
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        guard let obs = request.results?.first as? VNCoreMLFeatureValueObservation,
              let array = obs.featureValue.multiArrayValue else {
            throw UserFacingError("O modelo não devolveu a grade da página.")
        }
        let count = 2 * rows * cols
        guard array.count >= count else { throw UserFacingError("Grade da página com tamanho inesperado.") }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count { out[i] = array[i].floatValue }
        return out
    }

    /// Redesenha a imagem seguindo a grade (interpolação bilinear da grade e dos pixels).
    static func remap(_ cg: CGImage, grid: [Float]) -> CGImage? {
        let w = cg.width, h = cg.height
        guard w > 1, h > 1 else { return cg }
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let srcCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: space, bitmapInfo: info),
              let dstCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: space, bitmapInfo: info) else { return nil }
        srcCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let src = srcCtx.data?.assumingMemoryBound(to: UInt8.self),
              let dst = dstCtx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let plane = rows * cols
        let fw = Float(w - 1), fh = Float(h - 1)
        let rowScale = Float(rows - 1) / fh, colScale = Float(cols - 1) / fw
        grid.withUnsafeBufferPointer { g in
            for y in 0..<h {
                let gv = Float(y) * rowScale
                let i0 = min(Int(gv), rows - 2)
                let fv = gv - Float(i0)
                for x in 0..<w {
                    let gu = Float(x) * colScale
                    let j0 = min(Int(gu), cols - 2)
                    let fu = gu - Float(j0)
                    let a = i0 * cols + j0, b = a + 1, c = a + cols, d = c + 1
                    let gx = (g[a] * (1 - fu) + g[b] * fu) * (1 - fv) + (g[c] * (1 - fu) + g[d] * fu) * fv
                    let gy = (g[plane + a] * (1 - fu) + g[plane + b] * fu) * (1 - fv)
                        + (g[plane + c] * (1 - fu) + g[plane + d] * fu) * fv
                    let sx = (gx + 1) * 0.5 * fw
                    let sy = (gy + 1) * 0.5 * fh
                    let o = (y * w + x) * 4
                    if sx < 0 || sy < 0 || sx > fw || sy > fh {
                        dst[o] = 255; dst[o + 1] = 255; dst[o + 2] = 255; dst[o + 3] = 255
                        continue
                    }
                    let x0 = min(Int(sx), w - 2), y0 = min(Int(sy), h - 2)
                    let tx = sx - Float(x0), ty = sy - Float(y0)
                    let p00 = (y0 * w + x0) * 4, p01 = p00 + 4, p10 = p00 + w * 4, p11 = p10 + 4
                    for ch in 0..<3 {
                        let top = Float(src[p00 + ch]) * (1 - tx) + Float(src[p01 + ch]) * tx
                        let bottom = Float(src[p10 + ch]) * (1 - tx) + Float(src[p11 + ch]) * tx
                        dst[o + ch] = UInt8(max(0, min(255, (top * (1 - ty) + bottom * ty).rounded())))
                    }
                    dst[o + 3] = 255
                }
            }
        }
        return dstCtx.makeImage()
    }

    /// Foto com a página corrigida (mesmo tamanho da original).
    static func unwarp(_ image: UIImage) throws -> UIImage {
        guard let cg = upright(image) else { throw UserFacingError("Não foi possível ler a imagem.") }
        let grid = try predictGrid(cg)
        guard let out = remap(cg, grid: grid) else { throw UserFacingError("Não foi possível corrigir a imagem.") }
        return UIImage(cgImage: out)
    }

    // MARK: - PDFs

    /// Imagem de uma página do PDF, a cerca de 200 dpi.
    static func render(_ page: PDFPage, dpi: CGFloat = 200) -> UIImage {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
    }

    /// Novo PDF com as páginas escolhidas (começando em 1) corrigidas; as outras ficam intactas.
    static func dewarpPDF(_ source: PDFDocument, pages: [Int], progress: ((Int, Int) -> Void)? = nil) throws -> Data {
        guard let out = PDFDocument(data: source.dataRepresentation() ?? Data()) else {
            throw UserFacingError("Não foi possível ler o PDF.")
        }
        let chosen = Array(Set(pages)).sorted()
        for (k, n) in chosen.enumerated() {
            progress?(k + 1, chosen.count)
            try autoreleasepool {
                guard let page = out.page(at: n - 1) else { return }
                let bounds = page.bounds(for: .mediaBox)
                let fixed = try unwarp(render(page))
                let jpeg = fixed.jpegData(compressionQuality: 0.88).flatMap { UIImage(data: $0) } ?? fixed
                guard let newPage = PDFPage(image: jpeg, options: [.mediaBox: bounds, .upscaleIfSmaller: true]) else {
                    throw UserFacingError("Não foi possível montar a página \(n).")
                }
                out.removePage(at: n - 1)
                out.insert(newPage, at: n - 1)
            }
        }
        guard let data = out.dataRepresentation() else { throw UserFacingError("Não foi possível gravar o PDF.") }
        return data
    }
}

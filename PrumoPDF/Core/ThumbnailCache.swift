import PDFKit
import UIKit

/// Miniaturas de páginas. Todo acesso ao PDFKit acontece numa fila única, em segundo plano.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "br.com.prumopdf.thumbnails", qos: .userInitiated)
    // Acessados somente dentro de `queue`.
    private var openDocs: [String: PDFDocument] = [:]
    private var openOrder: [String] = []

    init() {
        cache.countLimit = 400
    }

    private func key(_ url: URL, _ version: String, _ page: Int, _ pixelWidth: Int) -> NSString {
        "\(url.path)|\(version)|\(page)|\(pixelWidth)" as NSString
    }

    /// Arredonda o tamanho para reaproveitar miniaturas parecidas.
    private func bucket(_ pixelWidth: CGFloat) -> Int {
        let steps = [120, 200, 320, 480, 720, 1000, 1400]
        let w = Int(pixelWidth)
        return steps.first { $0 >= w } ?? steps.last!
    }

    func cached(url: URL, version: String, page: Int, pixelWidth: CGFloat) -> UIImage? {
        cache.object(forKey: key(url, version, page, bucket(pixelWidth)))
    }

    func load(url: URL, version: String, page: Int, pixelWidth: CGFloat,
              completion: @escaping (UIImage?) -> Void) {
        let width = bucket(pixelWidth)
        let k = key(url, version, page, width)
        if let img = cache.object(forKey: k) {
            completion(img)
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let image: UIImage? = autoreleasepool {
                guard let doc = self.document(url: url, version: version),
                      let pdfPage = doc.page(at: page) else { return nil }
                let bounds = pdfPage.bounds(for: .cropBox)
                let rotated = pdfPage.rotation % 180 != 0
                let aspect = rotated ? bounds.width / max(bounds.height, 1) : bounds.height / max(bounds.width, 1)
                let size = CGSize(width: CGFloat(width), height: CGFloat(width) * max(aspect, 0.1))
                return pdfPage.thumbnail(of: size, for: .cropBox)
            }
            if let image { self.cache.setObject(image, forKey: k) }
            DispatchQueue.main.async { completion(image) }
        }
    }

    func image(url: URL, version: String, page: Int, pixelWidth: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            load(url: url, version: version, page: page, pixelWidth: pixelWidth) { continuation.resume(returning: $0) }
        }
    }

    /// Esquece documentos abertos de um arquivo que mudou.
    func invalidate(url: URL) {
        queue.async { [weak self] in
            guard let self else { return }
            let prefix = url.path + "|"
            for k in self.openDocs.keys where k.hasPrefix(prefix) {
                self.openDocs[k] = nil
            }
            self.openOrder.removeAll { $0.hasPrefix(prefix) }
        }
    }

    private func document(url: URL, version: String) -> PDFDocument? {
        let k = url.path + "|" + version
        if let doc = openDocs[k] { return doc }
        guard let doc = PDFDocument(url: url), !doc.isLocked else { return nil }
        openDocs[k] = doc
        openOrder.append(k)
        if openOrder.count > 4 {
            let old = openOrder.removeFirst()
            openDocs[old] = nil
        }
        return doc
    }
}

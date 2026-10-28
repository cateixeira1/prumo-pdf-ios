import PDFKit
import XCTest
@testable import PrumoPDF

/// Biblioteca numa pasta de nuvem usada por dois aparelhos (iPhone e Windows, ou dois iPhones).
@MainActor
final class SyncTests: XCTestCase {
    private func cloudFolder(with names: [String]) -> URL {
        let folder = TestPDF.tempDir().appendingPathComponent("Prumo PDF", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (i, n) in names.enumerated() {
            _ = TestPDF.digital(pages: i + 1, prefix: "S").write(to: folder.appendingPathComponent("\(n).pdf"))
        }
        return folder
    }

    private func favorites(_ lib: Library) -> Set<String> { Set(lib.items.filter { $0.meta.favorite }.map(\.name)) }

    private func later() { Thread.sleep(forTimeInterval: 0.05) }

    func testFavoritesAndOCRLinkReachTheOtherDevice() throws {
        let folder = cloudFolder(with: ["Contrato", "Laudo", "Recibo"])
        let phone = Library(baseDirectory: TestPDF.tempDir(), libraryFolder: folder)
        let other = Library(baseDirectory: TestPDF.tempDir(), libraryFolder: folder)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: phone.items.map { ($0.relativePath, $0.id) }),
                       Dictionary(uniqueKeysWithValues: other.items.map { ($0.relativePath, $0.id) }),
                       "os dois aparelhos usam os mesmos ids")
        phone.setFavorite(try XCTUnwrap(phone.item(path: "Contrato.pdf")), true)
        later()
        // O outro aparelho marca outro favorito sem ter recarregado: nenhum dos dois se perde.
        other.setFavorite(try XCTUnwrap(other.item(path: "Recibo.pdf")), true)
        later()
        phone.reload()
        XCTAssertEqual(favorites(phone), ["Contrato", "Recibo"])
        XCTAssertEqual(favorites(other), ["Contrato", "Recibo"])
        other.setFavorite(try XCTUnwrap(other.item(path: "Contrato.pdf")), false)
        later()
        phone.reload()
        XCTAssertEqual(favorites(phone), ["Recibo"])
    }

    func testReadsTheListWrittenByWindows() throws {
        let folder = cloudFolder(with: ["Laudo", "Laudo - OCR"])
        let meta = folder.appendingPathComponent(".prumo", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        // Como o Prumo para Windows grava (com campos que o iPhone não usa).
        let json = """
        [{"path": "Laudo.pdf", "id": "W1", "favorite": true, "pending_ocr": false, "is_ocr_result": false,
          "ocr_copy_id": "W2", "source_id": null, "text_status": "scanned", "page_count": 1, "added": 1.5},
         {"path": "Laudo - OCR.pdf", "id": "W2", "favorite": false, "is_ocr_result": true, "source_id": "W1",
          "ocr_copy_id": null, "review_pages": [1]}]
        """
        try Data(json.utf8).write(to: meta.appendingPathComponent("library.json"))
        let phone = Library(baseDirectory: TestPDF.tempDir(), libraryFolder: folder)
        let laudo = try XCTUnwrap(phone.item(path: "Laudo.pdf"))
        XCTAssertEqual(laudo.id, "W1")
        XCTAssertTrue(laudo.meta.favorite)
        XCTAssertEqual(laudo.meta.ocrCopyID, "W2")
        XCTAssertTrue(try XCTUnwrap(phone.item(path: "Laudo - OCR.pdf")).meta.isOCRResult)
        XCTAssertFalse(phone.needsOCRAttention(laudo))
    }

    func testFileStillOnTheWayKeepsItsEntry() throws {
        let folder = cloudFolder(with: ["Contrato"])
        let phone = Library(baseDirectory: TestPDF.tempDir(), libraryFolder: folder)
        let url = phone.sharedURL
        var rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        rows.append(["path": "Clientes/Novo.pdf", "id": "DO-WINDOWS", "favorite": true])
        try JSONSerialization.data(withJSONObject: rows).write(to: url)
        later()
        phone.setFavorite(try XCTUnwrap(phone.item(path: "Contrato.pdf")), true)
        let saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertTrue(saved.contains { $0["path"] as? String == "Clientes/Novo.pdf" }, "não apaga o que está chegando")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Clientes"), withIntermediateDirectories: true)
        _ = TestPDF.digital(pages: 2).write(to: folder.appendingPathComponent("Clientes/Novo.pdf"))
        phone.reload()
        let novo = try XCTUnwrap(phone.item(path: "Clientes/Novo.pdf"))
        XCTAssertEqual(novo.id, "DO-WINDOWS")
        XCTAssertTrue(novo.meta.favorite)
    }

    func testMovingTheLibraryToACloudFolder() throws {
        let base = TestPDF.tempDir()
        let lib = Library(baseDirectory: base)
        let src = base.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        _ = TestPDF.digital(pages: 2).write(to: src.appendingPathComponent("Petição.pdf"))
        _ = TestPDF.digital(pages: 3).write(to: src.appendingPathComponent("Laudo.pdf"))
        try lib.createFolder(named: "Clientes")
        let pet = try XCTUnwrap(lib.importFiles([src.appendingPathComponent("Petição.pdf")], into: "Clientes").first)
        _ = lib.importFiles([src.appendingPathComponent("Laudo.pdf")])
        lib.setFavorite(pet, true)

        // Na nuvem já há o mesmo Laudo (vindo do Windows) e outro PDF.
        let drive = TestPDF.tempDir().appendingPathComponent("iCloud Drive", isDirectory: true)
        let cloud = drive.appendingPathComponent("Prumo PDF", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src.appendingPathComponent("Laudo.pdf"), to: cloud.appendingPathComponent("Laudo.pdf"))
        _ = TestPDF.digital(pages: 1, prefix: "W").write(to: cloud.appendingPathComponent("Do Windows.pdf"))

        defer { _ = try? lib.useLocalStorage(bringCloud: false) }
        let r = try lib.useCloudFolder(drive, bringLocal: true)
        XCTAssertEqual(lib.root.standardizedFileURL, cloud.standardizedFileURL, "usa a subpasta Prumo PDF")
        XCTAssertFalse(lib.isLocal)
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.skipped, 1)
        XCTAssertEqual(Set(lib.items.map(\.relativePath)), ["Clientes/Petição.pdf", "Laudo.pdf", "Do Windows.pdf"])
        XCTAssertTrue(try XCTUnwrap(lib.item(path: "Clientes/Petição.pdf")).meta.favorite)
        let left = (FileManager.default.enumerator(atPath: lib.localRoot.path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".pdf") }
        XCTAssertEqual(left, [], "os PDFs saem do iPhone depois de chegarem à nuvem")
    }
}

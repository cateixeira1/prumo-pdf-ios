import PDFKit
import XCTest
@testable import PrumoPDF

@MainActor
final class LibraryTests: XCTestCase {
    var base: URL!
    var library: Library!

    /// Cada teste começa com uma biblioteca vazia numa pasta temporária.
    private func fresh() {
        if let base { try? FileManager.default.removeItem(at: base) }
        base = TestPDF.tempDir()
        library = Library(baseDirectory: base)
        UserDefaults.standard.removeObject(forKey: AppSettings.includeInBackupKey)
    }

    private func externalPDF(_ name: String, pages: Int = 3) -> URL {
        let url = base.appendingPathComponent(name)
        _ = TestPDF.digital(pages: pages).write(to: url)
        return url
    }

    func testImportFoldersRenameMoveDelete() throws {
        fresh()
        let imported = library.importFiles([externalPDF("Petição.pdf")])
        XCTAssertEqual(imported.count, 1)
        let item = try XCTUnwrap(imported.first)
        XCTAssertEqual(item.relativePath, "Petição.pdf")

        // Importar de novo gera um nome único.
        let again = library.importFiles([externalPDF("Petição.pdf")])
        XCTAssertEqual(again.first?.name, "Petição (2)")

        try library.createFolder(named: "Clientes")
        XCTAssertThrowsError(try library.createFolder(named: "Clientes"))
        try library.move([item], toFolder: "Clientes")
        let moved = try XCTUnwrap(library.item(id: item.id), "o id continua o mesmo depois de mover")
        XCTAssertEqual(moved.relativePath, "Clientes/Petição.pdf")

        library.setFavorite(moved, true)
        try library.renameFolder("Clientes", to: "Clientes 2026")
        let afterFolderRename = try XCTUnwrap(library.item(id: item.id))
        XCTAssertEqual(afterFolderRename.relativePath, "Clientes 2026/Petição.pdf")
        XCTAssertTrue(afterFolderRename.meta.favorite, "metadados acompanham a pasta renomeada")

        try library.rename(afterFolderRename, to: "Petição inicial")
        XCTAssertEqual(library.item(id: item.id)?.name, "Petição inicial")
        XCTAssertEqual(library.items(for: .favorites).map(\.id), [item.id])

        try library.delete([try XCTUnwrap(library.item(id: item.id))])
        XCTAssertNil(library.item(id: item.id))
    }

    func testMetadataSurvivesRestart() throws {
        fresh()
        let item = try XCTUnwrap(library.importFiles([externalPDF("A.pdf")]).first)
        library.setFavorite(item, true)
        library.setPendingOCR(item, true)
        let reopened = Library(baseDirectory: base)
        let same = try XCTUnwrap(reopened.item(id: item.id))
        XCTAssertTrue(same.meta.favorite)
        XCTAssertTrue(same.meta.pendingOCR)
        XCTAssertEqual(reopened.items(for: .pendingOCR).map(\.id), [item.id])
    }

    func testModifyAndUndo() async throws {
        fresh()
        let item = try XCTUnwrap(library.importFiles([externalPDF("Doc.pdf", pages: 4)]).first)
        try await library.modify(item) { doc in
            try PDFOps.remove(pages: [2, 3], from: doc)
        }
        XCTAssertEqual(try PDFOps.open(item.url).pageCount, 2)
        let changed = try XCTUnwrap(library.item(id: item.id))
        XCTAssertTrue(library.canUndo(changed))
        try library.undo(changed)
        XCTAssertEqual(try PDFOps.open(item.url).pageCount, 4)
        XCTAssertFalse(library.canUndo(try XCTUnwrap(library.item(id: item.id))))
    }

    func testSaveNewDocumentAndSplitNames() async throws {
        fresh()
        let doc = TestPDF.digital(pages: 9)
        let saved = try await library.save(newDocument: doc, name: "Processo", folder: "")
        XCTAssertEqual(saved.name, "Processo")
        for (i, part) in try PDFOps.split(doc, parts: 3).enumerated() {
            _ = try await library.save(newDocument: part, name: "Processo - Parte \(i + 1)", folder: "")
        }
        let names = library.items(inFolder: "").map(\.name)
        XCTAssertEqual(names, ["Processo", "Processo - Parte 1", "Processo - Parte 2", "Processo - Parte 3"])
    }

    func testBackupPreference() throws {
        fresh()
        let item = try XCTUnwrap(library.importFiles([externalPDF("B.pdf")]).first)
        XCTAssertFalse(BackupPolicy.isExcluded(item.url), "padrão: entra no backup")
        UserDefaults.standard.set(false, forKey: AppSettings.includeInBackupKey)
        BackupPolicy.applyAll(roots: [library.root])
        XCTAssertTrue(BackupPolicy.isExcluded(item.url))
        UserDefaults.standard.set(true, forKey: AppSettings.includeInBackupKey)
        BackupPolicy.applyAll(roots: [library.root])
        XCTAssertFalse(BackupPolicy.isExcluded(item.url))
    }

    func testSearchFindsAccentInsensitiveText() async throws {
        fresh()
        _ = library.importFiles([externalPDF("Contrato.pdf")])
        // Espera a análise em segundo plano terminar.
        for _ in 0..<50 where library.isAnalyzing {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(library.search("contrato").count, 1)
        XCTAssertEqual(library.search("CONTEUDO PARA A PAGINA").count, 1, "busca no texto, sem acentos")
        XCTAssertEqual(library.search("inexistente").count, 0)
    }
}

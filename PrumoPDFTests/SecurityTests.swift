import PDFKit
import XCTest
@testable import PrumoPDF

/// Senha no PDF e trava do app (versão 1.6.0).
@MainActor
final class SecurityTests: XCTestCase {
    func testProtectAndUnprotect() throws {
        let base = TestPDF.tempDir()
        let library = Library(baseDirectory: base)
        let src = base.appendingPathComponent("Laudo.pdf")
        _ = TestPDF.digital(pages: 3).write(to: src)
        let item = try XCTUnwrap(library.importFiles([src]).first)

        let locked = try library.protect(item, password: "Sigilo2026")
        XCTAssertEqual(locked.name, "Laudo - protegido")
        let doc = try XCTUnwrap(PDFDocument(url: locked.url))
        XCTAssertTrue(doc.isEncrypted)
        XCTAssertTrue(doc.isLocked, "sem a senha, não abre")
        XCTAssertFalse(doc.unlock(withPassword: "errada"))
        XCTAssertTrue(doc.unlock(withPassword: "Sigilo2026"))
        XCTAssertEqual(doc.pageCount, 3)

        // Qual criptografia a Apple usou (para registrar com precisão no LEIA-ME).
        let raw = try Data(contentsOf: locked.url)
        let text = String(decoding: raw, as: UTF8.self)
        if let r = text.range(of: "/Encrypt") {
            print("Criptografia PDFKit: \(text[r.lowerBound...].prefix(160))")
        }
        for key in ["/V 5", "/V 4", "/V 2", "/V 1", "/R 6", "/R 5", "/R 4", "/R 3", "/AESV3", "/AESV2", "/V2"] where text.contains(key) {
            print("Criptografia PDFKit: contém \(key)")
        }

        XCTAssertTrue(Library.checkPassword(locked.url, "Sigilo2026"))
        XCTAssertFalse(Library.checkPassword(locked.url, "sigilo2026"))
        XCTAssertThrowsError(try library.unprotect(locked, password: "errada"))
        let plain = try library.unprotect(locked, password: "Sigilo2026")
        XCTAssertEqual(plain.name, "Laudo (2)", "o nome volta ao original (com número, porque o original ainda existe)")
        let reopened = try XCTUnwrap(PDFDocument(url: plain.url))
        XCTAssertFalse(reopened.isEncrypted)
        XCTAssertEqual(reopened.pageCount, 3)
        XCTAssertTrue((reopened.string ?? "").contains("MARCADOR-A-1"), "o texto continua lá")
    }

    func testLockedPDFIsRecognized() throws {
        let base = TestPDF.tempDir()
        let src = base.appendingPathComponent("x.pdf")
        let doc = TestPDF.digital(pages: 2)
        XCTAssertTrue(doc.write(to: src, withOptions: [.userPasswordOption: "abc", .ownerPasswordOption: "abc"]))
        let analysis = try XCTUnwrap(Analyzer.analyze(url: src))
        XCTAssertTrue(analysis.locked)
    }
}

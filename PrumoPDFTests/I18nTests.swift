import PDFKit
import XCTest
@testable import PrumoPDF

/// Traduções (versão 1.12): todos os idiomas estão no app, os textos com parte variável e plural saem
/// certos, os nomes de cópia ("- resumo", "- protegido") são reconhecidos em qualquer idioma e o texto
/// gravado no PDF usa o idioma dos documentos. Os testes rodam com o app em português (ver project.yml);
/// os outros idiomas são lidos direto das pastas .lproj.
@MainActor
final class I18nTests: XCTestCase {
    private let others = ["en", "es", "fr", "de", "ja", "zh-Hans", "zh-Hant", "nb", "sv", "da", "fi"]

    private func strings(_ lproj: String, _ table: String = "Localizable") throws -> [String: String] {
        let path = try XCTUnwrap(Bundle.main.path(forResource: table, ofType: "strings", inDirectory: nil,
                                                  forLocalization: lproj), "\(table).strings em \(lproj)")
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
    }

    func testEveryLanguageIsInTheApp() throws {
        XCTAssertEqual(Bundle.main.developmentLocalization, "en", "idioma sem tradução → inglês")
        XCTAssertEqual(AppLanguages.current, "pt", "os testes rodam em português")
        for lproj in ["pt"] + others {
            XCTAssertTrue(Bundle.main.localizations.contains(lproj), lproj)
            let plist = try strings(lproj, "InfoPlist")
            XCTAssertNotNil(plist["NSCameraUsageDescription"], lproj)
            XCTAssertNotNil(plist["NSFaceIDUsageDescription"], lproj)
        }
        XCTAssertEqual(Set(AppLanguages.all.map(\.lproj)), Set(["pt"] + others))
    }

    func testCatalogsAreCompleteAndKeepPlaceholders() throws {
        let en = try strings("en")
        XCTAssertGreaterThan(en.count, 1000)
        for lproj in others {
            let cat = try strings(lproj)
            XCTAssertEqual(Set(cat.keys), Set(en.keys), "\(lproj): as mesmas chaves do inglês")
            for (k, v) in cat {
                XCTAssertEqual(k.components(separatedBy: "{}").count, v.components(separatedBy: "{}").count,
                               "\(lproj): \(k) → \(v)")
            }
            // textos que já ficavam em português no iPhone (modo leitor, avisos, menus)
            for key in ["Desfazer última alteração", "Adicionar ao resumo", "Modo leitor", "Opções de leitura",
                        "Ir para a página…", "Esconder as miniaturas", "Página {} de {}", "{} páginas",
                        "Abrir os Ajustes do iPhone", "Não foi possível abrir o PDF."] {
                let t = try XCTUnwrap(cat[key], "\(lproj): falta \(key)")
                if !["es", "fr"].contains(lproj) || !["Página {} de {}", "{} páginas"].contains(key) {
                    XCTAssertNotEqual(t, key, "\(lproj): \(key) continua em português")
                }
            }
        }
    }

    func testTemplatesAndPlurals() {
        XCTAssertEqual(fillTemplate("Página {} de {}", [2, 10]), "Página 2 de 10")
        XCTAssertEqual(fillTemplate("{} e {}", ["a"]), "a e ")
        XCTAssertEqual(LF("Página {} de {}", 3, 12), "Página 3 de 12")
        XCTAssertEqual(LN(1, "1 página", "{} páginas"), "1 página")
        XCTAssertEqual(LN(5, "1 página", "{} páginas"), "5 páginas")
        XCTAssertEqual(LN(1, "1 PDF importado para {}.", "{} PDFs importados para {}.", "Laudos"),
                       "1 PDF importado para Laudos.")
        XCTAssertEqual(LN(3, "1 PDF importado para {}.", "{} PDFs importados para {}.", "Laudos"),
                       "3 PDFs importados para Laudos.")
        XCTAssertEqual(sentences("PDF criado: X", L("Os de fotos estão em Sem OCR.")),
                       "PDF criado: X. Os de fotos estão em Sem OCR.")
        XCTAssertEqual(AppLanguages.translate("{} páginas", to: "de"), "{} Seiten")
        XCTAssertEqual(AppLanguages.translate("{} páginas", to: "pt"), "{} páginas")
    }

    func testCopyNamesAreRecognizedInAnyLanguage() {
        let names = AppLanguages.suffixedNames("Laudo", template: Summary.nameTemplate)
        XCTAssertEqual(names.first, "Laudo - resumo", "primeiro o idioma do app")
        XCTAssertTrue(names.contains("Laudo - summary"))
        XCTAssertTrue(names.contains("Laudo - Zusammenfassung"))
        XCTAssertEqual(AppLanguages.stripSuffix("Laudo - protected", template: "{} - protegido"), "Laudo")
        XCTAssertEqual(AppLanguages.stripSuffix("Laudo - protegido", template: "{} - protegido"), "Laudo")
        XCTAssertEqual(AppLanguages.stripSuffix("Laudo", template: "{} - protegido"), "Laudo")
        XCTAssertEqual(LF(PDFSigner.nameTemplate, "Contrato"), "Contrato - assinado")
        XCTAssertTrue(PageSelection.endWords.contains("fim"))
    }

    func testSummaryMadeInAnotherLanguageIsFound() throws {
        let base = TestPDF.tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let library = Library(baseDirectory: base)
        let src = base.appendingPathComponent("Laudo.pdf")
        let sum = base.appendingPathComponent("Laudo - summary.pdf")   // criado no Windows em inglês
        XCTAssertTrue(TestPDF.digital(pages: 2).write(to: src))
        XCTAssertTrue(TestPDF.digital(pages: 1, prefix: "R").write(to: sum))
        let items = library.importFiles([src, sum])
        let item = try XCTUnwrap(items.first { $0.name == "Laudo" })
        let found = try XCTUnwrap(Summary.find(in: library, for: item))
        XCTAssertEqual(found.name, "Laudo - summary")
        XCTAssertEqual(Summary.relativePath(for: item, in: library), found.relativePath)
    }

    func testDocumentLanguageForTextWrittenInPDFs() {
        XCTAssertEqual(AppLanguages.document, "pt")
        XCTAssertEqual(LD("Assinado digitalmente por"), "Assinado digitalmente por")
        XCTAssertEqual(AppLanguages.stampDateFormat, "dd/MM/yyyy HH:mm:ss")
        XCTAssertTrue(AppLanguages.documentLanguages.isSuperset(of: ["pt", "en", "de", "fi"]))
        XCTAssertFalse(AppLanguages.documentLanguages.contains("ja"), "japonês e chinês: em inglês no PDF")
        XCTAssertEqual(AppLanguages.translate("Assinado digitalmente por", to: "en"), "Digitally signed by")
        XCTAssertEqual(PageTools.NumberFormat.paginaDe.text(3, total: 12), "Página 3 de 12")
        XCTAssertEqual(OCRLanguage.defaultID, "por", "OCR sem escolha usa o idioma do app")
    }
}

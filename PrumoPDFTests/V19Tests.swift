import CryptoKit
import PDFKit
import Security
import XCTest
@testable import PrumoPDF

/// Versão 1.9.0: modo leitor com destaques, desfazer/refazer, tirar destaque e assinatura digital.
@MainActor
final class V19Tests: XCTestCase {
    var base: URL!
    var library: Library!

    private func removeTestCertificates() {
        for c in CertificateStore.all() where c.name.contains("TESTE") || c.name.contains("JOAO") || c.name.contains("AES") {
            CertificateStore.remove(c)
        }
    }

    private func fresh() {
        if let base { try? FileManager.default.removeItem(at: base) }
        base = TestPDF.tempDir()
        library = Library(baseDirectory: base)
    }

    /// Onde guardar os PDFs assinados para o CI conferir com o pyHanko (fora do simulador).
    private func keep(_ data: Data, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["PRUMO_SIGNED_OUT"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    // MARK: modo leitor ↔ PDF

    func testTextModeKnowsWhereEachLetterCameFrom() throws {
        let doc = TestPDF.digital(pages: 2)
        let reader = ReaderTextBuilder.build(doc)
        XCTAssertEqual(reader.pages.count, 2)
        for (i, page) in reader.pages.enumerated() {
            let source = (doc.page(at: i)?.string ?? "") as NSString
            XCTAssertEqual(page.maps.count, page.paragraphs.count)
            var mapped = 0
            for (para, map) in zip(page.paragraphs, page.maps) {
                let p = para as NSString
                XCTAssertEqual(p.length, map.count)
                for k in 0..<p.length where map[k] >= 0 && p.character(at: k) != 32 {
                    XCTAssertEqual(source.character(at: map[k]), p.character(at: k), "página \(i + 1), letra \(k)")
                    mapped += 1
                }
            }
            XCTAssertGreaterThan(mapped, 20, "quase todas as letras sabem de onde vieram")
        }
    }

    func testHighlightFromTextAndPartialUnmark() throws {
        let doc = TestPDF.digital(pages: 1)
        let page = try XCTUnwrap(doc.page(at: 0))
        let s = (page.string ?? "") as NSString
        let r = s.range(of: "texto digital com bastante")
        XCTAssertNotEqual(r.location, NSNotFound)
        let sel = try XCTUnwrap(page.selection(for: r))
        XCTAssertEqual(Highlights.add(sel, color: .pink, in: doc).count, 1)
        XCTAssertTrue(Highlights.hasMarks([(0, r)], in: doc))
        // tira o destaque só de "digital"
        let mid = s.range(of: "digital")
        let change = Highlights.unmark([(0, mid)], in: doc)
        XCTAssertEqual(change.removed.count, 1)
        XCTAssertGreaterThanOrEqual(change.added.count, 1)
        let left = page.annotations.filter { Highlights.isHighlight($0) }
        let covered = Set(left.flatMap { Highlights.indices(of: $0, on: page) })
        XCTAssertFalse(covered.contains(mid.location + 2), "“digital” não está mais destacado")
        XCTAssertTrue(covered.contains(s.range(of: "bastante").location + 2), "o resto continua destacado")
        // desfazer e refazer pelo histórico
        let h = ReaderHistory()
        h.record("Desfazer destaque", .marks(docID: "x", removed: change.removed, added: change.added))
        let step = try XCTUnwrap(h.popUndo())
        ReaderHistory.apply(step.change, forward: false, in: doc)
        let back = Set(page.annotations.filter { Highlights.isHighlight($0) }.flatMap { Highlights.indices(of: $0, on: page) })
        XCTAssertTrue(back.contains(mid.location + 2), "desfeito: “digital” destacado de novo")
        ReaderHistory.apply(step.change, forward: true, in: doc)
        let again = Set(page.annotations.filter { Highlights.isHighlight($0) }.flatMap { Highlights.indices(of: $0, on: page) })
        XCTAssertFalse(again.contains(mid.location + 2), "refeito")
    }

    func testHistoryRecordClearsRedo() {
        let h = ReaderHistory()
        h.record("a", .file(itemID: "1", before: Data([1]), after: Data([2])))
        h.record("b", .file(itemID: "1", before: Data([2]), after: Data([3])))
        let s = h.popUndo()!
        h.pushRedo(s)
        XCTAssertTrue(h.canRedo)
        h.record("c", .file(itemID: "1", before: Data([2]), after: Data([4])))
        XCTAssertFalse(h.canRedo, "uma ação nova apaga o que havia para refazer")
        XCTAssertEqual(h.undoSteps.map(\.label), ["a", "c"])
    }

    // MARK: certificados

    func testImportCertificateAndWrongPassword() throws {
        defer { removeTestCertificates() }
        XCTAssertThrowsError(try CertificateStore.importP12(TestCertificates.maria, password: "errada"))
        let c = try CertificateStore.importP12(TestCertificates.maria, password: TestCertificates.password)
        XCTAssertEqual(c.name, "MARIA DE TESTE")
        XCTAssertEqual(c.certificate.holderDocument, "12345678909")
        XCTAssertFalse(c.expired)
        XCTAssertTrue(CertificateStore.all().contains(c))
        XCTAssertNotNil(CertificateStore.identity(for: c))
        let sign = try CertificateStore.signer(for: c)
        XCTAssertEqual(try sign(Array("teste".utf8)).count, 256, "RSA 2048")
        CertificateStore.remove(c)
        XCTAssertFalse(CertificateStore.all().contains(c))
        // arquivo com a cifra nova (AES-256): só informa se o iOS aceita
        do {
            let a = try CertificateStore.importP12(TestCertificates.aes, password: TestCertificates.password)
            print("Certificado AES-256: aceito pelo iOS (\(a.name))")
        } catch {
            print("Certificado AES-256: recusado pelo iOS: \(error.localizedDescription)")
        }
    }

    // MARK: assinatura

    /// Confere a assinatura: o /ByteRange cobre todo o arquivo menos a assinatura, o resumo bate e a
    /// chave do certificado confere a assinatura CMS.
    private func verify(_ data: Data, signature index: Int) throws -> X509Certificate {
        let bytes = [UInt8](data)
        let marker = Array("/ByteRange [".utf8)
        var found: [Int] = []
        var k = 0
        while k + marker.count < bytes.count {
            if bytes[k] == marker[0], Array(bytes[k..<k + marker.count]) == marker { found.append(k) }
            k += 1
        }
        XCTAssertGreaterThan(found.count, index)
        var lx = PDFLexer(bytes, at: found[index] + "/ByteRange ".count)
        guard case .array(let arr) = try lx.parse() else { throw DER.Failure() }
        let br = arr.compactMap { $0.intValue }
        XCTAssertEqual(br.count, 4)
        XCTAssertEqual(br[0], 0)
        XCTAssertEqual(bytes[br[1]], UInt8(ascii: "<"))
        XCTAssertEqual(bytes[br[2] - 1], UInt8(ascii: ">"))
        if index == found.count - 1 { XCTAssertEqual(br[2] + br[3], bytes.count, "a última assinatura cobre o arquivo todo") }
        let hex = String(decoding: bytes[(br[1] + 1)..<(br[2] - 1)], as: UTF8.self)
        var cms: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            cms.append(UInt8(hex[i..<j], radix: 16) ?? 0)
            i = j
        }
        while cms.last == 0 { cms.removeLast() }
        let parsed = try CMS.inspect(cms)
        var h = SHA256()
        h.update(data: bytes[0..<br[1]])
        h.update(data: bytes[br[2]..<(br[2] + br[3])])
        XCTAssertEqual(parsed.digest, Array(h.finalize()), "o resumo do PDF bate com o da assinatura")
        let signer = try XCTUnwrap(parsed.signer)
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, Data(signer.der) as CFData))
        let key = try XCTUnwrap(SecCertificateCopyKey(cert))
        var err: Unmanaged<CFError>?
        XCTAssertTrue(SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(parsed.attrs) as CFData,
                                            Data(parsed.signature) as CFData, &err), "assinatura confere com a chave")
        return signer
    }

    func testSignTwiceKeepsTheFirstSignature() throws {
        defer { removeTestCertificates() }
        let maria = try CertificateStore.importP12(TestCertificates.maria, password: TestCertificates.password)
        let joao = try CertificateStore.importP12(TestCertificates.joao, password: TestCertificates.password)
        let original = try XCTUnwrap(TestPDF.digital(pages: 3).dataRepresentation())
        let once = try PDFSigner.sign(original, certificate: maria, options: SignOptions(reason: "Teste"),
                                      sign: try CertificateStore.signer(for: maria))
        XCTAssertTrue(once.starts(with: original), "atualização incremental: o original fica intacto")
        let file = try PDFFile(once)
        XCTAssertEqual(file.signatureCount, 1)
        XCTAssertEqual(file.docMDPLevel, 2, "primeira assinatura: certificação (DocMDP)")
        XCTAssertEqual(try verify(once, signature: 0).holderName, "MARIA DE TESTE")
        let text = String(decoding: once, as: UTF8.self)
        XCTAssertTrue(text.contains("/SubFilter /ETSI.CAdES.detached"))
        XCTAssertTrue(text.contains("/TransformMethod /DocMDP"))
        let doc = try XCTUnwrap(PDFDocument(data: once))
        XCTAssertEqual(doc.pageCount, 3)
        XCTAssertTrue(doc.page(at: 2)!.annotations.contains { $0.widgetFieldType == .signature }, "campo na última página")
        keep(once, "uma-assinatura.pdf")

        let twice = try PDFSigner.sign(once, certificate: joao, options: SignOptions(position: .bottomRight),
                                       sign: try CertificateStore.signer(for: joao))
        XCTAssertTrue(twice.starts(with: once), "a primeira assinatura continua intacta")
        XCTAssertEqual(try PDFFile(twice).signatureCount, 2)
        XCTAssertEqual(try verify(twice, signature: 0).holderName, "MARIA DE TESTE")
        XCTAssertEqual(try verify(twice, signature: 1).holderName, "JOAO DA SILVA")
        XCTAssertTrue(String(decoding: twice, as: UTF8.self).contains("/TransformMethod /FieldMDP"))
        keep(twice, "duas-assinaturas.pdf")
    }

    func testSignInvisibleRotatedAndXrefStream() throws {
        defer { removeTestCertificates() }
        let maria = try CertificateStore.importP12(TestCertificates.maria, password: TestCertificates.password)
        let sign = try CertificateStore.signer(for: maria)
        // página girada, com carimbo
        let rotated = TestPDF.digital(pages: 2)
        rotated.page(at: 1)?.rotation = 90
        let r = try PDFSigner.sign(try XCTUnwrap(rotated.dataRepresentation()), certificate: maria,
                                   options: SignOptions(), sign: sign)
        _ = try verify(r, signature: 0)
        keep(r, "girada.pdf")
        // sem carimbo (assinatura invisível)
        let invisible = try PDFSigner.sign(try XCTUnwrap(TestPDF.digital(pages: 1).dataRepresentation()),
                                           certificate: maria, options: SignOptions(stamp: false), sign: sign)
        _ = try verify(invisible, signature: 0)
        keep(invisible, "invisivel.pdf")
        // PDF com xref em fluxo e objetos compactados (como os do Word)
        let xs = TestPDFs.xrefStream
        let parsed = try PDFFile(xs)
        XCTAssertTrue(parsed.lastXrefIsStream)
        XCTAssertEqual(parsed.pageRefs().count, 2)
        let signed = try PDFSigner.sign(xs, certificate: maria, options: SignOptions(), sign: sign)
        XCTAssertTrue(signed.starts(with: xs))
        _ = try verify(signed, signature: 0)
        XCTAssertEqual(try PDFFile(signed).signatureCount, 1)
        XCTAssertEqual(PDFDocument(data: signed)?.pageCount, 2)
        keep(signed, "xref-em-fluxo.pdf")
    }

    func testLibrarySignsACopyAndThenInPlace() async throws {
        defer { removeTestCertificates() }
        fresh()
        let maria = try CertificateStore.importP12(TestCertificates.maria, password: TestCertificates.password)
        let url = base.appendingPathComponent("Contrato.pdf")
        XCTAssertTrue(TestPDF.digital(pages: 2).write(to: url))
        let item = try XCTUnwrap(library.importFiles([url]).first)
        let before = try Data(contentsOf: item.url)
        let signed = try await library.sign(item, with: maria, options: SignOptions())
        XCTAssertEqual(signed.name, "Contrato - assinado")
        XCTAssertEqual(signed.meta.signed, 1)
        XCTAssertTrue(signed.meta.isSigned)
        XCTAssertEqual(try Data(contentsOf: library.item(id: item.id)!.url), before, "o original não muda")
        let again = try await library.sign(signed, with: maria, options: SignOptions())
        XCTAssertEqual(again.id, signed.id, "PDF já assinado: a nova assinatura entra no mesmo arquivo")
        XCTAssertEqual(again.meta.signed, 2)
    }
}

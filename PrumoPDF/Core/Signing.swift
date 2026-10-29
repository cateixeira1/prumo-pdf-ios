import CryptoKit
import Foundation
import LocalAuthentication
import PDFKit
import Security
import UIKit

/// Certificado A1 guardado nas Chaves (Keychain) do iPhone, só neste aparelho.
struct SigningCertificate: Identifiable, Hashable {
    let id: String              // SHA-1 do certificado
    let certificate: X509Certificate
    let chain: [[UInt8]]

    var name: String { certificate.holderName }
    var issuer: String { certificate.issuerCN }
    var expired: Bool { certificate.expired }

    static func == (a: SigningCertificate, b: SigningCertificate) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// As Chaves do iPhone: o certificado e a chave ficam lá (acessíveis só com o iPhone desbloqueado,
/// sem ir para o iCloud nem para backups). A senha do arquivo .pfx não é guardada.
enum CertificateStore {
    static let service = "br.com.prumopdf.certificados"

    static func importP12(_ data: Data, password: String) throws -> SigningCertificate {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        switch status {
        case errSecSuccess: break
        case errSecAuthFailed, errSecPkcs12VerifyFailure:
            throw UserFacingError("Senha do certificado incorreta.")
        default:
            throw UserFacingError("Não foi possível ler o certificado (código \(status)). Use o arquivo .pfx ou .p12 do certificado A1.")
        }
        guard let list = items as? [[String: Any]], let first = list.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            throw UserFacingError("O arquivo não tem a chave do certificado.")
        }
        let identity = identityRef as! SecIdentity   // swiftlint:disable:this force_cast
        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess, let cert = certRef else {
            throw UserFacingError("O arquivo não tem o certificado.")
        }
        let der = [UInt8](SecCertificateCopyData(cert) as Data)
        let x509 = try parse(der)
        let chain = ((first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? [])
            .map { [UInt8](SecCertificateCopyData($0) as Data) }
            .filter { $0 != der }
        // a identidade (certificado + chave) vai para as Chaves
        let add: [String: Any] = [
            kSecValueRef as String: identity,
            kSecAttrLabel as String: "Prumo PDF – \(x509.holderName)",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let st = SecItemAdd(add as CFDictionary, nil)
        guard st == errSecSuccess || st == errSecDuplicateItem else {
            throw UserFacingError("Não foi possível guardar o certificado nas Chaves do iPhone (código \(st)).")
        }
        // a cadeia e os dados para mostrar a lista, num item separado
        let info: [String: Any] = ["der": Data(der).base64EncodedString(),
                                   "chain": chain.map { Data($0).base64EncodedString() }]
        let blob = try JSONSerialization.data(withJSONObject: info)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: x509.sha1]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = blob
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let st2 = SecItemAdd(item as CFDictionary, nil)
        guard st2 == errSecSuccess else {
            throw UserFacingError("Não foi possível guardar o certificado (código \(st2)).")
        }
        return SigningCertificate(id: x509.sha1, certificate: x509, chain: chain)
    }

    static func parse(_ der: [UInt8]) throws -> X509Certificate {
        do { return try X509Certificate(der: der) } catch {
            throw UserFacingError("O certificado não pôde ser lido.")
        }
    }

    static func all() -> [SigningCertificate] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let rows = out as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let data = row[kSecValueData as String] as? Data,
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let derB64 = info["der"] as? String, let der = Data(base64Encoded: derB64),
                  let x = try? X509Certificate(der: [UInt8](der)) else { return nil }
            let chain = (info["chain"] as? [String] ?? []).compactMap { Data(base64Encoded: $0) }.map { [UInt8]($0) }
            return SigningCertificate(id: x.sha1, certificate: x, chain: chain)
        }
        .sorted { $0.name < $1.name }
    }

    /// A identidade (certificado + chave) nas Chaves.
    static func identity(for cert: SigningCertificate) -> SecIdentity? {
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity,
                                    kSecReturnRef as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let list = out as? [Any] else { return nil }
        for any in list {
            let identity = any as! SecIdentity   // swiftlint:disable:this force_cast
            var c: SecCertificate?
            if SecIdentityCopyCertificate(identity, &c) == errSecSuccess, let c,
               [UInt8](SecCertificateCopyData(c) as Data) == cert.certificate.der {
                return identity
            }
        }
        return nil
    }

    static func remove(_ cert: SigningCertificate) {
        if let identity = identity(for: cert) {
            SecItemDelete([kSecClass as String: kSecClassIdentity, kSecValueRef as String: identity] as CFDictionary)
            var c: SecCertificate?
            if SecIdentityCopyCertificate(identity, &c) == errSecSuccess, let c {
                SecItemDelete([kSecClass as String: kSecClassCertificate, kSecValueRef as String: c] as CFDictionary)
            }
        }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: cert.id] as CFDictionary)
    }

    /// Assina `data` com a chave do certificado (RSA PKCS#1 v1.5 ou ECDSA, SHA-256).
    static func signer(for cert: SigningCertificate) throws -> ([UInt8]) throws -> [UInt8] {
        guard let identity = identity(for: cert) else {
            throw UserFacingError("A chave do certificado não está nas Chaves deste iPhone. Adicione o certificado de novo.")
        }
        var keyRef: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &keyRef) == errSecSuccess, let key = keyRef else {
            throw UserFacingError("Não foi possível usar a chave do certificado.")
        }
        let algorithm: SecKeyAlgorithm = cert.certificate.isRSA ? .rsaSignatureMessagePKCS1v15SHA256
                                                                 : .ecdsaSignatureMessageX962SHA256
        return { message in
            var error: Unmanaged<CFError>?
            guard let sig = SecKeyCreateSignature(key, algorithm, Data(message) as CFData, &error) as Data? else {
                throw UserFacingError("A assinatura falhou: \(error?.takeRetainedValue().localizedDescription ?? "erro desconhecido").")
            }
            return [UInt8](sig)
        }
    }
}

/// Onde e como a assinatura aparece.
struct SignOptions: Equatable {
    enum Page: String, CaseIterable, Identifiable {
        case last, first
        var id: String { rawValue }
        var label: String { self == .last ? "Última página" : "Primeira página" }
    }

    enum Position: String, CaseIterable, Identifiable {
        case bottomLeft, bottomRight, topRight
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bottomLeft: return "Embaixo, à esquerda"
            case .bottomRight: return "Embaixo, à direita"
            case .topRight: return "Em cima, à direita"
            }
        }
    }

    var stamp = true
    var page: Page = .last
    var position: Position = .bottomLeft
    var reason = ""
}

/// Assinatura digital PAdES (o mesmo formato do Prumo para Windows e do Adobe Acrobat):
/// SubFilter ETSI.CAdES.detached; a primeira assinatura é de certificação (DocMDP, só formulários e
/// novas assinaturas); as seguintes travam os campos (FieldMDP). O verificador do ITI exige DocMDP
/// ou FieldMDP. Gravada como atualização incremental: o que já estava no arquivo não muda.
enum PDFSigner {
    static let suffix = " - assinado"
    static let reserved = 20_000          // bytes reservados para a assinatura CMS
    static let stampSize = CGSize(width: 230, height: 48)

    struct Prepared {
        var bytes: [UInt8]
        let contentsStart: Int      // posição do "<" de /Contents
        let contentsEnd: Int        // posição depois do ">"
    }

    static func signatureCount(_ data: Data) -> Int { (try? PDFFile(data))?.signatureCount ?? 0 }

    /// Assina e devolve o PDF assinado.
    static func sign(_ data: Data, certificate: SigningCertificate, options: SignOptions, date: Date = Date(),
                     sign: ([UInt8]) throws -> [UInt8]) throws -> Data {
        var prepared = try prepare(data, certificate: certificate, options: options, date: date)
        let b = prepared.bytes
        var digest = SHA256()
        digest.update(data: b[0..<prepared.contentsStart])
        digest.update(data: b[prepared.contentsEnd..<b.count])
        let cms = try CMS.build(digest: Array(digest.finalize()), certificate: certificate.certificate,
                                chain: certificate.chain, sign: sign)
        let hex = Array(cms.map { String(format: "%02X", $0) }.joined().utf8)
        let room = prepared.contentsEnd - prepared.contentsStart - 2
        guard hex.count <= room else { throw UserFacingError("A assinatura ficou maior que o espaço reservado.") }
        for (k, c) in hex.enumerated() { prepared.bytes[prepared.contentsStart + 1 + k] = c }
        guard PDFDocument(data: Data(prepared.bytes)) != nil else {
            throw UserFacingError("O PDF assinado não pôde ser conferido; nada foi alterado.")
        }
        return Data(prepared.bytes)
    }

    /// Monta a atualização incremental com o espaço da assinatura e o /ByteRange já preenchido.
    static func prepare(_ data: Data, certificate: SigningCertificate, options: SignOptions, date: Date) throws -> Prepared {
        let file: PDFFile
        do { file = try PDFFile(data) } catch {
            throw UserFacingError("A estrutura deste PDF não pôde ser lida para assinar.")
        }
        guard !file.isEncrypted else {
            throw UserFacingError("PDF com senha não pode ser assinado. Remova a senha antes.")
        }
        if file.docMDPLevel == 1 {
            throw UserFacingError("A primeira assinatura deste PDF não permite mais nenhuma mudança, nem novas assinaturas.")
        }
        guard let rootRef = file.rootRef, var catalog = file.catalog else {
            throw UserFacingError("PDF sem catálogo.")
        }
        let pages = file.pageRefs()
        guard !pages.isEmpty else { throw UserFacingError("PDF sem páginas.") }
        let existing = file.signatureCount
        let names = Set(file.fields().compactMap { f -> String? in
            if case .string(let s)? = f["T"] { return PDFText.decode(s) }
            return nil
        })
        var index = existing + 1
        while names.contains("Assinatura\(index)") { index += 1 }
        let certify = existing == 0

        var up = PDFIncrementalUpdate(file)
        let sigNum = up.reserve()
        let fieldNum = up.reserve()
        let pageRef = options.page == .first ? pages[0] : pages[pages.count - 1]
        guard var pageDict = (try? file.object(pageRef.0))?.dictValue else { throw UserFacingError("Página inválida.") }

        // carimbo visível (opcional)
        var rect = "[0 0 0 0]"
        var ap = ""
        if options.stamp {
            let crop = box(file, pageDict, "CropBox") ?? box(file, pageDict, "MediaBox") ?? CGRect(x: 0, y: 0, width: 595, height: 842)
            let rot = ((file.inherited("Rotate", page: pageDict)?.intValue ?? 0) % 360 + 360) % 360
            let r = stampRect(crop: crop, rotation: rot, position: options.position, index: existing)
            rect = "[\(f(r.minX)) \(f(r.minY)) \(f(r.maxX)) \(f(r.maxY))]"
            let fontNum = up.reserve()
            let apNum = up.reserve()
            up.set(fontNum, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
            let content = stampContent(name: certificate.name, date: date)
            let w = Double(stampSize.width), h = Double(stampSize.height)
            let matrix: String
            switch rot {
            case 90: matrix = "/Matrix [0 1 -1 0 0 0] "
            case 180: matrix = "/Matrix [-1 0 0 -1 0 0] "
            case 270: matrix = "/Matrix [0 -1 1 0 0 0] "
            default: matrix = ""
            }
            up.set(apNum, Array("<</Type /XObject /Subtype /Form /BBox [0 0 \(f(w)) \(f(h))] \(matrix)/Resources <</Font <</F1 \(fontNum) 0 R>>>> /Length \(content.count)>>\nstream\n".utf8)
                + content + Array("\nendstream".utf8))
            ap = " /AP <</N \(apNum) 0 R>>"
        }

        // dicionário da assinatura, com espaço reservado para o CMS
        let reference: String
        if certify {
            reference = "/Reference [<</Type /SigRef /TransformMethod /DocMDP /TransformParams <</Type /TransformParams /P 2 /V /1.2>>>>]"
        } else {
            reference = "/Reference [<</Type /SigRef /TransformMethod /FieldMDP /TransformParams <</Type /TransformParams /Action /All /V /1.2>> /Data \(rootRef.0) \(rootRef.1) R>>]"
        }
        var sig = "<</Type /Sig /Filter /Adobe.PPKLite /SubFilter /ETSI.CAdES.detached "
        sig += "/ByteRange [0 BYTERANGE_1 BYTERANGE_2 BYTERANGE_3] "
        sig += "/Contents <" + String(repeating: "0", count: reserved * 2) + "> "
        sig += "/M (\(pdfDate(date))) /Name \(PDFWriter.text(certificate.name)) "
        if !options.reason.isEmpty { sig += "/Reason \(PDFWriter.text(options.reason)) " }
        sig += reference + ">>"
        up.set(sigNum, sig)

        // campo de assinatura (também é a anotação na página)
        let lock = certify ? "" : " /Lock <</Type /SigFieldLock /Action /All>>"
        up.set(fieldNum, "<</Type /Annot /Subtype /Widget /FT /Sig /T (Assinatura\(index)) /V \(sigNum) 0 R /F 132 /Rect \(rect) /P \(pageRef.0) \(pageRef.1) R\(ap)\(lock)>>")

        // a página passa a listar o campo em /Annots
        let fieldRef = PDFObject.ref(fieldNum, 0)
        if let annots = pageDict["Annots"], case .ref(let an, let ag) = annots {
            var list = file.resolve(annots)?.arrayValue ?? []
            list.append(fieldRef)
            up.set(an, gen: ag, PDFWriter.write(.array(list)))
        } else {
            var list = pageDict["Annots"]?.arrayValue ?? []
            list.append(fieldRef)
            pageDict["Annots"] = .array(list)
            up.set(pageRef.0, gen: pageRef.1, PDFWriter.dict(pageDict))
        }

        // formulário (AcroForm) com o campo novo e /SigFlags 3
        var acroRef: (Int, Int)?
        var acro = PDFDict()
        if let a = catalog["AcroForm"] {
            if case .ref(let n, let g) = a { acroRef = (n, g) }
            acro = file.resolve(a)?.dictValue ?? PDFDict()
        }
        if let fields = acro["Fields"], case .ref(let fnum, let fgen) = fields {
            var list = file.resolve(fields)?.arrayValue ?? []
            list.append(fieldRef)
            up.set(fnum, gen: fgen, PDFWriter.write(.array(list)))
        } else {
            var list = acro["Fields"]?.arrayValue ?? []
            list.append(fieldRef)
            acro["Fields"] = .array(list)
        }
        acro["SigFlags"] = .number("3")
        if let ar = acroRef {
            up.set(ar.0, gen: ar.1, PDFWriter.dict(acro))
        } else {
            catalog["AcroForm"] = .dict(acro)
        }
        if certify {
            var perms = file.resolve(catalog["Perms"])?.dictValue ?? PDFDict()
            perms["DocMDP"] = .ref(sigNum, 0)
            catalog["Perms"] = .dict(perms)
        }
        up.set(rootRef.0, gen: rootRef.1, PDFWriter.dict(catalog))

        // grava e preenche o /ByteRange
        var out = up.output()
        guard let sigStart = find(out, "/ByteRange [0 BYTERANGE_1", from: file.bytes.count),
              let open = find(out, "/Contents <", from: sigStart) else {
            throw UserFacingError("Falha ao montar a assinatura.")
        }
        let contentsStart = open + 10
        let contentsEnd = contentsStart + 2 + reserved * 2
        let placeholder = "BYTERANGE_1 BYTERANGE_2 BYTERANGE_3"
        let values = [contentsStart, contentsEnd, out.count - contentsEnd]
        var filled = values.map { String($0) }.joined(separator: " ")
        guard filled.count <= placeholder.count else { throw UserFacingError("PDF grande demais para assinar.") }
        filled += String(repeating: " ", count: placeholder.count - filled.count)
        let at = sigStart + "/ByteRange [0 ".count
        for (k, c) in filled.utf8.enumerated() { out[at + k] = c }
        return Prepared(bytes: out, contentsStart: contentsStart, contentsEnd: contentsEnd)
    }

    // MARK: auxiliares

    private static func f(_ v: Double) -> String { String(format: "%.2f", v) }
    private static func f(_ v: CGFloat) -> String { f(Double(v)) }

    private static func find(_ b: [UInt8], _ s: String, from: Int) -> Int? {
        let u = Array(s.utf8)
        var k = max(0, from)
        while k + u.count <= b.count {
            if b[k] == u[0], Array(b[k..<k + u.count]) == u { return k }
            k += 1
        }
        return nil
    }

    private static func box(_ file: PDFFile, _ page: PDFDict, _ key: String) -> CGRect? {
        guard let a = file.inherited(key, page: page)?.arrayValue, a.count >= 4 else { return nil }
        let v = a.compactMap { file.resolve($0)?.doubleValue }
        guard v.count >= 4 else { return nil }
        return CGRect(x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1]))
    }

    /// Retângulo do carimbo no espaço do PDF, para a página como aparece (com giro).
    static func stampRect(crop: CGRect, rotation: Int, position: SignOptions.Position, index: Int) -> CGRect {
        let (w, h) = rotation % 180 == 0 ? (crop.width, crop.height) : (crop.height, crop.width)
        let sw = stampSize.width, sh = stampSize.height
        let step = CGFloat(index) * (sh + 6)
        let dx: CGFloat, dy: CGFloat
        switch position {
        case .bottomRight: dx = w - 36 - sw; dy = h - 28 - sh - step
        case .topRight: dx = w - 36 - sw; dy = 28 + step
        case .bottomLeft: dx = 36; dy = h - 28 - sh - step
        }
        let a = PageTools.displayToUser(crop: crop, rotation: rotation, x: dx, y: dy)
        let b = PageTools.displayToUser(crop: crop, rotation: rotation, x: dx + sw, y: dy + sh)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    static func pdfDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        let offset = TimeZone.current.secondsFromGMT(for: d)
        let sign = offset >= 0 ? "+" : "-"
        let hh = abs(offset) / 3600, mm = (abs(offset) % 3600) / 60
        return "D:" + f.string(from: d) + String(format: "%@%02d'%02d'", sign, hh, mm)
    }

    /// Texto do carimbo: "Assinado digitalmente por / NOME / em DATA".
    static func stampContent(name: String, date: Date) -> [UInt8] {
        let df = DateFormatter()
        df.locale = Locale(identifier: "pt_BR")
        df.dateFormat = "dd/MM/yyyy HH:mm:ss"
        let h = Double(stampSize.height), w = Double(stampSize.width)
        var s = "q 0.16 0.47 0.96 RG 0.8 w 0.5 0.5 \(f(w - 1)) \(f(h - 1)) re S Q\n"
        s += "BT 0.15 0.15 0.15 rg /F1 7.5 Tf 6 \(f(h - 13)) Td "
        var out = Array(s.utf8)
        let lines = ["Assinado digitalmente por", name, "em \(df.string(from: date))"]
        for (k, line) in lines.enumerated() {
            if k > 0 { out += Array(" 0 -12 Td ".utf8) }
            if k == 1 { out += Array("/F1 9 Tf ".utf8) }
            if k == 2 { out += Array("/F1 7.5 Tf ".utf8) }
            out += winAnsi(line) + Array(" Tj".utf8)
        }
        out += Array(" ET".utf8)
        return out
    }

    /// Texto em WinAnsi (o da fonte Helvetica padrão), com os escapes do PDF.
    static func winAnsi(_ s: String) -> [UInt8] {
        let bytes = [UInt8](s.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data(s.utf8))
        var out: [UInt8] = [UInt8(ascii: "(")]
        for b in bytes {
            if b == UInt8(ascii: "(") || b == UInt8(ascii: ")") || b == UInt8(ascii: "\\") {
                out += [UInt8(ascii: "\\"), b]
            } else if b < 32 || b > 126 {
                out += Array(String(format: "\\%03o", b).utf8)
            } else {
                out.append(b)
            }
        }
        out.append(UInt8(ascii: ")"))
        return out
    }
}

/// Textos do PDF: UTF-16 (com FE FF no começo) ou PDFDocEncoding (na prática, Latin-1).
enum PDFText {
    static func decode(_ b: [UInt8]) -> String {
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF {
            var units: [UInt16] = []
            var i = 2
            while i + 1 < b.count {
                units.append(UInt16(b[i]) << 8 | UInt16(b[i + 1]))
                i += 2
            }
            return String(utf16CodeUnits: units, count: units.count)
        }
        return String(bytes: b, encoding: .isoLatin1) ?? String(decoding: b, as: UTF8.self)
    }
}

extension Library {
    /// Assina um PDF da biblioteca. Sem assinatura: cria "Nome - assinado.pdf" (o original continua
    /// editável). Já assinado: acrescenta a nova assinatura no próprio arquivo. Devolve o PDF assinado.
    func sign(_ item: PDFItem, with cert: SigningCertificate, options: SignOptions) async throws -> PDFItem {
        guard item.meta.locked != true else {
            throw UserFacingError("PDF com senha não pode ser assinado. Remova a senha antes.")
        }
        let signer = try CertificateStore.signer(for: cert)
        let url = item.url
        let original = try Data(contentsOf: url)
        let already = PDFSigner.signatureCount(original) > 0
        let signed: Data = try await Task.detached(priority: .userInitiated) {
            do {
                return try PDFSigner.sign(original, certificate: cert, options: options, sign: signer)
            } catch let e as UserFacingError where !already && e.message.contains("estrutura") {
                // estrutura que o Prumo não lê: regrava o PDF (é uma cópia nova) e assina
                guard let doc = PDFDocument(data: original), let clean = doc.dataRepresentation() else { throw e }
                return try PDFSigner.sign(clean, certificate: cert, options: options, sign: signer)
            }
        }.value
        let count = PDFSigner.signatureCount(signed)
        if already {
            try await replaceContents(item, with: signed, keepReview: true)
            markSigned(item.id, count: count)
            return self.item(id: item.id) ?? item
        }
        let result = try save(newData: signed, name: item.name + PDFSigner.suffix, folder: item.folder) {
            $0.signed = count
        }
        return self.item(id: result.id) ?? result
    }
}

/// Face ID ou código do iPhone antes de usar a chave do certificado.
enum SignConfirmation {
    @MainActor
    static func confirm() async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication,
                                              localizedReason: "Confirme para assinar o PDF com o seu certificado")) ?? false
    }
}

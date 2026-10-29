import CryptoKit
import Foundation
import Security

/// DER (ASN.1) mínimo: o bastante para ler certificados X.509 e montar a assinatura CMS do PDF.
enum DER {
    struct Node {
        let tag: UInt8
        let start: Int            // início do TLV
        let contentStart: Int
        let end: Int              // fim (exclusivo)
        var content: Range<Int> { contentStart..<end }
        var range: Range<Int> { start..<end }
    }

    struct Failure: Error {}

    static func read(_ b: [UInt8], at offset: Int) throws -> Node {
        guard offset + 2 <= b.count else { throw Failure() }
        let tag = b[offset]
        var i = offset + 1
        var len = Int(b[i])
        i += 1
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n > 0, n <= 4, i + n <= b.count else { throw Failure() }
            len = 0
            for _ in 0..<n {
                len = (len << 8) | Int(b[i])
                i += 1
            }
        }
        guard i + len <= b.count else { throw Failure() }
        return Node(tag: tag, start: offset, contentStart: i, end: i + len)
    }

    static func children(_ b: [UInt8], _ node: Node) throws -> [Node] {
        var out: [Node] = []
        var i = node.contentStart
        while i < node.end {
            let n = try read(b, at: i)
            out.append(n)
            i = n.end
        }
        return out
    }

    // MARK: Gravação

    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    static func seq(_ parts: [[UInt8]]) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }

    /// SET OF em DER: os elementos vão em ordem crescente de bytes.
    static func set(_ parts: [[UInt8]]) -> [UInt8] {
        tlv(0x31, parts.sorted { $0.lexicographicallyPrecedes($1) }.flatMap { $0 })
    }

    static func oid(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").compactMap { UInt64($0) }
        guard arcs.count >= 2 else { return [] }
        var body: [UInt8] = []
        let all: [UInt64] = [arcs[0] * 40 + arcs[1]] + Array(arcs.dropFirst(2))
        for arc in all {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var v = arc >> 7
            while v > 0 {
                chunk.insert(UInt8(v & 0x7F) | 0x80, at: 0)
                v >>= 7
            }
            body += chunk
        }
        return tlv(0x06, body)
    }

    static func int(_ v: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var x = v
        repeat {
            bytes.insert(UInt8(x & 0xFF), at: 0)
            x >>= 8
        } while x > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }

    static func octets(_ b: [UInt8]) -> [UInt8] { tlv(0x04, b) }
    static let null: [UInt8] = [0x05, 0x00]
}

/// Certificado X.509: o que a assinatura e a tela precisam (titular, emissor, validade, número de série).
struct X509Certificate {
    let der: [UInt8]
    let serialTLV: [UInt8]
    let issuerTLV: [UInt8]
    let subjectTLV: [UInt8]
    let notBefore: Date
    let notAfter: Date
    let subjectCN: String
    let issuerCN: String
    let isRSA: Bool

    init(der: [UInt8]) throws {
        self.der = der
        let root = try DER.read(der, at: 0)
        let top = try DER.children(der, root)
        guard let tbsNode = top.first else { throw DER.Failure() }
        var parts = try DER.children(der, tbsNode)
        if parts.first?.tag == 0xA0 { parts.removeFirst() }      // versão
        guard parts.count >= 6 else { throw DER.Failure() }
        serialTLV = Array(der[parts[0].range])
        issuerTLV = Array(der[parts[2].range])
        let validity = try DER.children(der, parts[3])
        subjectTLV = Array(der[parts[4].range])
        guard validity.count == 2 else { throw DER.Failure() }
        notBefore = try X509Certificate.date(der, validity[0])
        notAfter = try X509Certificate.date(der, validity[1])
        subjectCN = X509Certificate.commonName(der, parts[4]) ?? ""
        issuerCN = X509Certificate.commonName(der, parts[2]) ?? ""
        // chave pública: AlgorithmIdentifier do SubjectPublicKeyInfo
        let spki = try DER.children(der, parts[5])
        let alg = try DER.children(der, spki[0])
        isRSA = alg.first.map { Array(der[$0.range]) == DER.oid("1.2.840.113549.1.1.1") } ?? true
    }

    /// Nome do titular sem o CPF/CNPJ que a ICP-Brasil põe no fim ("NOME:12345678900").
    var holderName: String {
        if let r = subjectCN.range(of: #":(\d{11}|\d{14})$"#, options: .regularExpression) {
            return String(subjectCN[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return subjectCN
    }

    var holderDocument: String {
        if let r = subjectCN.range(of: #"(\d{11}|\d{14})$"#, options: .regularExpression),
           subjectCN.contains(":") {
            return String(subjectCN[r])
        }
        return ""
    }

    var expired: Bool { Date() > notAfter }
    var sha1: String { Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined() }

    private static func commonName(_ b: [UInt8], _ name: DER.Node) -> String? {
        let cnOID = DER.oid("2.5.4.3")
        guard let sets = try? DER.children(b, name) else { return nil }
        for set in sets {
            guard let atvs = try? DER.children(b, set) else { continue }
            for atv in atvs {
                guard let kv = try? DER.children(b, atv), kv.count == 2, Array(b[kv[0].range]) == cnOID else { continue }
                let raw = Array(b[kv[1].content])
                switch kv[1].tag {
                case 0x1E:    // BMPString (UTF-16BE)
                    var units: [UInt16] = []
                    var i = 0
                    while i + 1 < raw.count {
                        units.append(UInt16(raw[i]) << 8 | UInt16(raw[i + 1]))
                        i += 2
                    }
                    return String(utf16CodeUnits: units, count: units.count)
                case 0x14:    // T61String: na prática, Latin-1
                    return String(bytes: raw, encoding: .isoLatin1)
                default:
                    return String(bytes: raw, encoding: .utf8) ?? String(bytes: raw, encoding: .isoLatin1)
                }
            }
        }
        return nil
    }

    private static func date(_ b: [UInt8], _ node: DER.Node) throws -> Date {
        guard let s = String(bytes: b[node.content], encoding: .ascii) else { throw DER.Failure() }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        var text = s
        if node.tag == 0x17 {                 // UTCTime: AAMMDDhhmmssZ
            let yy = Int(text.prefix(2)) ?? 0
            text = (yy < 50 ? "20" : "19") + text
        }
        text = text.replacingOccurrences(of: "Z", with: "")
        f.dateFormat = text.count >= 14 ? "yyyyMMddHHmmss" : "yyyyMMddHHmm"
        guard let d = f.date(from: String(text.prefix(14))) else { throw DER.Failure() }
        return d
    }
}

/// Assinatura CMS (SignedData destacada), no formato PAdES: atributos contentType, messageDigest e
/// signingCertificateV2, sem signingTime (a data vai no /M do PDF), resumo SHA-256.
enum CMS {
    static let sha256 = "2.16.840.1.101.3.4.2.1"
    static let data = "1.2.840.113549.1.7.1"
    static let signedData = "1.2.840.113549.1.7.2"

    /// Os atributos assinados, já como SET (é sobre estes bytes que a chave assina).
    static func signedAttributes(digest: [UInt8], certificate c: X509Certificate) -> [UInt8] {
        let contentType = DER.seq([DER.oid("1.2.840.113549.1.9.3"), DER.set([DER.oid(data)])])
        let messageDigest = DER.seq([DER.oid("1.2.840.113549.1.9.4"), DER.set([DER.octets(digest)])])
        let certHash = Array(SHA256.hash(data: c.der))
        let issuerSerial = DER.seq([DER.seq([DER.tlv(0xA4, c.issuerTLV)]), c.serialTLV])
        let essCertIDv2 = DER.seq([DER.octets(certHash), issuerSerial])
        let signingCertV2 = DER.seq([DER.oid("1.2.840.113549.1.9.16.2.47"),
                                     DER.set([DER.seq([DER.seq([essCertIDv2])])])])
        return DER.set([contentType, messageDigest, signingCertV2])
    }

    static func build(digest: [UInt8], certificate c: X509Certificate, chain: [[UInt8]],
                      sign: ([UInt8]) throws -> [UInt8]) throws -> [UInt8] {
        let attrs = signedAttributes(digest: digest, certificate: c)
        let signature = try sign(attrs)
        var implicitAttrs = attrs
        implicitAttrs[0] = 0xA0
        let sigAlg = c.isRSA ? DER.seq([DER.oid("1.2.840.113549.1.1.1"), DER.null])
                             : DER.seq([DER.oid("1.2.840.10045.4.3.2")])
        let signerInfo = DER.seq([
            DER.int(1),
            DER.seq([c.issuerTLV, c.serialTLV]),
            DER.seq([DER.oid(sha256)]),
            implicitAttrs,
            sigAlg,
            DER.octets(signature),
        ])
        var certs = [c.der]
        for extra in chain where extra != c.der && !certs.contains(extra) { certs.append(extra) }
        let certSet = certs.sorted { $0.lexicographicallyPrecedes($1) }.flatMap { $0 }
        let sd = DER.seq([
            DER.int(1),
            DER.set([DER.seq([DER.oid(sha256)])]),
            DER.seq([DER.oid(data)]),
            DER.tlv(0xA0, certSet),
            DER.set([signerInfo]),
        ])
        return DER.seq([DER.oid(signedData), DER.tlv(0xA0, sd)])
    }

    /// Lê de volta uma assinatura CMS: (atributos assinados como SET, assinatura, certificado do signatário,
    /// resumo declarado no messageDigest). Usado nos testes e para mostrar quem assinou.
    static func inspect(_ cms: [UInt8]) throws -> (attrs: [UInt8], signature: [UInt8], signer: X509Certificate?, digest: [UInt8]) {
        let ci = try DER.read(cms, at: 0)
        let ciParts = try DER.children(cms, ci)
        guard ciParts.count == 2 else { throw DER.Failure() }
        let sdNode = try DER.children(cms, ciParts[1])[0]
        let sd = try DER.children(cms, sdNode)
        var certs: [X509Certificate] = []
        var signerInfos: DER.Node?
        for n in sd {
            if n.tag == 0xA0 {
                for cert in try DER.children(cms, n) {
                    if let x = try? X509Certificate(der: Array(cms[cert.range])) { certs.append(x) }
                }
            } else if n.tag == 0x31 {
                signerInfos = n
            }
        }
        guard let infos = signerInfos, let si = try DER.children(cms, infos).last else { throw DER.Failure() }
        let parts = try DER.children(cms, si)
        guard let attrsNode = parts.first(where: { $0.tag == 0xA0 }), let sigNode = parts.last else { throw DER.Failure() }
        var attrs = Array(cms[attrsNode.range])
        attrs[0] = 0x31
        var digest: [UInt8] = []
        let mdOID = DER.oid("1.2.840.113549.1.9.4")
        for a in try DER.children(cms, attrsNode) {
            let kv = try DER.children(cms, a)
            if kv.count == 2, Array(cms[kv[0].range]) == mdOID, let v = try DER.children(cms, kv[1]).first {
                digest = Array(cms[v.content])
            }
        }
        var sid: [DER.Node] = []
        if parts.count > 1 { sid = try DER.children(cms, parts[1]) }
        let serial = sid.count == 2 ? Array(cms[sid[1].range]) : []
        let signer = certs.first { $0.serialTLV == serial } ?? certs.first
        return (attrs, Array(cms[sigNode.content]), signer, digest)
    }
}

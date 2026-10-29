import Foundation

/// Leitura da estrutura do PDF (objetos e tabela xref, inclusive xref em fluxo e objetos
/// compactados) e gravação de atualização incremental: o arquivo original fica intacto e as
/// mudanças entram no fim. É assim que a assinatura digital é gravada sem mexer no conteúdo.
indirect enum PDFObject: Equatable {
    case null
    case bool(Bool)
    case number(String)          // como está no arquivo (não muda ao gravar de novo)
    case name(String)            // sem a barra
    case string([UInt8])
    case array([PDFObject])
    case dict(PDFDict)
    case ref(Int, Int)
    case stream(PDFDict, [UInt8])

    var dictValue: PDFDict? {
        switch self {
        case .dict(let d): return d
        case .stream(let d, _): return d
        default: return nil
        }
    }

    var arrayValue: [PDFObject]? { if case .array(let a) = self { return a } else { return nil } }
    var nameValue: String? { if case .name(let n) = self { return n } else { return nil } }
    var intValue: Int? {
        if case .number(let s) = self { return Int(s) ?? Double(s).map { Int($0) } }
        return nil
    }
    var doubleValue: Double? { if case .number(let s) = self { return Double(s) } else { return nil } }
    var refValue: (Int, Int)? { if case .ref(let n, let g) = self { return (n, g) } else { return nil } }
}

struct PDFDict: Equatable {
    var entries: [(String, PDFObject)] = []

    static func == (a: PDFDict, b: PDFDict) -> Bool {
        a.entries.count == b.entries.count && zip(a.entries, b.entries).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    subscript(key: String) -> PDFObject? {
        get { entries.first { $0.0 == key }?.1 }
        set {
            if let i = entries.firstIndex(where: { $0.0 == key }) {
                if let v = newValue { entries[i].1 = v } else { entries.remove(at: i) }
            } else if let v = newValue {
                entries.append((key, v))
            }
        }
    }
}

struct PDFSyntaxError: Error {
    let message: String
}

// MARK: - Leitura de objetos

struct PDFLexer {
    let b: [UInt8]
    var i: Int

    init(_ bytes: [UInt8], at offset: Int = 0) {
        b = bytes
        i = offset
    }

    static func isWhite(_ c: UInt8) -> Bool { c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32 }
    static func isDelim(_ c: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(c) }

    mutating func skipWhite() {
        while i < b.count {
            let c = b[i]
            if PDFLexer.isWhite(c) {
                i += 1
            } else if c == UInt8(ascii: "%") {
                while i < b.count, b[i] != 10, b[i] != 13 { i += 1 }
            } else {
                break
            }
        }
    }

    mutating func keyword() -> String {
        skipWhite()
        let start = i
        while i < b.count, !PDFLexer.isWhite(b[i]), !PDFLexer.isDelim(b[i]) { i += 1 }
        return String(decoding: b[start..<i], as: UTF8.self)
    }

    func peek(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard i + u.count <= b.count else { return false }
        return Array(b[i..<i + u.count]) == u
    }

    mutating func parse() throws -> PDFObject {
        skipWhite()
        guard i < b.count else { throw PDFSyntaxError(message: "fim inesperado") }
        let c = b[i]
        if peek("<<") {
            i += 2
            var d = PDFDict()
            while true {
                skipWhite()
                if peek(">>") { i += 2; break }
                guard i < b.count, b[i] == UInt8(ascii: "/") else { throw PDFSyntaxError(message: "chave inválida") }
                guard case .name(let key) = try parse() else { throw PDFSyntaxError(message: "chave inválida") }
                let value = try parse()
                d[key] = value
            }
            return .dict(d)
        }
        if c == UInt8(ascii: "<") { return .string(try hexString()) }
        if c == UInt8(ascii: "[") {
            i += 1
            var arr: [PDFObject] = []
            while true {
                skipWhite()
                guard i < b.count else { throw PDFSyntaxError(message: "lista sem fim") }
                if b[i] == UInt8(ascii: "]") { i += 1; break }
                arr.append(try parse())
            }
            return .array(arr)
        }
        if c == UInt8(ascii: "(") { return .string(try literalString()) }
        if c == UInt8(ascii: "/") {
            i += 1
            let start = i
            while i < b.count, !PDFLexer.isWhite(b[i]), !PDFLexer.isDelim(b[i]) { i += 1 }
            return .name(String(decoding: b[start..<i], as: UTF8.self))
        }
        if c == UInt8(ascii: "+") || c == UInt8(ascii: "-") || c == UInt8(ascii: ".") || (c >= 48 && c <= 57) {
            let first = number()
            // "n g R" (referência)?
            let save = i
            skipWhite()
            if i < b.count, b[i] >= 48, b[i] <= 57 {
                let second = number()
                skipWhite()
                if i < b.count, b[i] == UInt8(ascii: "R"),
                   i + 1 >= b.count || PDFLexer.isWhite(b[i + 1]) || PDFLexer.isDelim(b[i + 1]),
                   let n = Int(first), let g = Int(second) {
                    i += 1
                    return .ref(n, g)
                }
            }
            i = save
            return .number(first)
        }
        let word = keyword()
        switch word {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        default: throw PDFSyntaxError(message: "palavra inesperada: \(word)")
        }
    }

    private mutating func number() -> String {
        let start = i
        while i < b.count, "+-.0123456789".utf8.contains(b[i]) { i += 1 }
        return String(decoding: b[start..<i], as: UTF8.self)
    }

    private mutating func hexString() throws -> [UInt8] {
        i += 1
        var digits: [UInt8] = []
        while i < b.count, b[i] != UInt8(ascii: ">") {
            let c = b[i]
            i += 1
            if PDFLexer.isWhite(c) { continue }
            digits.append(c)
        }
        i += 1
        if digits.count % 2 == 1 { digits.append(UInt8(ascii: "0")) }
        var out: [UInt8] = []
        var k = 0
        while k < digits.count {
            let s = String(decoding: digits[k..<k + 2], as: UTF8.self)
            out.append(UInt8(s, radix: 16) ?? 0)
            k += 2
        }
        return out
    }

    private mutating func literalString() throws -> [UInt8] {
        i += 1
        var out: [UInt8] = []
        var depth = 1
        while i < b.count {
            let c = b[i]
            i += 1
            if c == UInt8(ascii: "\\") {
                guard i < b.count else { break }
                let e = b[i]
                i += 1
                switch e {
                case UInt8(ascii: "n"): out.append(10)
                case UInt8(ascii: "r"): out.append(13)
                case UInt8(ascii: "t"): out.append(9)
                case UInt8(ascii: "b"): out.append(8)
                case UInt8(ascii: "f"): out.append(12)
                case 10: break
                case 13: if i < b.count, b[i] == 10 { i += 1 }
                case 48...55:
                    var v = Int(e - 48)
                    var n = 1
                    while n < 3, i < b.count, b[i] >= 48, b[i] <= 55 {
                        v = v * 8 + Int(b[i] - 48)
                        i += 1
                        n += 1
                    }
                    out.append(UInt8(v & 0xFF))
                default: out.append(e)
                }
            } else if c == UInt8(ascii: "(") {
                depth += 1
                out.append(c)
            } else if c == UInt8(ascii: ")") {
                depth -= 1
                if depth == 0 { return out }
                out.append(c)
            } else {
                out.append(c)
            }
        }
        throw PDFSyntaxError(message: "texto sem fim")
    }
}

// MARK: - Gravação de objetos

enum PDFWriter {
    static func hex(_ bytes: [UInt8]) -> String { "<" + bytes.map { String(format: "%02X", $0) }.joined() + ">" }

    /// Texto do PDF em UTF-16 (aceita acentos e qualquer letra).
    static func text(_ s: String) -> String {
        hex([0xFE, 0xFF] + s.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
    }

    static func write(_ o: PDFObject) -> String {
        switch o {
        case .null: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .number(let s): return s
        case .name(let n): return "/" + n
        case .string(let b): return hex(b)
        case .array(let a): return "[" + a.map(write).joined(separator: " ") + "]"
        case .dict(let d): return dict(d)
        case .ref(let n, let g): return "\(n) \(g) R"
        case .stream(let d, _): return dict(d)    // fluxos existentes nunca são regravados
        }
    }

    static func dict(_ d: PDFDict) -> String {
        "<<" + d.entries.map { "/\($0.0) \(write($0.1))" }.joined(separator: " ") + ">>"
    }
}

// MARK: - Arquivo

final class PDFFile {
    let bytes: [UInt8]
    private(set) var offsets: [Int: (offset: Int, gen: Int)] = [:]
    private(set) var compressed: [Int: (stream: Int, index: Int)] = [:]
    private(set) var trailer = PDFDict()
    private(set) var lastXref = 0
    private(set) var lastXrefIsStream = false
    private var cache: [Int: PDFObject] = [:]
    private var objStreams: [Int: [Int: PDFObject]] = [:]

    init(_ data: Data) throws {
        bytes = [UInt8](data)
        try readXrefs()
    }

    // MARK: xref

    private func startxref() throws -> Int {
        let tail = max(0, bytes.count - 2048)
        let key = Array("startxref".utf8)
        var k = bytes.count - key.count
        while k >= tail {
            if Array(bytes[k..<k + key.count]) == key {
                var lx = PDFLexer(bytes, at: k + key.count)
                if let v = Int(lx.keyword()) { return v }
            }
            k -= 1
        }
        throw PDFSyntaxError(message: "startxref não encontrado")
    }

    private func readXrefs() throws {
        var off = try startxref()
        lastXref = off
        var seen = Set<Int>()
        var first = true
        while off >= 0, off < bytes.count, !seen.contains(off) {
            seen.insert(off)
            var lx = PDFLexer(bytes, at: off)
            lx.skipWhite()
            var prev: Int?
            if lx.peek("xref") {
                let t = try classicXref(at: lx.i)
                if first { trailer = t; lastXrefIsStream = false }
                if let x = t["XRefStm"]?.intValue { try streamXref(at: x) }
                prev = t["Prev"]?.intValue
            } else {
                let t = try streamXref(at: off)
                if first { trailer = t; lastXrefIsStream = true }
                prev = t["Prev"]?.intValue
            }
            first = false
            off = prev ?? -1
        }
        guard trailer["Root"] != nil else { throw PDFSyntaxError(message: "PDF sem catálogo") }
    }

    private func classicXref(at start: Int) throws -> PDFDict {
        var lx = PDFLexer(bytes, at: start)
        _ = lx.keyword()                 // "xref"
        while true {
            lx.skipWhite()
            if lx.peek("trailer") {
                _ = lx.keyword()
                guard case .dict(let t) = try lx.parse() else { throw PDFSyntaxError(message: "trailer inválido") }
                return t
            }
            guard let first = Int(lx.keyword()), let count = Int(lx.keyword()) else {
                throw PDFSyntaxError(message: "xref inválida")
            }
            for n in 0..<count {
                guard let off = Int(lx.keyword()), let gen = Int(lx.keyword()) else {
                    throw PDFSyntaxError(message: "xref inválida")
                }
                let kind = lx.keyword()
                let num = first + n
                if kind == "n", offsets[num] == nil, compressed[num] == nil, num > 0 {
                    offsets[num] = (off, gen)
                }
            }
        }
    }

    @discardableResult
    private func streamXref(at off: Int) throws -> PDFDict {
        let (_, _, obj) = try indirect(at: off)
        guard case .stream(let d, let raw) = obj else { throw PDFSyntaxError(message: "xref em fluxo inválida") }
        let data = try decode(d, raw)
        guard let w = d["W"]?.arrayValue?.compactMap({ $0.intValue }), w.count == 3 else {
            throw PDFSyntaxError(message: "xref sem /W")
        }
        let size = d["Size"]?.intValue ?? 0
        var index: [Int] = d["Index"]?.arrayValue?.compactMap { $0.intValue } ?? [0, size]
        if index.count % 2 == 1 { index.removeLast() }
        let rowLen = w.reduce(0, +)
        var pos = 0
        func field(_ len: Int) -> Int {
            var v = 0
            for _ in 0..<len {
                v = (v << 8) | Int(data[pos])
                pos += 1
            }
            return v
        }
        var k = 0
        while k + 1 < index.count {
            let first = index[k], count = index[k + 1]
            for n in 0..<count {
                guard pos + rowLen <= data.count else { break }
                let t = w[0] == 0 ? 1 : field(w[0])
                let a = field(w[1])
                let c = field(w[2])
                let num = first + n
                guard num > 0, offsets[num] == nil, compressed[num] == nil else { continue }
                if t == 1 { offsets[num] = (a, c) } else if t == 2 { compressed[num] = (a, c) }
            }
            k += 2
        }
        return d
    }

    // MARK: objetos

    /// Objeto "n g obj ... endobj" na posição.
    func indirect(at off: Int) throws -> (Int, Int, PDFObject) {
        var lx = PDFLexer(bytes, at: off)
        guard let n = Int(lx.keyword()), let g = Int(lx.keyword()), lx.keyword() == "obj" else {
            throw PDFSyntaxError(message: "objeto inválido em \(off)")
        }
        let value = try lx.parse()
        lx.skipWhite()
        if case .dict(let d) = value, lx.peek("stream") {
            lx.i += 6
            if lx.i < bytes.count, bytes[lx.i] == 13 { lx.i += 1 }
            if lx.i < bytes.count, bytes[lx.i] == 10 { lx.i += 1 }
            let start = lx.i
            var length = -1
            if let l = d["Length"] {
                if let v = l.intValue {
                    length = v
                } else if case .ref(let rn, _) = l, rn != n, let v = (try? object(rn))?.intValue {
                    length = v
                }
            }
            var end = start + length
            if length < 0 || end > bytes.count || !PDFLexer(bytes, at: end).hasKeyword("endstream") {
                end = find("endstream", from: start) ?? bytes.count
                while end > start, PDFLexer.isWhite(bytes[end - 1]) { end -= 1 }
            }
            return (n, g, .stream(d, Array(bytes[start..<end])))
        }
        return (n, g, value)
    }

    private func find(_ s: String, from: Int) -> Int? {
        let u = Array(s.utf8)
        var k = from
        while k + u.count <= bytes.count {
            if bytes[k] == u[0], Array(bytes[k..<k + u.count]) == u { return k }
            k += 1
        }
        return nil
    }

    func object(_ num: Int) throws -> PDFObject {
        if let c = cache[num] { return c }
        var result: PDFObject = .null
        if let o = offsets[num] {
            let (n, _, v) = try indirect(at: o.offset)
            guard n == num else { throw PDFSyntaxError(message: "xref aponta para o objeto errado (\(num))") }
            result = v
        } else if let c = compressed[num] {
            result = try fromObjectStream(c.stream, num)
        }
        cache[num] = result
        return result
    }

    func generation(_ num: Int) -> Int { offsets[num]?.gen ?? 0 }

    private func fromObjectStream(_ stm: Int, _ num: Int) throws -> PDFObject {
        if let objs = objStreams[stm] { return objs[num] ?? .null }
        guard case .stream(let d, let raw) = try object(stm) else { throw PDFSyntaxError(message: "fluxo de objetos inválido") }
        let data = try decode(d, raw)
        let n = d["N"]?.intValue ?? 0
        let first = d["First"]?.intValue ?? 0
        var lx = PDFLexer(data)
        var pairs: [(Int, Int)] = []
        for _ in 0..<n {
            guard let a = Int(lx.keyword()), let b = Int(lx.keyword()) else { break }
            pairs.append((a, b))
        }
        var objs: [Int: PDFObject] = [:]
        for (objNum, rel) in pairs {
            var ox = PDFLexer(data, at: first + rel)
            if let v = try? ox.parse() { objs[objNum] = v }
        }
        objStreams[stm] = objs
        return objs[num] ?? .null
    }

    func resolve(_ o: PDFObject?) -> PDFObject? {
        guard let o else { return nil }
        if case .ref(let n, _) = o { return try? object(n) }
        return o
    }

    // MARK: fluxos

    func decode(_ d: PDFDict, _ raw: [UInt8]) throws -> [UInt8] {
        var filters: [String] = []
        if let f = resolve(d["Filter"]) {
            if let n = f.nameValue { filters = [n] }
            if let a = f.arrayValue { filters = a.compactMap { $0.nameValue } }
        }
        var data = raw
        for f in filters {
            guard f == "FlateDecode" || f == "Fl" else { throw PDFSyntaxError(message: "filtro não suportado: \(f)") }
            data = try PDFFile.inflate(data)
        }
        if let parms = resolve(d["DecodeParms"])?.dictValue ?? resolve(d["DecodeParms"])?.arrayValue?.first?.dictValue,
           let predictor = parms["Predictor"]?.intValue, predictor >= 10 {
            data = try PDFFile.unpredict(data, columns: parms["Columns"]?.intValue ?? 1)
        }
        return data
    }

    static func inflate(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count > 2 else { return [] }
        // o PDF usa zlib (2 bytes de cabeçalho); o "zlib" da Apple é o DEFLATE puro
        let body = Data(data[2...])
        guard let out = try? (body as NSData).decompressed(using: .zlib) else {
            throw PDFSyntaxError(message: "fluxo compactado inválido")
        }
        return [UInt8](out as Data)
    }

    static func unpredict(_ data: [UInt8], columns: Int) throws -> [UInt8] {
        let row = columns + 1
        var out: [UInt8] = []
        var prev = [UInt8](repeating: 0, count: columns)
        var k = 0
        while k + row <= data.count {
            let type = data[k]
            var cur = Array(data[(k + 1)..<(k + row)])
            for x in 0..<columns {
                let left = x > 0 ? Int(cur[x - 1]) : 0
                let up = Int(prev[x])
                let upLeft = x > 0 ? Int(prev[x - 1]) : 0
                var v = Int(cur[x])
                switch type {
                case 1: v += left
                case 2: v += up
                case 3: v += (left + up) / 2
                case 4:
                    let p = left + up - upLeft
                    let pa = abs(p - left), pb = abs(p - up), pc = abs(p - upLeft)
                    v += (pa <= pb && pa <= pc) ? left : (pb <= pc ? up : upLeft)
                default: break
                }
                cur[x] = UInt8(v & 0xFF)
            }
            out += cur
            prev = cur
            k += row
        }
        return out
    }

    // MARK: estrutura

    var rootRef: (Int, Int)? { trailer["Root"]?.refValue }
    var isEncrypted: Bool { trailer["Encrypt"] != nil }
    var size: Int {
        max(trailer["Size"]?.intValue ?? 0, (offsets.keys.max() ?? 0) + 1, (compressed.keys.max() ?? 0) + 1)
    }

    var catalog: PDFDict? { rootRef.flatMap { (try? object($0.0))?.dictValue } }

    /// Páginas em ordem: (número do objeto, geração).
    func pageRefs() -> [(Int, Int)] {
        guard let pages = catalog?["Pages"]?.refValue else { return [] }
        var out: [(Int, Int)] = []
        var visited = Set<Int>()
        func walk(_ ref: (Int, Int), depth: Int) {
            guard depth < 64, !visited.contains(ref.0), let d = (try? object(ref.0))?.dictValue else { return }
            visited.insert(ref.0)
            if d["Type"]?.nameValue == "Page" || d["Kids"] == nil {
                out.append(ref)
                return
            }
            for kid in resolve(d["Kids"])?.arrayValue ?? [] {
                if let r = kid.refValue { walk(r, depth: depth + 1) }
            }
        }
        walk(pages, depth: 0)
        return out
    }

    /// Valor herdado do nó de páginas (MediaBox, CropBox, Rotate).
    func inherited(_ key: String, page: PDFDict) -> PDFObject? {
        var node: PDFDict? = page
        var depth = 0
        while let n = node, depth < 64 {
            if let v = n[key] { return resolve(v) }
            node = resolve(n["Parent"])?.dictValue
            depth += 1
        }
        return nil
    }

    /// Campos do formulário (com os filhos), para contar as assinaturas.
    func fields() -> [PDFDict] {
        guard let acro = resolve(catalog?["AcroForm"])?.dictValue else { return [] }
        var out: [PDFDict] = []
        var stack = resolve(acro["Fields"])?.arrayValue ?? []
        var guardCount = 0
        while let f = stack.popLast(), guardCount < 10_000 {
            guardCount += 1
            guard let d = resolve(f)?.dictValue else { continue }
            out.append(d)
            stack += resolve(d["Kids"])?.arrayValue ?? []
        }
        return out
    }

    var signatureCount: Int {
        fields().filter { $0["FT"]?.nameValue == "Sig" && $0["V"] != nil }.count
    }

    /// Permissão da assinatura de certificação (1: nada pode mudar; 2: formulários e assinaturas; 3: e anotações).
    var docMDPLevel: Int? {
        guard let perms = resolve(catalog?["Perms"])?.dictValue, let sig = resolve(perms["DocMDP"])?.dictValue else { return nil }
        for r in resolve(sig["Reference"])?.arrayValue ?? [] {
            if let rd = resolve(r)?.dictValue, rd["TransformMethod"]?.nameValue == "DocMDP" {
                return resolve(rd["TransformParams"])?.dictValue?["P"]?.intValue ?? 2
            }
        }
        return 2
    }
}

private extension PDFLexer {
    func hasKeyword(_ s: String) -> Bool {
        var copy = self
        copy.skipWhite()
        return copy.peek(s)
    }
}

// MARK: - Atualização incremental

/// Junta objetos novos e alterados e grava no fim do arquivo, com a nova tabela xref.
struct PDFIncrementalUpdate {
    let file: PDFFile
    private(set) var nextNumber: Int
    private var objects: [(num: Int, gen: Int, body: [UInt8])] = []

    init(_ file: PDFFile) {
        self.file = file
        nextNumber = file.size
    }

    mutating func reserve() -> Int {
        defer { nextNumber += 1 }
        return nextNumber
    }

    mutating func set(_ num: Int, gen: Int = 0, _ body: String) {
        set(num, gen: gen, Array(body.utf8))
    }

    mutating func set(_ num: Int, gen: Int = 0, _ body: [UInt8]) {
        objects.removeAll { $0.num == num }
        objects.append((num, gen, body))
    }

    /// Grava tudo e devolve o PDF completo (o original + a atualização).
    func output() -> [UInt8] {
        var out = file.bytes
        if let last = out.last, last != 10, last != 13 { out.append(10) }
        var entries: [(Int, Int, Int)] = []     // (número, posição, geração)
        for o in objects.sorted(by: { $0.num < $1.num }) {
            entries.append((o.num, out.count, o.gen))
            out += Array("\(o.num) \(o.gen) obj\n".utf8) + o.body + Array("\nendobj\n".utf8)
        }
        var t = PDFDict()
        let size = max(file.size, (objects.map { $0.num }.max() ?? 0) + 1)
        if let root = file.trailer["Root"] { t["Root"] = root }
        if let info = file.trailer["Info"] { t["Info"] = info }
        if let id = file.trailer["ID"] { t["ID"] = id }
        t["Prev"] = .number("\(file.lastXref)")
        if file.lastXrefIsStream {
            let xnum = size
            entries.append((xnum, out.count, 0))
            entries.sort { $0.0 < $1.0 }
            var index: [PDFObject] = []
            var rows: [UInt8] = []
            for (start, group) in PDFIncrementalUpdate.groups(entries) {
                index += [.number("\(start)"), .number("\(group.count)")]
                for e in group {
                    rows.append(1)
                    rows += [UInt8((e.1 >> 24) & 0xFF), UInt8((e.1 >> 16) & 0xFF), UInt8((e.1 >> 8) & 0xFF), UInt8(e.1 & 0xFF)]
                    rows += [UInt8((e.2 >> 8) & 0xFF), UInt8(e.2 & 0xFF)]
                }
            }
            t["Type"] = .name("XRef")
            t["Size"] = .number("\(xnum + 1)")
            t["W"] = .array([.number("1"), .number("4"), .number("2")])
            t["Index"] = .array(index)
            t["Length"] = .number("\(rows.count)")
            let xrefStart = out.count
            out += Array("\(xnum) 0 obj\n\(PDFWriter.dict(t))\nstream\n".utf8) + rows + Array("\nendstream\nendobj\n".utf8)
            out += Array("startxref\n\(xrefStart)\n%%EOF\n".utf8)
        } else {
            entries.sort { $0.0 < $1.0 }
            let xrefStart = out.count
            var x = "xref\n"
            for (start, group) in PDFIncrementalUpdate.groups(entries) {
                x += "\(start) \(group.count)\n"
                for e in group { x += String(format: "%010ld %05ld n\r\n", e.1, e.2) }
            }
            t["Size"] = .number("\(size)")
            x += "trailer\n\(PDFWriter.dict(t))\nstartxref\n\(xrefStart)\n%%EOF\n"
            out += Array(x.utf8)
        }
        return out
    }

    private static func groups(_ entries: [(Int, Int, Int)]) -> [(Int, [(Int, Int, Int)])] {
        var out: [(Int, [(Int, Int, Int)])] = []
        for e in entries {
            if let last = out.last, let prev = last.1.last, prev.0 + 1 == e.0 {
                out[out.count - 1].1.append(e)
            } else {
                out.append((e.0, [e]))
            }
        }
        return out
    }
}

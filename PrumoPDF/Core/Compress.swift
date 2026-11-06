import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Comprimir PDF (reduzir o tamanho do arquivo), em dois níveis, iguais aos do Prumo para Windows:
///
/// - média: imagens com mais de 150 pontos por polegada (como aparecem na página) são reduzidas para 150
///   e regravadas em JPEG de qualidade 75. Texto, fontes, destaques e a camada de OCR não mudam.
/// - alta: imagens reduzidas para 96 pontos por polegada, JPEG de qualidade 50. O arquivo fica bem menor;
///   fotos e páginas escaneadas perdem nitidez.
///
/// O arquivo é regravado por inteiro (só os objetos em uso, com fluxos de objetos e tabela xref em fluxo).
/// Continua um PDF padrão. Imagens que não são mexidas, por segurança: 1 bit, CMYK, paleta, com /Decode ou
/// máscara por cor, JBIG2/CCITT/JPEG 2000. Imagem com poucas cores (captura de tela, gráfico) fica sem perda.
/// Uma imagem só é trocada se a nova versão for menor.
enum CompressionLevel: String, CaseIterable, Identifiable {
    case medium, high
    var id: String { rawValue }
    var dpi: Double { self == .medium ? 150 : 96 }
    var quality: Double { self == .medium ? 0.75 : 0.50 }
}

struct CompressionResult {
    let before: Int
    let after: Int
    let imagesChanged: Int
    let imagesTotal: Int
    var savedRatio: Double { before == 0 ? 0 : max(0, 1 - Double(after) / Double(before)) }
}

enum PDFCompressor {
    /// Reduz só se a imagem estiver pelo menos 10% acima da resolução alvo.
    static let margin = 1.10
    static let minPixels = 64 * 64

    static func compress(_ src: URL, to dest: URL, level: CompressionLevel,
                         progress: ((Int, Int) -> Void)? = nil) throws -> CompressionResult {
        let data = try Data(contentsOf: src)
        let file: PDFFile
        do { file = try PDFFile(data) } catch { throw UserFacingError(L("Não foi possível abrir o PDF.")) }
        if file.isEncrypted { throw UserFacingError(L("O PDF está protegido por senha.")) }

        // 1) objetos em uso (a partir do catálogo e das informações), sem miniaturas embutidas
        let pages = file.pageRefs()
        let pageNums = Set(pages.map { $0.0 })
        var objects: [Int: PDFObject] = [:]
        var gens: [Int: Int] = [:]
        var stack: [Int] = []
        for key in ["Root", "Info"] { if let r = file.trailer[key]?.refValue { stack.append(r.0) } }
        while let n = stack.popLast() {
            if objects[n] != nil { continue }
            var o = (try? file.object(n)) ?? .null
            if pageNums.contains(n), case .dict(var d) = o, d["Thumb"] != nil {
                d["Thumb"] = nil
                o = .dict(d)
            }
            objects[n] = o
            gens[n] = file.generation(n)
            collectRefs(o, into: &stack)
        }

        // 2) imagens e o tamanho com que aparecem
        var smasks = Set<Int>()
        var images: [Int] = []
        for (n, o) in objects {
            guard case .stream(let d, _) = o, file.resolve(d["Subtype"])?.nameValue == "Image" else { continue }
            images.append(n)
            if let s = d["SMask"]?.refValue { smasks.insert(s.0) }
        }
        images = images.filter { !smasks.contains($0) }.sorted()
        let sizes = displaySizes(file, objects: objects, pages: pages)
        let diag = pageDiagonal(file, pages: pages)

        var changed = 0
        for (k, n) in images.enumerated() {
            progress?(k + 1, images.count)
            guard case .stream(let d, let raw)? = objects[n] else { continue }
            var mask: (Int, PDFDict, [UInt8])?
            if let s = d["SMask"]?.refValue, case .stream(let sd, let sraw)? = objects[s.0] { mask = (s.0, sd, sraw) }
            autoreleasepool {
                if let r = shrink(file, d, raw, mask: mask.map { ($0.1, $0.2) }, display: sizes[n], diag: diag,
                                  level: level) {
                    objects[n] = .stream(r.dict, r.data)
                    if let m = mask, let nm = r.mask { objects[m.0] = .stream(nm.0, nm.1) }
                    changed += 1
                }
            }
        }

        // 3) grava o arquivo novo
        let out = write(file, objects: objects, gens: gens)
        let tmp = dest.appendingPathExtension("part")
        try Data(out).write(to: tmp, options: .atomic)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
        return CompressionResult(before: data.count, after: out.count, imagesChanged: changed, imagesTotal: images.count)
    }

    static func collectRefs(_ o: PDFObject, into out: inout [Int]) {
        switch o {
        case .ref(let n, _): out.append(n)
        case .array(let a): for x in a { collectRefs(x, into: &out) }
        case .dict(let d): for (_, v) in d.entries { collectRefs(v, into: &out) }
        case .stream(let d, _): for (_, v) in d.entries { collectRefs(v, into: &out) }
        default: break
        }
    }

    // MARK: - Onde e de que tamanho cada imagem aparece

    typealias Matrix = (Double, Double, Double, Double, Double, Double)

    static func mul(_ m: Matrix, _ n: Matrix) -> Matrix {
        (m.0 * n.0 + m.1 * n.2, m.0 * n.1 + m.1 * n.3,
         m.2 * n.0 + m.3 * n.2, m.2 * n.1 + m.3 * n.3,
         m.4 * n.0 + m.5 * n.2 + n.4, m.4 * n.1 + m.5 * n.3 + n.5)
    }

    static func matrix(_ o: PDFObject?) -> Matrix? {
        guard let a = o?.arrayValue, a.count == 6 else { return nil }
        let v = a.compactMap { $0.doubleValue }
        guard v.count == 6 else { return nil }
        return (v[0], v[1], v[2], v[3], v[4], v[5])
    }

    /// Para cada imagem (número do objeto), o maior tamanho (largura, altura) em pontos com que é desenhada.
    static func displaySizes(_ file: PDFFile, objects: [Int: PDFObject], pages: [(Int, Int)]) -> [Int: (Double, Double)] {
        var sizes: [Int: (Double, Double)] = [:]
        var budget = 4000   // formulários visitados, no máximo

        func xobject(_ name: String, _ resources: PDFDict?) -> (Int, PDFDict, [UInt8])? {
            guard let xo = file.resolve(resources?["XObject"])?.dictValue, let r = xo[name]?.refValue,
                  case .stream(let d, let raw)? = objects[r.0] else { return nil }
            return (r.0, d, raw)
        }

        func walk(_ data: [UInt8], _ resources: PDFDict?, _ start: Matrix, depth: Int) {
            guard depth < 12, budget > 0 else { return }
            budget -= 1
            var lx = PDFLexer(data)
            var ctm = start
            var saved: [Matrix] = []
            var operands: [PDFObject] = []
            while true {
                lx.skipWhite()
                guard lx.i < data.count else { break }
                let c = data[lx.i]
                let isNumber = c == UInt8(ascii: "+") || c == UInt8(ascii: "-") || c == UInt8(ascii: ".") || (c >= 48 && c <= 57)
                if isNumber || c == UInt8(ascii: "/") || c == UInt8(ascii: "(") || c == UInt8(ascii: "<") || c == UInt8(ascii: "[") {
                    let before = lx.i
                    if let o = try? lx.parse() {
                        operands.append(o)
                    } else {
                        lx.i = max(before + 1, lx.i)
                        operands.removeAll()
                    }
                    continue
                }
                if PDFLexer.isDelim(c) {
                    lx.i += 1
                    continue
                }
                let op = lx.keyword()
                if op.isEmpty { lx.i += 1; continue }
                switch op {
                case "q": saved.append(ctm)
                case "Q": if let s = saved.popLast() { ctm = s }
                case "cm":
                    let v = operands.compactMap { $0.doubleValue }
                    if v.count == 6 { ctm = mul((v[0], v[1], v[2], v[3], v[4], v[5]), ctm) }
                case "Do":
                    if let name = operands.last?.nameValue, let xo = xobject(name, resources) {
                        let (n, d, raw) = xo
                        let sub = file.resolve(d["Subtype"])?.nameValue
                        if sub == "Image" {
                            let w = (ctm.0 * ctm.0 + ctm.1 * ctm.1).squareRoot()
                            let h = (ctm.2 * ctm.2 + ctm.3 * ctm.3).squareRoot()
                            let old = sizes[n] ?? (0, 0)
                            sizes[n] = (max(old.0, w), max(old.1, h))
                        } else if sub == "Form", let content = try? file.decode(d, raw) {
                            let m = matrix(file.resolve(d["Matrix"])) ?? (1, 0, 0, 1, 0, 0)
                            let res = file.resolve(d["Resources"])?.dictValue ?? resources
                            walk(content, res, mul(m, ctm), depth: depth + 1)
                        }
                    }
                case "BI":
                    // imagem embutida no conteúdo: pula até "EI"
                    var k = lx.i
                    while k + 2 < data.count {
                        if data[k] == UInt8(ascii: "E"), data[k + 1] == UInt8(ascii: "I"),
                           PDFLexer.isWhite(data[k - 1]), PDFLexer.isWhite(data[k + 2]) || PDFLexer.isDelim(data[k + 2]) {
                            break
                        }
                        k += 1
                    }
                    lx.i = min(data.count, k + 2)
                case "true", "false", "null":
                    operands.append(.null)
                    continue
                default: break
                }
                operands.removeAll()
            }
        }

        for (pn, _) in pages {
            guard let page = objects[pn]?.dictValue ?? (try? file.object(pn))?.dictValue else { continue }
            let resources = file.inherited("Resources", page: page)?.dictValue
            var content: [UInt8] = []
            let contents = page["Contents"]
            var parts: [PDFObject] = []
            if let a = file.resolve(contents)?.arrayValue { parts = a } else if let c = contents { parts = [c] }
            for p in parts {
                var obj = p
                if let r = p.refValue { obj = objects[r.0] ?? .null }
                if case .stream(let d, let raw) = obj, let bytes = try? file.decode(d, raw) {
                    content += bytes
                    content.append(10)
                }
            }
            walk(content, resources, (1, 0, 0, 1, 0, 0), depth: 0)
        }
        return sizes
    }

    static func pageDiagonal(_ file: PDFFile, pages: [(Int, Int)]) -> Double {
        var best = 0.0
        for (pn, _) in pages {
            guard let page = (try? file.object(pn))?.dictValue,
                  let box = file.inherited("MediaBox", page: page)?.arrayValue?.compactMap({ file.resolve($0)?.doubleValue }),
                  box.count == 4 else { continue }
            best = max(best, ((box[2] - box[0]) * (box[2] - box[0]) + (box[3] - box[1]) * (box[3] - box[1])).squareRoot())
        }
        return best > 0 ? best : (612.0 * 612 + 842.0 * 842).squareRoot()
    }

    // MARK: - Uma imagem

    static func filters(_ file: PDFFile, _ d: PDFDict) -> [String]? {
        guard let f = file.resolve(d["Filter"]) else { return [] }
        if let n = f.nameValue { return [n] }
        if let a = f.arrayValue { return a.compactMap { file.resolve($0)?.nameValue } }
        return nil
    }

    /// Componentes de cor (1 = cinza, 3 = RGB) ou nil se o espaço de cor não é tratado.
    static func components(_ file: PDFFile, _ d: PDFDict) -> Int? {
        guard let cs = file.resolve(d["ColorSpace"]) else { return nil }
        if let n = cs.nameValue {
            switch n {
            case "DeviceGray", "G", "CalGray": return 1
            case "DeviceRGB", "RGB", "CalRGB": return 3
            default: return nil
            }
        }
        if let a = cs.arrayValue, a.count == 2, a[0].nameValue == "ICCBased",
           let n = file.resolve(a[1])?.dictValue?["N"]?.intValue, n == 1 || n == 3 {
            return n
        }
        return nil
    }

    struct Shrunk {
        let dict: PDFDict
        let data: [UInt8]
        let mask: (PDFDict, [UInt8])?
    }

    static func shrink(_ file: PDFFile, _ d: PDFDict, _ raw: [UInt8], mask: (PDFDict, [UInt8])?,
                       display: (Double, Double)?, diag: Double, level: CompressionLevel) -> Shrunk? {
        if case .bool(true)? = file.resolve(d["ImageMask"]) { return nil }
        if (file.resolve(d["BitsPerComponent"])?.intValue ?? 8) != 8 { return nil }
        if d["Decode"] != nil || d["Mask"] != nil { return nil }
        guard let flt = filters(file, d), flt.count <= 1 else { return nil }
        let isJPEG = flt == ["DCTDecode"] || flt == ["DCT"]
        let isFlate = flt == ["FlateDecode"] || flt == ["Fl"]
        guard isJPEG || isFlate || flt.isEmpty else { return nil }
        guard let comps = components(file, d),
              let w = file.resolve(d["Width"])?.intValue, let h = file.resolve(d["Height"])?.intValue,
              w > 0, h > 0, w * h >= minPixels else { return nil }
        if let m = mask {
            let sd = m.0
            guard sd["Matte"] == nil, (file.resolve(sd["BitsPerComponent"])?.intValue ?? 8) == 8,
                  let sf = filters(file, sd), sf.isEmpty || sf == ["FlateDecode"] || sf == ["Fl"] else { return nil }
        }

        var dpi: Double
        if let s = display, s.0 > 0.5, s.1 > 0.5 {
            dpi = max(Double(w) / (s.0 / 72), Double(h) / (s.1 / 72))
        } else {
            dpi = Double(max(w, h)) / (diag / 72)
        }
        if !dpi.isFinite { dpi = 0 }
        let scale = dpi > level.dpi * margin ? level.dpi / dpi : 1.0
        if scale >= 1.0 && isJPEG && level == .medium { return nil }   // regravar só perderia qualidade
        let nw = max(1, Int((Double(w) * scale).rounded())), nh = max(1, Int((Double(h) * scale).rounded()))

        // decodifica
        var source: CGImage?
        var lossless = false
        if isJPEG {
            guard let src = CGImageSourceCreateWithData(Data(raw) as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            if img.colorSpace?.model == .cmyk { return nil }
            source = img
        } else {
            guard let pixels = try? file.decode(d, raw), pixels.count >= w * h * comps else { return nil }
            let packed = Array(pixels.prefix(w * h * comps))
            lossless = fewColors(packed, comps: comps)
            source = makeImage(packed, width: w, height: h, comps: comps)
        }
        guard let image = source else { return nil }

        // redesenha no tamanho novo
        guard let drawn = redraw(image, width: nw, height: nh, comps: comps) else { return nil }
        let (resized, bytes) = drawn
        var out: [UInt8]
        var dict = d
        if lossless {
            out = zlib(bytes)
            dict["Filter"] = .name("FlateDecode")
        } else {
            guard let jpeg = jpegData(resized, quality: level.quality) else { return nil }
            out = jpeg
            dict["Filter"] = .name("DCTDecode")
            if !isJPEG {
                // origem sem perda: uma página limpa (texto renderizado) às vezes fica menor sem perda que em JPEG
                let flate = zlib(bytes)
                if flate.count <= out.count {
                    out = flate
                    dict["Filter"] = .name("FlateDecode")
                }
            }
        }
        if scale >= 1.0 && Double(out.count) >= Double(raw.count) * 0.95 { return nil }
        if out.count >= raw.count { return nil }
        dict["DecodeParms"] = nil
        dict["Width"] = .number("\(nw)")
        dict["Height"] = .number("\(nh)")
        dict["BitsPerComponent"] = .number("8")

        var newMask: (PDFDict, [UInt8])?
        if let m = mask {
            let (sd, sraw) = m
            if nw != w || nh != h {
                guard let mw = file.resolve(sd["Width"])?.intValue, let mh = file.resolve(sd["Height"])?.intValue,
                      let mp = try? file.decode(sd, sraw), mp.count >= mw * mh,
                      let mimg = makeImage(Array(mp.prefix(mw * mh)), width: mw, height: mh, comps: 1),
                      let mdrawn = redraw(mimg, width: nw, height: nh, comps: 1) else { return nil }
                let mbytes = mdrawn.1
                var md = sd
                md["Filter"] = .name("FlateDecode")
                md["DecodeParms"] = nil
                md["Width"] = .number("\(nw)")
                md["Height"] = .number("\(nh)")
                newMask = (md, zlib(mbytes))
            }
        }
        return Shrunk(dict: dict, data: out, mask: newMask)
    }

    /// Poucas cores (captura de tela, gráfico, texto chapado): JPEG borraria as bordas. Até 64 cores numa
    /// imagem colorida, até 16 tons numa em cinza (uma página escaneada em cinza tem muito mais tons).
    static func fewColors(_ px: [UInt8], comps: Int) -> Bool {
        let count = px.count / comps
        let limit = comps == 1 ? 16 : 64
        let step = max(1, count / 250_000)
        var seen = Set<UInt32>()
        var k = 0
        while k < count {
            let o = k * comps
            let v = comps == 1 ? UInt32(px[o]) : (UInt32(px[o]) << 16 | UInt32(px[o + 1]) << 8 | UInt32(px[o + 2]))
            seen.insert(v)
            if seen.count > limit { return false }
            k += step
        }
        return true
    }

    static func makeImage(_ px: [UInt8], width: Int, height: Int, comps: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        let space = comps == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * comps,
                       bytesPerRow: width * comps, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Desenha a imagem no tamanho pedido; devolve a imagem e os pixels compactos (cinza ou RGB, sem sobras).
    static func redraw(_ image: CGImage, width: Int, height: Int, comps: Int) -> (CGImage, [UInt8])? {
        let gray = comps == 1
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = ctx.makeImage(), let base = ctx.data else { return nil }
        let row = ctx.bytesPerRow
        let src = base.bindMemory(to: UInt8.self, capacity: row * height)
        var bytes = [UInt8](repeating: 0, count: width * height * comps)
        for y in 0..<height {
            let line = src + y * row
            if gray {
                for x in 0..<width { bytes[y * width + x] = line[x] }
            } else {
                for x in 0..<width {
                    let o = (y * width + x) * 3
                    bytes[o] = line[x * 4]
                    bytes[o + 1] = line[x * 4 + 1]
                    bytes[o + 2] = line[x * 4 + 2]
                }
            }
        }
        return (out, bytes)
    }

    static func jpegData(_ image: CGImage, quality: Double) -> [UInt8]? {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buffer as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return [UInt8](buffer as Data)
    }

    /// Compactação zlib (o formato do PDF: cabeçalho de 2 bytes, DEFLATE e Adler-32 no fim).
    static func zlib(_ bytes: [UInt8]) -> [UInt8] {
        guard let deflated = try? (Data(bytes) as NSData).compressed(using: .zlib) else { return bytes }
        var a: UInt32 = 1, b: UInt32 = 0
        var k = 0
        while k < bytes.count {
            let end = min(k + 5552, bytes.count)
            while k < end {
                a += UInt32(bytes[k])
                b += a
                k += 1
            }
            a %= 65521
            b %= 65521
        }
        let adler = (b << 16) | a
        return [0x78, 0xDA] + [UInt8](deflated as Data) +
            [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)]
    }

    // MARK: - Gravação

    static func write(_ file: PDFFile, objects: [Int: PDFObject], gens: [Int: Int]) -> [UInt8] {
        var out: [UInt8] = Array("%PDF-1.7\n%".utf8) + [0xE2, 0xE3, 0xCF, 0xD3, 0x0A]
        var direct: [Int: (offset: Int, gen: Int)] = [:]
        var packed: [Int: (stream: Int, index: Int)] = [:]
        let maxNum = objects.keys.max() ?? 0
        var next = maxNum + 1

        // fluxos: cada um no seu lugar (os sem filtro são compactados)
        var plain: [Int] = []
        for n in objects.keys.sorted() {
            let gen = gens[n] ?? 0
            guard case .stream(var d, var data) = objects[n]! else {
                if gen == 0 { plain.append(n) } else {
                    direct[n] = (out.count, gen)
                    out += Array("\(n) \(gen) obj\n\(PDFWriter.write(objects[n]!))\nendobj\n".utf8)
                }
                continue
            }
            let flt = filters(file, d) ?? ["?"]
            if flt.isEmpty, data.count > 64 {
                let z = zlib(data)
                if z.count < data.count {
                    data = z
                    d["Filter"] = .name("FlateDecode")
                }
            } else if (flt == ["FlateDecode"] || flt == ["Fl"]), d["DecodeParms"] == nil,
                      let decoded = try? PDFFile.inflate(data) {
                let z = zlib(decoded)
                if z.count < data.count { data = z }
            }
            d["Length"] = .number("\(data.count)")
            direct[n] = (out.count, gen)
            out += Array("\(n) \(gen) obj\n\(PDFWriter.dict(d))\nstream\n".utf8) + data + Array("\nendstream\nendobj\n".utf8)
        }

        // os outros objetos, em fluxos de objetos de até 200
        var k = 0
        while k < plain.count {
            let group = Array(plain[k..<min(k + 200, plain.count)])
            k += 200
            let stm = next
            next += 1
            var header = ""
            var body: [UInt8] = []
            for (i, n) in group.enumerated() {
                header += "\(n) \(body.count) "
                body += Array(PDFWriter.write(objects[n]!).utf8) + [10]
                packed[n] = (stm, i)
            }
            let head = Array(header.utf8) + [10]
            let content = zlib(head + body)
            var d = PDFDict()
            d["Type"] = .name("ObjStm")
            d["N"] = .number("\(group.count)")
            d["First"] = .number("\(head.count)")
            d["Filter"] = .name("FlateDecode")
            d["Length"] = .number("\(content.count)")
            direct[stm] = (out.count, 0)
            out += Array("\(stm) 0 obj\n\(PDFWriter.dict(d))\nstream\n".utf8) + content + Array("\nendstream\nendobj\n".utf8)
        }

        // tabela xref em fluxo
        let xnum = next
        let size = xnum + 1
        let xrefStart = out.count
        direct[xnum] = (xrefStart, 0)
        var rows: [UInt8] = []
        for n in 0..<size {
            if let p = packed[n] {
                rows += [2] + be32(p.stream) + be16(p.index)
            } else if let o = direct[n] {
                rows += [1] + be32(o.offset) + be16(o.gen)
            } else {
                rows += [0] + be32(0) + be16(n == 0 ? 65535 : 0)
            }
        }
        let z = zlib(rows)
        var t = PDFDict()
        t["Type"] = .name("XRef")
        t["Size"] = .number("\(size)")
        t["W"] = .array([.number("1"), .number("4"), .number("2")])
        if let root = file.trailer["Root"] { t["Root"] = root }
        if let info = file.trailer["Info"], let r = info.refValue, objects[r.0] != nil { t["Info"] = info }
        if let id = file.trailer["ID"] { t["ID"] = id }
        t["Filter"] = .name("FlateDecode")
        t["Length"] = .number("\(z.count)")
        out += Array("\(xnum) 0 obj\n\(PDFWriter.dict(t))\nstream\n".utf8) + z + Array("\nendstream\nendobj\n".utf8)
        out += Array("startxref\n\(xrefStart)\n%%EOF\n".utf8)
        return out
    }

    static func be32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
}

// MARK: - Na biblioteca

extension Library {
    /// Cria "Nome - comprimido" na mesma pasta. Devolve nil quando o PDF já está compacto (menos de 2% a ganhar).
    func compressedCopy(_ item: PDFItem, level: CompressionLevel,
                        progress: ((Int, Int) -> Void)? = nil) async throws -> (PDFItem, CompressionResult)? {
        if item.meta.locked == true { throw UserFacingError(L("Este PDF tem senha. Para comprimir, crie antes uma cópia sem senha.")) }
        if item.meta.isSigned {
            throw UserFacingError(L("Este PDF está assinado digitalmente: comprimir regrava o arquivo e a assinatura deixaria de valer. Comprima o original (sem assinatura) e assine depois."))
        }
        let src = item.url
        let tmp = newTempURL()
        let result = try await Task.detached(priority: .userInitiated) {
            try PDFCompressor.compress(src, to: tmp, level: level, progress: progress)
        }.value
        if Double(result.after) >= Double(result.before) * 0.98 {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        let base = AppLanguages.stripSuffix(item.name, template: "{} - comprimido")   // i18n: em qualquer idioma
        let new = try adopt(fileAt: tmp, name: LF("{} - comprimido", base), folder: item.folder)
        return (new, result)
    }
}

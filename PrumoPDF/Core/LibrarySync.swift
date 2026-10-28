import Foundation

/// O que acompanha cada PDF entre aparelhos (iPhone e Windows), pelo arquivo `.prumo/library.json`
/// dentro da pasta da biblioteca. É o mesmo arquivo e os mesmos nomes de campos do Prumo para Windows.
/// As referências (cópia com OCR, original) vão como id no arquivo e são conferidas pelo caminho.
struct SharedMeta: Equatable {
    var favorite = false
    var pendingOCR = false
    var isOCRResult = false
    var ocrCopy: String?      // caminho em minúsculas, ou "id:<id>" se o arquivo ainda não chegou
    var source: String?
}

extension Library {
    static let sharedFolder = ".prumo"

    var sharedURL: URL {
        root.appendingPathComponent(Self.sharedFolder, isDirectory: true).appendingPathComponent("library.json")
    }

    private func diskStampNow() -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: sharedURL.path) else { return nil }
        let date = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        return "\(date)-\(size)"
    }

    private func readDisk() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: sharedURL),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.filter { ($0["path"] as? String)?.isEmpty == false && ($0["id"] as? String)?.isEmpty == false }
    }

    private static func key(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").lowercased()
    }

    private func setDisk(_ entries: [[String: Any]]) {
        var out: [String: [String: Any]] = [:]
        for e in entries {
            let k = Self.key(e["path"] as! String)
            if out[k] == nil { out[k] = e }
        }
        diskEntries = out
    }

    func sharedValues() -> [String: SharedMeta] {
        let metas = allMetas
        var idPath: [String: String] = [:]
        for m in metas.values { idPath[m.id] = m.path.lowercased() }
        func ref(_ id: String?) -> String? { id.map { idPath[$0] ?? "id:\($0)" } }
        var out: [String: SharedMeta] = [:]
        for m in metas.values {
            out[m.path.lowercased()] = SharedMeta(favorite: m.favorite, pendingOCR: m.pendingOCR,
                                                  isOCRResult: m.isOCRResult, ocrCopy: ref(m.ocrCopyID),
                                                  source: ref(m.sourceID))
        }
        return out
    }

    private func diskValues(_ e: [String: Any], idPath: [String: String]) -> SharedMeta {
        func ref(_ v: Any?) -> String? {
            guard let id = v as? String, !id.isEmpty else { return nil }
            return idPath[id] ?? "id:\(id)"
        }
        return SharedMeta(favorite: e["favorite"] as? Bool ?? false,
                          pendingOCR: e["pending_ocr"] as? Bool ?? false,
                          isOCRResult: e["is_ocr_result"] as? Bool ?? false,
                          ocrCopy: ref(e["ocr_copy_id"]), source: ref(e["source_id"]))
    }

    private func resolve(_ value: String?, byPath: [String: DocMeta]) -> String? {
        guard let v = value else { return nil }
        if v.hasPrefix("id:") { return String(v.dropFirst(3)) }
        if let m = byPath[v] { return m.id }
        return diskEntries[v]?["id"] as? String
    }

    /// Traz do library.json o que outro aparelho mudou. Os campos mudados aqui desde a última
    /// sincronização ficam como estão aqui. Devolve true se algo mudou.
    @discardableResult
    func syncFromDisk() -> Bool {
        let stamp = diskStampNow()
        guard stamp != diskStamp else { return false }
        diskStamp = stamp
        let entries = readDisk()
        setDisk(entries)
        guard !entries.isEmpty else { return false }
        var idPath: [String: String] = [:]
        for e in entries { idPath[e["id"] as! String] = Self.key(e["path"] as! String) }
        let local = sharedValues()
        var metas = allMetas
        var byPath: [String: DocMeta] = [:]
        for m in metas.values { byPath[m.path.lowercased()] = m }
        var changed = false
        for (p, entry) in diskEntries {
            guard var m = byPath[p], let mine = local[p] else { continue }
            let disk = diskValues(entry, idPath: idPath)
            let snap = syncSnap[p]
            func take<T: Equatable>(_ kp: KeyPath<SharedMeta, T>) -> Bool {
                if let snap, mine[keyPath: kp] != snap[keyPath: kp] { return false }   // mudou aqui
                return disk[keyPath: kp] != mine[keyPath: kp]
            }
            if take(\.favorite) { m.favorite = disk.favorite }
            if take(\.pendingOCR) { m.pendingOCR = disk.pendingOCR }
            if take(\.isOCRResult) { m.isOCRResult = disk.isOCRResult }
            if take(\.ocrCopy) { m.ocrCopyID = resolve(disk.ocrCopy, byPath: byPath) }
            if take(\.source) { m.sourceID = resolve(disk.source, byPath: byPath) }
            if m != metas[m.id] {
                metas[m.id] = m
                changed = true
            }
        }
        if changed { allMetas = metas }
        syncSnap = sharedValues()
        return changed
    }

    /// Dados de um PDF novo na pasta: se ele veio de outro aparelho, usa o id e o favorito de lá.
    func newSharedMeta(path: String, usedIDs: inout Set<String>) -> DocMeta {
        guard let e = diskEntries[path.lowercased()] else { return DocMeta(path: path) }
        var m: DocMeta
        if let id = e["id"] as? String, !usedIDs.contains(id) {
            m = DocMeta(id: id, path: path)
            usedIDs.insert(id)
        } else {
            m = DocMeta(path: path)
        }
        m.favorite = e["favorite"] as? Bool ?? false
        m.pendingOCR = e["pending_ocr"] as? Bool ?? false
        m.isOCRResult = e["is_ocr_result"] as? Bool ?? false
        m.ocrCopyID = e["ocr_copy_id"] as? String
        m.sourceID = e["source_id"] as? String
        return m
    }

    /// Grava o library.json compartilhado: os PDFs daqui e os que outro aparelho registrou e ainda
    /// não chegaram pela nuvem.
    func writeShared() {
        let metas = allMetas
        let local = Set(metas.values.map { $0.path.lowercased() })
        var rows: [[String: Any]] = metas.values.sorted { $0.path < $1.path }.map { m in
            var r: [String: Any] = ["path": m.path, "id": m.id, "favorite": m.favorite,
                                    "pending_ocr": m.pendingOCR, "is_ocr_result": m.isOCRResult]
            r["ocr_copy_id"] = m.ocrCopyID ?? NSNull()
            r["source_id"] = m.sourceID ?? NSNull()
            return r
        }
        for (p, e) in diskEntries where !local.contains(p) && !knownPaths.contains(p) { rows.append(e) }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: sharedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: sharedURL, options: .atomic)) != nil else { return }
        diskStamp = diskStampNow()
        setDisk(rows)
        knownPaths.formUnion(local)
        syncSnap = sharedValues()
    }
}

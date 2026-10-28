import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Cópia de segurança da biblioteca numa pasta comum (no iCloud Drive, Google Drive, pendrive…),
/// no mesmo formato da versão para Windows: os PDFs nas suas pastas e, em ".prumo/library.json",
/// os favoritos. Uma cópia feita num aparelho pode ser restaurada no outro.
struct RestoreResult {
    var added = 0
    var skipped = 0       // já estavam na biblioteca (mesmo conteúdo)
    var favorites = 0
}

extension Library {
    static let backupMetaFolder = ".prumo"

    /// A biblioteca como pasta, pronta para o "Salvar em…" do app Arquivos.
    func backupWrapper() throws -> FileWrapper {
        let wrapper = try FileWrapper(url: root, options: [])
        if let inbox = wrapper.fileWrappers?["Inbox"] { wrapper.removeFileWrapper(inbox) }
        if let old = wrapper.fileWrappers?[Self.backupMetaFolder] { wrapper.removeFileWrapper(old) }
        let entries: [[String: Any]] = items.map { item in
            ["path": item.relativePath, "favorite": item.meta.favorite, "is_ocr_result": item.meta.isOCRResult]
        }
        let json = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        let meta = FileWrapper(directoryWithFileWrappers: [:])
        meta.preferredFilename = Self.backupMetaFolder
        meta.addRegularFile(withContents: json, preferredFilename: "library.json")
        wrapper.addFileWrapper(meta)
        return wrapper
    }

    static func backupName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "yyyy-MM-dd HH'h'mm"
        return "Prumo PDF - cópia \(f.string(from: date))"
    }

    nonisolated static func digest(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Traz os PDFs de uma cópia (ou de qualquer pasta com PDFs) mantendo as pastas, sem duplicar.
    func restore(from source: URL) throws -> RestoreResult {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        var result = RestoreResult()

        var bySize: [Int64: [URL]] = [:]
        for item in items { bySize[item.size, default: []].append(item.url) }
        var digests: [URL: String] = [:]
        func alreadyHere(_ url: URL, size: Int64) -> Bool {
            guard let same = bySize[size], !same.isEmpty, let d = Self.digest(url) else { return false }
            for other in same {
                if digests[other] == nil { digests[other] = Self.digest(other) }
                if digests[other] == d { return true }
            }
            return false
        }

        var favorites = Set<String>()
        let metaURL = source.appendingPathComponent(Self.backupMetaFolder).appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: metaURL),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for entry in list where (entry["favorite"] as? Bool) == true {
                if let p = entry["path"] as? String { favorites.insert(p.replacingOccurrences(of: "\\", with: "/").lowercased()) }
            }
        }

        let base = source.standardizedFileURL.resolvingSymlinksInPath()
        guard let en = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                     options: [.skipsHiddenFiles]) else {
            throw UserFacingError("Não foi possível ler a pasta escolhida.")
        }
        var restoredFavorites: [String] = []
        for case let url as URL in en {
            guard url.pathExtension.lowercased() == "pdf",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(base.path) else { continue }
            let rel = String(full.dropFirst(base.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if alreadyHere(url, size: size) {
                result.skipped += 1
                continue
            }
            let folder = (rel as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                try? fm.createDirectory(at: folderURL(folder), withIntermediateDirectories: true)
            }
            let dest = uniqueURL(folder: folder, baseName: url.deletingPathExtension().lastPathComponent)
            try fm.copyItem(at: url, to: dest)
            BackupPolicy.apply(to: dest)
            bySize[size, default: []].append(dest)
            result.added += 1
            if favorites.contains(rel.lowercased()) { restoredFavorites.append(relativePath(of: dest)) }
        }
        reload()
        for path in restoredFavorites {
            if let item = item(path: path) {
                setFavorite(item, true)
                result.favorites += 1
            }
        }
        return result
    }
}

/// A biblioteca como documento de pasta, para o "Salvar em…" (fileExporter).
struct LibraryFolderDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    let wrapper: FileWrapper

    init(wrapper: FileWrapper) { self.wrapper = wrapper }

    init(configuration: ReadConfiguration) throws { wrapper = configuration.file }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { wrapper }
}

import Foundation

enum AppSettings {
    static let includeInBackupKey = "includeInBackup"
    static let ocrLanguageKey = "ocrLanguage"

    /// Padrão: os PDFs entram no backup do iCloud (escolha feita no app, em Ajustes).
    static var includeInBackup: Bool {
        UserDefaults.standard.object(forKey: includeInBackupKey) as? Bool ?? true
    }

    static var ocrLanguages: [String] {
        UserDefaults.standard.string(forKey: ocrLanguageKey) == "por+eng" ? ["pt-BR", "en-US"] : ["pt-BR"]
    }
}

/// Marca arquivos para entrar (ou não) no backup do iCloud.
/// A Apple orienta reaplicar a marca a cada gravação, porque algumas operações a desfazem.
enum BackupPolicy {
    static func apply(to url: URL, include: Bool = AppSettings.includeInBackup) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = !include
        try? u.setResourceValues(values)
    }

    /// Aplica a todos os arquivos e pastas abaixo de cada raiz (incluindo a própria raiz).
    static func applyAll(roots: [URL], include: Bool = AppSettings.includeInBackup) {
        let fm = FileManager.default
        for root in roots {
            apply(to: root, include: include)
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in en {
                apply(to: url, include: include)
            }
        }
    }

    static func isExcluded(_ url: URL) -> Bool {
        // URL guarda os valores lidos em cache; uma URL nova lê o valor atual do disco.
        let fresh = URL(fileURLWithPath: url.path)
        return (try? fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
    }
}

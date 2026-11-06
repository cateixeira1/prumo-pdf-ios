import Foundation

// Tradução da interface. A chave é o próprio texto em português; as traduções ficam em
// PrumoPDF/Localization/<idioma>.lproj/Localizable.strings, geradas de scripts/locales/*.json
// (os mesmos catálogos do Prumo para Windows) por scripts/build_strings.py.
//
// Regras (conferidas pela verificação do GitHub, tools/i18n_check.py):
// - `Text("literal")`, `Button("literal")`, `Label("literal", systemImage:)`, `.navigationTitle("literal")`
//   etc. já são traduzidos pelo SwiftUI, desde que o texto não tenha "\(...)".
// - Todo outro texto da interface passa por L("..."); com parte variável, LF("Página {} de {}", n, total);
//   com singular e plural, LN(n, "1 página", "{} páginas").
// - Texto gravado dentro do PDF (carimbo da assinatura, resumo, numeração) usa LD/LDF: idioma do app,
//   ou inglês em japonês e chinês (as fontes padrão do PDF não têm esses caracteres).

/// Traduz um texto escrito em português (a "chave") para o idioma do app, se houver tradução.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Traduz o modelo e preenche cada "{}" com os valores, na ordem: LF("Página {} de {}", 2, 10).
func LF(_ template: String, _ args: Any...) -> String {
    fillTemplate(L(template), args)
}

/// Singular ou plural: LN(3, "1 página", "{} páginas") → "3 páginas". O número entra no primeiro "{}".
func LN(_ n: Int, _ one: String, _ other: String, _ args: Any...) -> String {
    if n == 1 { return fillTemplate(L(one), args) }
    return fillTemplate(L(other), [n] + args)
}

/// Texto gravado dentro do PDF, no idioma dos documentos (AppLanguages.document).
func LD(_ key: String) -> String {
    AppLanguages.translate(key, to: AppLanguages.document)
}

func LDF(_ template: String, _ args: Any...) -> String {
    fillTemplate(LD(template), args)
}

func fillTemplate(_ template: String, _ args: [Any]) -> String {
    guard !args.isEmpty, template.contains("{}") else { return template }
    var out = ""
    var rest = Substring(template)
    var i = 0
    while let r = rest.range(of: "{}") {
        out += rest[..<r.lowerBound]
        out += i < args.count ? "\(args[i])" : ""
        i += 1
        rest = rest[r.upperBound...]
    }
    return out + rest
}

enum AppLanguages {
    /// Idiomas da interface: pasta `.lproj` e nome no próprio idioma.
    static let all: [(lproj: String, name: String)] = [
        ("pt", "Português"), ("en", "English"), ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"),
        ("ja", "日本語"), ("zh-Hans", "中文 (简体)"), ("zh-Hant", "中文 (繁體, 台灣)"), ("nb", "Norsk bokmål"),
        ("sv", "Svenska"), ("da", "Dansk"), ("fi", "Suomi"),
    ]
    /// Traduções que ainda pedem revisão por quem fala a língua.
    static let needsReview: Set<String> = []

    /// Idioma em uso pela interface (pasta .lproj escolhida pelo iOS).
    static var current: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// Datas e números no idioma do app (com a região do iPhone).
    static var locale: Locale {
        let region = Locale.current.region?.identifier
        let lang = current
        return Locale(identifier: region.map { "\(lang)_\($0)" } ?? lang)
    }

    /// Idiomas que podem ser gravados dentro do PDF com as fontes padrão (sem japonês e chinês).
    static let documentLanguages: Set<String> = ["pt", "en", "es", "fr", "de", "nb", "sv", "da", "fi"]

    /// Idioma dos textos gravados no PDF: o da interface, ou inglês.
    static var document: String { documentLanguages.contains(current) ? current : "en" }

    private static var bundles: [String: Bundle] = [:]
    private static let lock = NSLock()

    private static func bundle(_ lproj: String) -> Bundle? {
        lock.lock(); defer { lock.unlock() }
        if let b = bundles[lproj] { return b }
        guard let path = Bundle.main.path(forResource: lproj, ofType: "lproj"), let b = Bundle(path: path) else {
            return nil
        }
        bundles[lproj] = b
        return b
    }

    /// Tradução para um idioma específico (não necessariamente o da interface).
    static func translate(_ key: String, to lproj: String) -> String {
        if lproj == current { return L(key) }
        if lproj == "pt" { return key }
        return bundle(lproj)?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    /// O texto em português e em todos os idiomas, começando pelo idioma atual (para reconhecer nomes de
    /// arquivo criados em outro idioma, no iPhone ou no Windows).
    static func allTranslations(_ key: String) -> [String] {
        var out = [L(key)]
        for (lproj, _) in all {
            let t = translate(key, to: lproj)
            if !out.contains(t) { out.append(t) }
        }
        return out
    }

    /// Tira de um nome o sufixo do modelo ("{} - protegido") em qualquer idioma; se não tiver, devolve o nome.
    static func stripSuffix(_ name: String, template: String) -> String {
        for t in allTranslations(template) where t.hasPrefix("{}") {
            let suffix = String(t.dropFirst(2))
            if !suffix.isEmpty, name.hasSuffix(suffix), name.count > suffix.count {
                return String(name.dropLast(suffix.count))
            }
        }
        return name
    }

    /// O nome com o sufixo em cada idioma, começando pelo idioma atual.
    static func suffixedNames(_ base: String, template: String) -> [String] {
        allTranslations(template).map { fillTemplate($0, [base]) }
    }

    /// Formato da data e hora no carimbo da assinatura, no idioma dos documentos (como no Windows).
    static var stampDateFormat: String {
        switch document {
        case "pt", "es", "fr": return "dd/MM/yyyy HH:mm:ss"
        case "de", "nb", "da", "fi": return "dd.MM.yyyy HH:mm:ss"
        default: return "yyyy-MM-dd HH:mm:ss"
        }
    }
}

/// Junta frases com a pontuação do idioma: "PDF criado: X" + "Os de fotos estão em Sem OCR." →
/// "PDF criado: X. Os de fotos estão em Sem OCR." (em japonês e chinês, com "。" e sem espaço).
func sentences(_ parts: String...) -> String {
    let cjk = ["ja", "zh-Hans", "zh-Hant"].contains(AppLanguages.current)
    let ends: Set<Character> = [".", "!", "?", "…", "。", "！", "？", ":", "："]
    return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { p in
        ends.contains(p.last!) ? p : p + (cjk ? "。" : ".")
    }.joined(separator: cjk ? "" : " ")
}

extension Date {
    /// Só a data, curta, no idioma do app ("14/11/2023", "11/14/23", "14.11.23").
    var dayText: String {
        let f = DateFormatter()
        f.locale = AppLanguages.locale
        f.dateStyle = .short
        f.timeStyle = .none
        return f.string(from: self)
    }
}

/// Rótulo no meio de uma frase ("Mudar para amarelo"): em minúsculas, menos em alemão, onde substantivo
/// continua com maiúscula ("Zu Gelb wechseln").
func inSentence(_ label: String) -> String {
    AppLanguages.current == "de" ? label : label.lowercased(with: AppLanguages.locale)
}

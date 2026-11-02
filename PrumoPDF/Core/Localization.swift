import Foundation

/// Traduz um texto escrito em português (a "chave") para o idioma do app, se houver tradução.
/// `Text("literal")` do SwiftUI já faz isso sozinho; esta função serve para textos que chegam como `String`.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

enum AppLanguages {
    /// Idiomas da interface: pasta `.lproj` e nome no próprio idioma.
    static let all: [(lproj: String, name: String)] = [
        ("pt-BR", "Português"), ("en", "English"), ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"),
        ("ja", "日本語"), ("zh-Hans", "中文 (简体)"), ("zh-Hant", "中文 (繁體, 台灣)"), ("nb", "Norsk bokmål"),
        ("se", "Davvisámegiella"), ("sv", "Svenska"), ("da", "Dansk"), ("fi", "Suomi"),
    ]
    /// Traduções que ainda pedem revisão por quem fala a língua.
    static let needsReview: Set<String> = ["se"]
}

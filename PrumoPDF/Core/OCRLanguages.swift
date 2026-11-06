import Foundation
import Vision

/// Idiomas do OCR. Os códigos de `id` são os mesmos do Prumo para Windows (Tesseract), então a escolha
/// significa a mesma coisa nos dois. O Vision não reconhece todos os idiomas, e a lista muda com a versão
/// do iOS; por isso o que vale é o que o próprio aparelho informa (`supportedRecognitionLanguages`).
struct OCRLanguage: Identifiable, Hashable {
    let id: String              // por, eng, spa, fra, deu, jpn, chi_sim, chi_tra, nor, swe, dan, fin
    let name: String            // no próprio idioma
    let vision: String?         // código do Vision; nil = o Vision não tem
    var storageKey: String { id }

    static let all: [OCRLanguage] = [
        OCRLanguage(id: "por", name: "Português", vision: "pt-BR"),
        OCRLanguage(id: "eng", name: "English", vision: "en-US"),
        OCRLanguage(id: "spa", name: "Español", vision: "es-ES"),
        OCRLanguage(id: "fra", name: "Français", vision: "fr-FR"),
        OCRLanguage(id: "deu", name: "Deutsch", vision: "de-DE"),
        OCRLanguage(id: "jpn", name: "日本語", vision: "ja-JP"),
        OCRLanguage(id: "chi_sim", name: "中文 (简体)", vision: "zh-Hans"),
        OCRLanguage(id: "chi_tra", name: "中文 (繁體, 台灣)", vision: "zh-Hant"),
        OCRLanguage(id: "nor", name: "Norsk", vision: "nb-NO"),
        OCRLanguage(id: "swe", name: "Svenska", vision: "sv-SE"),
        OCRLanguage(id: "dan", name: "Dansk", vision: "da-DK"),
        OCRLanguage(id: "fin", name: "Suomi", vision: "fi-FI"),
    ]
    static let maxSelected = 4

    /// Sem escolha salva, o OCR usa o idioma do app (como no Windows).
    static var defaultID: String {
        let byUI = ["pt": "por", "en": "eng", "es": "spa", "fr": "fra", "de": "deu", "ja": "jpn",
                    "zh-Hans": "chi_sim", "zh-Hant": "chi_tra", "nb": "nor", "sv": "swe", "da": "dan", "fi": "fin"]
        return byUI[AppLanguages.current] ?? "eng"
    }

    /// Códigos de idioma que este iPhone reconhece agora.
    static func supportedByDevice() -> [String] {
        (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? ["pt-BR", "en-US"]
    }

    /// O código está na lista do aparelho? Compara o código inteiro ("zh-Hans") ou, nos de língua só, o começo
    /// ("pt-BR" aceita "pt-BR" e também "pt-PT" não: só o mesmo código).
    private static func isSupported(_ code: String, in supported: [String]) -> Bool {
        supported.contains { $0.caseInsensitiveCompare(code) == .orderedSame }
    }

    static func available(supported: [String] = supportedByDevice()) -> [OCRLanguage] {
        all.filter { l in l.vision.map { isSupported($0, in: supported) } ?? false }
    }

    static func unavailable(supported: [String] = supportedByDevice()) -> [OCRLanguage] {
        let ok = Set(available(supported: supported).map(\.id))
        return all.filter { !ok.contains($0.id) }
    }

    /// "por+eng" → ["por", "eng"] (valores antigos "por" e "por+eng" continuam valendo).
    static func parse(_ stored: String?) -> [String] {
        let ids = Set(all.map(\.id))
        var out: [String] = []
        for part in (stored ?? defaultID).split(separator: "+").map(String.init) where ids.contains(part) && !out.contains(part) {
            out.append(part)
        }
        return out.isEmpty ? [defaultID] : out
    }

    static func join(_ ids: [String]) -> String {
        var seen: [String] = []
        for i in ids where all.contains(where: { $0.id == i }) && !seen.contains(i) { seen.append(i) }
        let joined = seen.prefix(maxSelected).joined(separator: "+")
        return joined.isEmpty ? defaultID : joined
    }

    /// Códigos do Vision para o que está salvo, só os que o aparelho reconhece (sempre devolve algum).
    static func visionCodes(stored: String?, supported: [String] = supportedByDevice()) -> [String] {
        let ok = Set(available(supported: supported).map(\.id))
        let codes = parse(stored).filter { ok.contains($0) }.compactMap { id in all.first { $0.id == id }?.vision }
        return codes.isEmpty ? [all.first { $0.id == defaultID }?.vision ?? "en-US"] : codes
    }
}

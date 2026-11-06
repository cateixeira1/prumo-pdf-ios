import Foundation

/// Erros com mensagens prontas para mostrar ao usuário.
struct UserFacingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Converte textos como "1, 3-5, 10-fim" em números de página (começando em 1) e vice-versa.
enum PageSelection {

    /// Palavras aceitas para "última página": fim, end, última e a palavra do idioma do app (Ende, fin…).
    static var endWords: Set<String> { ["fim", "end", "última", "ultima", L("fim").lowercased()] }

    static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        let parts = text
            .replacingOccurrences(of: ";", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw UserFacingError(L("Informe ao menos uma página.")) }

        var pages = Set<Int>()
        for part in parts {
            let lower = part.lowercased()
            if endWords.contains(lower) {
                pages.insert(pageCount)
                continue
            }
            if let dash = part.firstIndex(where: { $0 == "-" || $0 == "–" || $0 == "—" }) {
                let a = part[..<dash].trimmingCharacters(in: .whitespaces)
                let b = part[part.index(after: dash)...].trimmingCharacters(in: .whitespaces).lowercased()
                guard let start = Int(a) else { throw UserFacingError(LF("Não entendi “{}”. Use algo como 1, 3-5, 10-fim.", part)) }
                let end: Int
                if endWords.contains(b) || b.isEmpty {
                    end = pageCount
                } else if let e = Int(b) {
                    end = e
                } else {
                    throw UserFacingError(LF("Não entendi “{}”. Use algo como 1, 3-5, 10-fim.", part))
                }
                guard start <= end else { throw UserFacingError(LF("Intervalo invertido: {}", part)) }
                guard start >= 1, end <= pageCount else {
                    throw UserFacingError(LF("O documento tem {}; “{}” está fora do intervalo.", LN(pageCount, "1 página", "{} páginas"), part))
                }
                pages.formUnion(start...end)
            } else if let n = Int(part) {
                guard n >= 1, n <= pageCount else {
                    throw UserFacingError(LF("O documento tem {}; a página {} não existe.", LN(pageCount, "1 página", "{} páginas"), n))
                }
                pages.insert(n)
            } else {
                throw UserFacingError(LF("Não entendi “{}”. Use algo como 1, 3-5, 10-fim.", part))
            }
        }
        return pages.sorted()
    }

    /// [1,2,3,5,7,8] -> "1-3, 5, 7-8"
    static func format(_ pages: [Int]) -> String {
        let sorted = Array(Set(pages)).sorted()
        guard var start = sorted.first else { return "" }
        var prev = start
        var out: [String] = []
        for p in sorted.dropFirst() + [Int.min] {
            if p == prev + 1 { prev = p; continue }
            out.append(start == prev ? "\(start)" : "\(start)-\(prev)")
            start = p
            prev = p
        }
        return out.joined(separator: ", ")
    }
}

/// Divide um total de páginas em partes o mais iguais possível.
/// Quando a divisão não é exata, as primeiras partes ficam com uma página a mais (200 em 3 = 67, 67, 66).
enum SplitPlan {
    static func sizes(pageCount: Int, parts: Int) throws -> [Int] {
        guard parts >= 2 else { throw UserFacingError(L("Escolha pelo menos 2 partes.")) }
        guard pageCount >= parts else {
            throw UserFacingError(LF("O documento tem {}; não dá para dividir em {} partes.", LN(pageCount, "1 página", "{} páginas"), parts))
        }
        let base = pageCount / parts
        let extra = pageCount % parts
        return (0..<parts).map { $0 < extra ? base + 1 : base }
    }

    /// Faixas de páginas (começando em 1) de cada parte.
    static func ranges(pageCount: Int, parts: Int) throws -> [ClosedRange<Int>] {
        var start = 1
        return try sizes(pageCount: pageCount, parts: parts).map { size in
            defer { start += size }
            return start...(start + size - 1)
        }
    }

    /// Texto curto para a prévia: "4 partes de 50 páginas" ou "3 partes: 67, 67 e 66 páginas".
    static func summary(pageCount: Int, parts: Int) -> String? {
        guard let s = try? sizes(pageCount: pageCount, parts: parts) else { return nil }
        if Set(s).count == 1 { return LN(parts, "1 parte de {}", "{} partes de {}", LN(s[0], "1 página", "{} páginas")) }
        let list = s.map(String.init)
        let joined = LF("{} e {}", list.dropLast().joined(separator: ", "), list.last!)
        return LF("{} partes: {} páginas", parts, joined)
    }
}

import Foundation

/// Erros com mensagens prontas para mostrar ao usuário.
struct UserFacingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Converte textos como "1, 3-5, 10-fim" em números de página (começando em 1) e vice-versa.
enum PageSelection {

    static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        let parts = text
            .replacingOccurrences(of: ";", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw UserFacingError("Informe ao menos uma página.") }

        var pages = Set<Int>()
        for part in parts {
            let lower = part.lowercased()
            if lower == "fim" || lower == "end" || lower == "última" || lower == "ultima" {
                pages.insert(pageCount)
                continue
            }
            if let dash = part.firstIndex(where: { $0 == "-" || $0 == "–" || $0 == "—" }) {
                let a = part[..<dash].trimmingCharacters(in: .whitespaces)
                let b = part[part.index(after: dash)...].trimmingCharacters(in: .whitespaces).lowercased()
                guard let start = Int(a) else { throw UserFacingError("Não entendi “\(part)”. Use algo como 1, 3-5, 10-fim.") }
                let end: Int
                if b == "fim" || b == "end" || b.isEmpty {
                    end = pageCount
                } else if let e = Int(b) {
                    end = e
                } else {
                    throw UserFacingError("Não entendi “\(part)”. Use algo como 1, 3-5, 10-fim.")
                }
                guard start <= end else { throw UserFacingError("Intervalo invertido: \(part)") }
                guard start >= 1, end <= pageCount else {
                    throw UserFacingError("O documento tem \(pageCount) página(s); “\(part)” está fora do intervalo.")
                }
                pages.formUnion(start...end)
            } else if let n = Int(part) {
                guard n >= 1, n <= pageCount else {
                    throw UserFacingError("O documento tem \(pageCount) página(s); a página \(n) não existe.")
                }
                pages.insert(n)
            } else {
                throw UserFacingError("Não entendi “\(part)”. Use algo como 1, 3-5, 10-fim.")
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
        guard parts >= 2 else { throw UserFacingError("Escolha pelo menos 2 partes.") }
        guard pageCount >= parts else {
            throw UserFacingError("O documento tem \(pageCount) página(s); não dá para dividir em \(parts) partes.")
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
        if Set(s).count == 1 { return "\(parts) partes de \(s[0]) página\(s[0] == 1 ? "" : "s")" }
        let list = s.map(String.init)
        let joined = list.dropLast().joined(separator: ", ") + " e " + list.last!
        return "\(parts) partes: \(joined) páginas"
    }
}

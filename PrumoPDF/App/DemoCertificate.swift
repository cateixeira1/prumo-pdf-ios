import Foundation

#if DEBUG
/// Certificado de demonstração (autoassinado, fictício), só para as capturas de tela automáticas.
enum DemoCertificate {
    static let password = "demo"
    static var data: Data {
        Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: ""))!
    }

    private static let b64 = """
        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
        AggA
        """
}
#endif

import Foundation

/// Certificados de teste (autoassinados, sem valor nenhum), gerados para os testes da assinatura digital.
/// Senha de todos: "teste123". MARIA e JOAO usam a cifra antiga (3DES), comum nos arquivos A1 das
/// autoridades certificadoras; o "AES" usa a cifra nova (AES-256), padrão do OpenSSL 3.
enum TestCertificates {
    static let password = "teste123"

    static var maria: Data { data(mariaB64) }
    static var joao: Data { data(joaoB64) }
    static var aes: Data { data(aesB64) }

    private static func data(_ s: String) -> Data {
        Data(base64Encoded: s.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: ""))!
    }

    private static let mariaB64 = """
        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
        """

    private static let joaoB64 = """
        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
        vgICCAA=
        """

    private static let aesB64 = """
        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
        """
}

/// PDF de 2 páginas com tabela xref em fluxo e objetos compactados (como os PDFs do Word e de
/// muitos sistemas), para conferir que o Prumo lê essa estrutura ao assinar.
enum TestPDFs {
    static var xrefStream: Data {
        Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: ""))!
    }

    private static let b64 = """
        JVBERi0xLjUKJb/3ov4KMSAwIG9iago8PCAvVHlwZSAvT2JqU3RtIC9MZW5ndGggMzI2IC9GaWx0ZXIgL0ZsYXRlRGVjb2RlIC9O
        IDkgL0ZpcnN0IDUyID4+CnN0cmVhbQp4nLWRTWvCQBCG7/6K99he3I98uCkS0FhR2tKgQqHiYRuHEIi7YjZF/33Jqm2h9NBDLzOz
        w/s+M+xIcASIOEKIkCOClAFiBDzGAIFSUAjjEAmikENwRIr3hkOwzLbGQYI9VNsGa4TgWCDycQO2Ou0JLNclNUhT73jekxkVrrLm
        U86mlZvBtHXdeTr1oz7Z1oE9G8ps3e7MFSLPhjM3007XtrySM2scGddAiLPqibaVHttjt7Bv5PpAfl3/WlBj20NBDQbfqd2gn0j5
        R6T6DTnWDU2tcWAzqt/JVYUGuzeF3VamBHupzMg01Vdj2b45D+lQ4kr0hAvR174QiP3YNAXLD7ZYksMaLJ9MwVZ0dGDznS5pfMnZ
        Jc+x+Q9WdiDd3XmiHeFmcie5jAWXiQy44Or1ttOt0f1jlER9qaBC0VcJNr0PUiyy5QplbmRzdHJlYW0KZW5kb2JqCjExIDAgb2Jq
        Cjw8IC9GaWx0ZXIgL0ZsYXRlRGVjb2RlIC9MZW5ndGggMTI5ID4+CnN0cmVhbQp4nBXNsQ6CMBQF0J2vuKMOPF9rjKwoMJgYk6aD
        awOviYZSUiD28w3rWY7Go2C6XPErbhanTkFpYob1aO1OZ0WqQsVMrGEHHJrYb0GmNaKPATmJhwT4ccuR8KzNvW5epnybtisVwUpe
        IwaBZAnzGDG75OCW5TO5REfY7/78ARhYJeAKZW5kc3RyZWFtCmVuZG9iagoxMiAwIG9iago8PCAvRmlsdGVyIC9GbGF0ZURlY29k
        ZSAvTGVuZ3RoIDEyOSA+PgpzdHJlYW0KeJwVzbEOgjAUBdCdr7ijDjxfa4ysKDCYGJOmg2sDr4mGUlIg9vMN61mOxqNgulzxK24W
        p05BaWKG9WjtTmdFqkLFTKxhBxya2G9BpjWijwE5iYcE+HHLkfCszb1uXqZ8m7YrNcFKXiMGgWQJ8xgxu+TgluUzuURH2O/+/AEY
        gSXhCmVuZHN0cmVhbQplbmRvYmoKMTMgMCBvYmoKPDwgL1R5cGUgL1hSZWYgL0xlbmd0aCAzOSAvRmlsdGVyIC9GbGF0ZURlY29k
        ZSAvRGVjb2RlUGFybXMgPDwgL0NvbHVtbnMgNCAvUHJlZGljdG9yIDEyID4+IC9XIFsgMSAyIDEgXSAvSW5mbyA5IDAgUiAvUm9v
        dCAzIDAgUiAvU2l6ZSAxNCAvSUQgWzxmNDFkMWM3MjgwMTYwYzMwMTM2ZGY0YTA2OGJiYmZiMj48YTI3NTRmMWUzYmJmNjQ2YzZk
        YTJlZjhhNWRkMDI1OWM+XSA+PgpzdHJlYW0KeJxjYmBgYGBiZOAHEZ8YmBgYGBiJIf4z7vzBxMB4igFMAABn4wVvCmVuZHN0cmVh
        bQplbmRvYmoKc3RhcnR4cmVmCjg0NgolJUVPRgo=
        """
}

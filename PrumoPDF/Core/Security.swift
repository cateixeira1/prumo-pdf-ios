import Foundation
import LocalAuthentication
import UIKit
import PDFKit
import SwiftUI

// MARK: - Senha no PDF

extension Library {
    /// Cópia do PDF com senha, na criptografia padrão de PDF: abre em qualquer leitor com a senha.
    func protect(_ item: PDFItem, password: String) throws -> PDFItem {
        guard !password.isEmpty else { throw UserFacingError("Digite uma senha.") }
        guard let doc = PDFDocument(url: item.url) else { throw UserFacingError("Não foi possível abrir o PDF.") }
        if doc.isLocked { throw UserFacingError("Este PDF já tem senha.") }
        let dest = uniqueURL(folder: item.folder, baseName: "\(item.name) - protegido")
        let ok = doc.write(to: dest, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password])
        guard ok else { throw UserFacingError("Não foi possível gravar o PDF protegido.") }
        reload()
        guard let new = self.item(path: relativePath(of: dest)) else {
            throw UserFacingError("O arquivo foi salvo, mas não apareceu na biblioteca.")
        }
        return new
    }

    /// Cópia sem senha (com a senha atual), para fazer OCR, organizar páginas etc.
    func unprotect(_ item: PDFItem, password: String) throws -> PDFItem {
        guard let doc = PDFDocument(url: item.url) else { throw UserFacingError("Não foi possível abrir o PDF.") }
        guard doc.unlock(withPassword: password) else { throw UserFacingError("Senha incorreta.") }
        // Copia as páginas para um documento novo: ele é gravado sem criptografia.
        let plain = PDFDocument()
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i)?.copy() as? PDFPage { plain.insert(page, at: plain.pageCount) }
        }
        let base = item.name.hasSuffix(" - protegido") ? String(item.name.dropLast(" - protegido".count))
                                                         : "\(item.name) - sem senha"
        let dest = uniqueURL(folder: item.folder, baseName: base)
        guard plain.write(to: dest) else { throw UserFacingError("Não foi possível gravar a cópia sem senha.") }
        reload()
        guard let new = self.item(path: relativePath(of: dest)) else {
            throw UserFacingError("O arquivo foi salvo, mas não apareceu na biblioteca.")
        }
        return new
    }

    nonisolated static func checkPassword(_ url: URL, _ password: String) -> Bool {
        guard let doc = PDFDocument(url: url) else { return false }
        return !doc.isLocked || doc.unlock(withPassword: password)
    }
}

// MARK: - Trava do app (Face ID, Touch ID ou o código do iPhone)

@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()
    static let enabledKey = "appLockEnabled"

    @Published private(set) var locked: Bool
    @Published var lastError: String?

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    init() {
        locked = UserDefaults.standard.bool(forKey: Self.enabledKey) && !DemoSeeder.isActive
    }

    /// "Face ID", "Touch ID" ou "código do iPhone", conforme o aparelho.
    static var methodName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "código do iPhone"
        }
    }

    static var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func lock() {
        if enabled { locked = true }
    }

    private var prompting = false

    /// Pede Face ID (ou o código do iPhone, se a biometria falhar). `automatic`: pedido feito pelo app
    /// (ao voltar para ele), não pelo botão. Só acontece com o app ativo na tela: pedir antes disso
    /// (quando a tela bloqueada aparece, ao sair do app) dava o erro "LocalAuthentication -6".
    func unlock(automatic: Bool = false) async {
        guard locked, !prompting else { return }
        if automatic && UIApplication.shared.applicationState != .active { return }
        prompting = true
        defer { prompting = false }
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancelar"
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Desbloquear o Prumo PDF")
            if ok {
                locked = false
                lastError = nil
            }
        } catch {
            lastError = Self.message(for: error, automatic: automatic)
        }
    }

    /// Mensagem para mostrar (ou nada, quando não é um problema de verdade: cancelou, o sistema interrompeu,
    /// o app saiu da tela).
    static func message(for error: Error, automatic: Bool) -> String? {
        guard let e = error as? LAError else { return automatic ? nil : error.localizedDescription }
        switch e.code {
        case .userCancel, .systemCancel, .appCancel, .notInteractive, .userFallback:
            return nil
        case .biometryNotAvailable:
            return automatic ? nil : "O \(methodName) não está disponível agora. Tente de novo em instantes."
        case .biometryLockout:
            return "O \(methodName) foi bloqueado por muitas tentativas. Toque em Desbloquear e use o código do iPhone."
        case .authenticationFailed:
            return "Não foi possível confirmar. Tente de novo."
        case .passcodeNotSet:
            return "Configure um código no iPhone (Ajustes › Face ID e Código) para usar o bloqueio."
        default:
            return automatic ? nil : e.localizedDescription
        }
    }

    /// Liga ou desliga a trava (pede a autenticação antes, para confirmar que funciona neste aparelho).
    func setEnabled(_ on: Bool) async -> Bool {
        guard on != enabled else { return true }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            lastError = "Este iPhone não tem Face ID, Touch ID nem código configurado."
            return false
        }
        do {
            let reason = on ? "Ligar o bloqueio do Prumo PDF" : "Desligar o bloqueio do Prumo PDF"
            guard try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { return false }
        } catch {
            return false
        }
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        locked = false
        return true
    }
}

/// Tela que cobre o app enquanto ele está travado.
struct LockView: View {
    @ObservedObject var lock: AppLock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 18) {
            // Logo, cadeado e botão ficam abaixo do meio da tela (mais perto do polegar).
            Spacer()
            Spacer()
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .accessibilityLabel("Prumo PDF")
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.purple)
                .accessibilityHidden(true)
            Text("Prumo PDF está bloqueado")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            if let e = lock.lastError {
                Text(e).font(.footnote).foregroundStyle(Theme.red).multilineTextAlignment(.center).padding(.horizontal)
            }
            PrimaryButton(title: "Desbloquear com \(AppLock.methodName)", color: Theme.blue) {
                Task { await lock.unlock() }
            }
            .padding(.horizontal, 40)
            Spacer()
            Text("Color Software")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .task { if !DemoSeeder.isActive { await lock.unlock(automatic: true) } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !DemoSeeder.isActive { Task { await lock.unlock(automatic: true) } }
        }
    }
}

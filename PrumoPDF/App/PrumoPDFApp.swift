import SwiftUI

@main
struct PrumoPDFApp: App {
    @StateObject private var library = Library.shared
    @StateObject private var flow = AppFlow.shared
    @StateObject private var jobs = JobCenter.shared
    @StateObject private var appLock = AppLock.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(flow)
                .environmentObject(jobs)
                .overlay {
                    if appLock.locked || (DemoSeeder.isActive && DemoSeeder.startScreen == "lock") { LockView(lock: appLock).transition(.opacity) }
                }
                .onOpenURL { url in
                    flow.handleIncoming(url: url, library: library)
                }
                .task {
                    // Biblioteca na nuvem: o que o Windows muda aparece aqui com o app aberto.
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 20_000_000_000)
                        if scenePhase == .active && !library.isLocal && !DemoSeeder.isActive { library.reload() }
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Arquivos podem ter sido adicionados ou apagados pelo app Arquivos.
            if phase == .active && !DemoSeeder.isActive { library.reload() }
            // Ao sair do app (segundo plano), trava; ao voltar, pede Face ID.
            if phase == .background { appLock.lock() }
        }
    }
}

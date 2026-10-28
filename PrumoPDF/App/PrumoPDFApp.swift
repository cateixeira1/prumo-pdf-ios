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
                    if appLock.locked { LockView(lock: appLock).transition(.opacity) }
                }
                .onOpenURL { url in
                    flow.handleIncoming(url: url, library: library)
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

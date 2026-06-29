import SwiftUI

@main


struct SillySpeed: App {
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var audioManager = AudioManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(themeManager)
                .environmentObject(audioManager)
                .onOpenURL { url in
                    if url.scheme == "punches" && url.host == "openAndPlay" {
                        Task {
                            await audioManager.processPendingImports(shouldAutoPlay: true)
                        }
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task {
                            await audioManager.processPendingImports()
                        }
                    }
                }
                .onAppear {
                    preloadHaptics()
                }
        }
    }
    private func preloadHaptics() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
    }
}


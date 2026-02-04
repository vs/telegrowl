import SwiftUI

@main
struct TelegrowlApp: App {
    @StateObject private var telegramService = TelegramService.shared
    @StateObject private var audioService = AudioService.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(telegramService)
                .environmentObject(audioService)
                .onAppear {
                    setupAudioSession()
                }
        }
    }
    
    private func setupAudioSession() {
        audioService.setupAudioSession()
    }
}

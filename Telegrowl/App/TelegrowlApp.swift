import SwiftUI

@main
struct TelegrowlApp: App {
    @StateObject private var telegramService = TelegramService.shared
    @StateObject private var audioService = AudioService.shared

    init() {
        Config.registerDefaults()
        MessageSendQueue.shared.load()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(telegramService)
                .environmentObject(audioService)
                .onAppear {
                    setupAudioSession()
                    AudioConverter.cleanupTempFiles()
                }
        }
    }
    
    private func setupAudioSession() {
        audioService.setupAudioSession()
    }
}

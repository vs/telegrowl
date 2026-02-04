import SwiftUI

struct ContentView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var audioService: AudioService
    
    @State private var showingAuth = false
    @State private var showingSettings = false
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color(hex: "1a1a2e"), Color(hex: "16213e")],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                header
                
                Spacer()
                
                // Main content
                if telegramService.isAuthenticated {
                    mainContent
                } else {
                    authPrompt
                }
                
                Spacer()
                
                // Status bar
                statusBar
            }
        }
        .sheet(isPresented: $showingAuth) {
            AuthView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newVoiceMessage)) { _ in
            handleNewVoiceMessage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingAutoStopped)) { _ in
            sendRecording()
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack {
            Text("Telegrowl")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text("🐯")
                .font(.title2)
            
            Spacer()
            
            Button(action: { showingSettings = true }) {
                Image(systemName: "gear")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding()
    }
    
    // MARK: - Main Content
    
    private var mainContent: some View {
        VStack(spacing: 40) {
            // Chat info
            if let chat = telegramService.currentChat {
                Text(chat.title)
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.8))
            } else {
                Text("Tap to select chat")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.5))
            }
            
            // Record button
            RecordButton(
                isRecording: audioService.isRecording,
                audioLevel: audioService.audioLevel,
                duration: audioService.recordingDuration
            ) {
                // On press
                audioService.startRecording()
            } onRelease: {
                // On release
                sendRecording()
            }
            
            // Instructions
            Text(audioService.isRecording ? "Release to send" : "Hold to talk")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
        }
    }
    
    // MARK: - Auth Prompt
    
    private var authPrompt: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.5))
            
            Text("Login to Telegram")
                .font(.title2)
                .foregroundColor(.white)
            
            Button(action: { showingAuth = true }) {
                Text("Connect Account")
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 15)
                    .background(Color.blue)
                    .cornerRadius(25)
            }
        }
    }
    
    // MARK: - Status Bar
    
    private var statusBar: some View {
        HStack {
            // Connection status
            Circle()
                .fill(telegramService.isAuthenticated ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            
            Text(telegramService.isAuthenticated ? "Connected" : "Not connected")
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))
            
            Spacer()
            
            // Playing indicator
            if audioService.isPlaying {
                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2.fill")
                    Text("Playing...")
                }
                .font(.caption)
                .foregroundColor(.green)
            }
        }
        .padding()
        .background(Color.black.opacity(0.3))
    }
    
    // MARK: - Actions
    
    private func sendRecording() {
        guard let url = audioService.stopRecording() else { return }
        
        let duration = Int(audioService.recordingDuration)
        let waveform = audioService.generateWaveform(from: url)
        
        telegramService.sendVoiceMessage(audioURL: url, duration: duration, waveform: waveform)
    }
    
    private func handleNewVoiceMessage() {
        guard Config.autoPlayResponses else { return }
        
        // Get latest incoming voice message and play it
        if let lastMessage = telegramService.messages.last,
           !lastMessage.isOutgoing,
           let url = lastMessage.localURL {
            audioService.play(url: url)
        }
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(TelegramService.shared)
        .environmentObject(AudioService.shared)
}

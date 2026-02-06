import SwiftUI
import TDLibKit

struct ContentView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var audioService: AudioService
    
    @State private var showingAuth = false
    @State private var showingSettings = false
    @State private var showingChatList = false
    @State private var showingConversation = false
    
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
                
                // Main content
                if telegramService.isAuthenticated {
                    if showingConversation {
                        // Conversation mode
                        conversationMode
                    } else {
                        // Record mode (main)
                        recordMode
                    }
                } else {
                    authPrompt
                }
            }
        }
        .sheet(isPresented: $showingAuth) {
            AuthView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingChatList) {
            ChatListView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newVoiceMessage)) { notification in
            handleNewVoiceMessage(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingAutoStopped)) { _ in
            sendRecording()
        }
        .alert("Error", isPresented: .constant(telegramService.error != nil)) {
            Button("OK") {
                telegramService.error = nil
            }
        } message: {
            if let error = telegramService.error {
                Text(error.localizedDescription)
            }
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack {
            // Title
            HStack(spacing: 8) {
                Text("🐯")
                    .font(.title)
                
                Text("Telegrowl")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }
            
            Spacer()
            
            // Chat selector
            if telegramService.isAuthenticated {
                Button(action: { showingChatList = true }) {
                    HStack(spacing: 4) {
                        if let chat = telegramService.selectedChat {
                            Text(chat.title)
                                .lineLimit(1)
                        } else {
                            Text("Select chat")
                        }
                        Image(systemName: "chevron.down")
                    }
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(20)
                }
            }
            
            // Settings
            Button(action: { showingSettings = true }) {
                Image(systemName: "gear")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding()
    }
    
    // MARK: - Record Mode
    
    private var recordMode: some View {
        VStack(spacing: 0) {
            Spacer()
            
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
                .font(.headline)
                .foregroundColor(.white.opacity(0.6))
                .padding(.top, 20)
            
            Spacer()
            
            // Bottom actions
            bottomBar
        }
    }
    
    // MARK: - Conversation Mode
    
    private var conversationMode: some View {
        VStack(spacing: 0) {
            // Messages
            ConversationView()
            
            // Compact record button
            compactRecordBar
        }
    }
    
    // MARK: - Compact Record Bar
    
    private var compactRecordBar: some View {
        HStack(spacing: 16) {
            // Back button
            Button(action: { showingConversation = false }) {
                Image(systemName: "chevron.left")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.7))
            }
            
            Spacer()
            
            // Mini record button
            ZStack {
                Circle()
                    .fill(audioService.isRecording ? Color.red : Color(hex: "e94560"))
                    .frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(0.3), radius: 10)
                
                Image(systemName: audioService.isRecording ? "stop.fill" : "mic.fill")
                    .font(.title2)
                    .foregroundColor(.white)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !audioService.isRecording {
                            audioService.startRecording()
                        }
                    }
                    .onEnded { _ in
                        sendRecording()
                    }
            )
            
            Spacer()
            
            // Placeholder for balance
            Color.clear.frame(width: 44, height: 44)
        }
        .padding()
        .background(Color.black.opacity(0.3))
    }
    
    // MARK: - Bottom Bar
    
    private var bottomBar: some View {
        HStack {
            // Connection status
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionStatusColor)
                    .frame(width: 8, height: 8)
                
                Text(connectionStatusText)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }
            
            Spacer()
            
            // View conversation button
            if !telegramService.messages.isEmpty {
                Button(action: { showingConversation = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left.and.bubble.right")
                        Text("\(telegramService.messages.count)")
                    }
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(15)
                }
            }
            
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
    
    // MARK: - Auth Prompt
    
    private var authPrompt: some View {
        VStack(spacing: 30) {
            Spacer()
            
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 80))
                .foregroundColor(.white.opacity(0.4))
            
            VStack(spacing: 8) {
                Text("Welcome to Telegrowl")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("Hands-free voice messaging for Telegram")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.6))
            }
            
            Button(action: { showingAuth = true }) {
                HStack {
                    Image(systemName: "paperplane.fill")
                    Text("Connect Telegram")
                }
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .padding(.horizontal, 30)
                .padding(.vertical, 15)
                .background(Color(hex: "e94560"))
                .cornerRadius(25)
            }
            
            #if DEBUG
            // Demo mode button for testing
            Button(action: { telegramService.simulateLogin() }) {
                Text("Demo Mode")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.top, 20)
            #endif
            
            Spacer()
        }
    }
    
    // MARK: - Helpers
    
    private var connectionStatusColor: Color {
        guard let state = telegramService.connectionState else { return .red }

        switch state {
        case .connectionStateReady:
            return .green
        case .connectionStateConnecting, .connectionStateConnectingToProxy, .connectionStateUpdating:
            return .yellow
        case .connectionStateWaitingForNetwork:
            return .red
        }
    }
    
    private var connectionStatusText: String {
        guard let state = telegramService.connectionState else { return "Disconnected" }

        switch state {
        case .connectionStateReady:
            return "Connected"
        case .connectionStateConnecting:
            return "Connecting..."
        case .connectionStateConnectingToProxy:
            return "Connecting to proxy..."
        case .connectionStateUpdating:
            return "Updating..."
        case .connectionStateWaitingForNetwork:
            return "Waiting for network..."
        }
    }
    
    // MARK: - Actions
    
    private func sendRecording() {
        guard let m4aURL = audioService.stopRecording() else { return }

        let duration = Int(audioService.recordingDuration)
        guard duration > 0 else {
            print("⚠️ Recording too short, not sending")
            return
        }

        // Capture chat ID before async gap to avoid sending to wrong chat
        // if the user switches chats during conversion.
        guard let chatId = telegramService.selectedChat?.id else {
            print("❌ No chat selected")
            return
        }

        let service = telegramService

        // Run conversion off the main actor to avoid freezing UI.
        Task.detached {
            do {
                let (oggURL, waveform) = try await AudioConverter.convertToOpus(inputURL: m4aURL)

                await service.sendVoiceMessage(
                    audioURL: oggURL,
                    duration: duration,
                    waveform: waveform,
                    chatId: chatId
                )

                try? FileManager.default.removeItem(at: m4aURL)
            } catch {
                print("❌ Conversion failed: \(error), sending M4A as fallback")
                await service.sendVoiceMessage(
                    audioURL: m4aURL,
                    duration: duration,
                    waveform: nil,
                    chatId: chatId
                )
            }
        }
    }
    
    private func handleNewVoiceMessage(_ notification: Foundation.Notification) {
        guard Config.autoPlayResponses else { return }

        if let message = notification.object as? Message,
           !message.isOutgoing,
           case .messageVoiceNote(let voiceContent) = message.content {

            telegramService.downloadVoice(voiceContent.voiceNote) { url in
                if let url = url {
                    audioService.play(url: url)
                }
            }
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
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
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

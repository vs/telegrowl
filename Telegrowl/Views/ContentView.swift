import SwiftUI
import TDLibKit
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var audioService: AudioService
    @StateObject private var voiceCommandService = VoiceCommandService.shared

    @State private var navigationPath = NavigationPath()
    @State private var showingAuth = false
    @StateObject private var sendQueue = MessageSendQueue.shared
    @State private var currentToast: ToastData?
    @State private var toastDismissTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if telegramService.isAuthenticated {
                authenticatedView
            } else {
                authPrompt
            }

            // Connection banner overlay (top)
            VStack(spacing: 0) {
                if isDisconnected {
                    ConnectionBanner(
                        state: telegramService.connectionState,
                        queueCount: sendQueue.pendingCount
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .animation(.easeInOut(duration: 0.3), value: isDisconnected)

            // Toast overlay (bottom)
            VStack {
                Spacer()
                if let toast = currentToast {
                    ToastView(toast: toast, onDismiss: { dismissToast() }, onRetry: nil)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 8)
                }
            }
            .animation(.spring(duration: 0.3), value: currentToast)
        }
        .sheet(isPresented: $showingAuth) {
            AuthView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newVoiceMessage)) { notification in
            handleNewVoiceMessage(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceDownloaded)) { notification in
            handleDeferredVoiceDownload(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingAutoStopped)) { _ in
            sendRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .queueSendSucceeded)) { _ in
            showToast(ToastData(message: "Voice message sent", style: .success, icon: "checkmark.circle.fill"))
        }
        .onChange(of: telegramService.error?.localizedDescription) {
            if let error = telegramService.error {
                showToast(ToastData(message: error.localizedDescription, style: .error, icon: "exclamationmark.triangle.fill"))
                telegramService.error = nil
            }
        }
        .task {
            if telegramService.isAuthenticated {
                await startVoiceControlIfNeeded()
            }
        }
        .onChange(of: telegramService.isAuthenticated) { _, isAuth in
            if isAuth {
                Task { await startVoiceControlIfNeeded() }
            }
        }
        .onChange(of: navigationPath.count) { oldCount, newCount in
            if newCount == 0 && oldCount > 0 {
                voiceCommandService.onChatClosed()
            }
        }
    }

    // MARK: - Authenticated View

    private var authenticatedView: some View {
        navigationView
    }

    private var navigationView: some View {
        NavigationStack(path: $navigationPath) {
            ChatListView()
                .navigationDestination(for: Int64.self) { chatId in
                    conversationDestination(chatId: chatId)
                }
                .navigationDestination(for: String.self) { value in
                    if value.hasPrefix("voiceChat-"),
                       let chatId = Int64(value.replacingOccurrences(of: "voiceChat-", with: "")),
                       let chat = telegramService.chats.first(where: { $0.id == chatId }) {
                        VoiceChatView(chatId: chatId, chatTitle: chat.title) { action in
                            handleVoiceAction(action, telegramService: telegramService)
                        }
                        .navigationBarHidden(true)
                    }
                }
        }
        .tint(TelegramTheme.accent)
        .onChange(of: telegramService.selectedChat?.id) { _, newChatId in
            if let chatId = newChatId {
                // Only push if we're not already there
                if navigationPath.isEmpty {
                    navigationPath.append(chatId)
                }
            }
        }
    }

    @ViewBuilder
    private func conversationDestination(chatId: Int64) -> some View {
        VStack(spacing: 0) {
            ConversationView(chatId: chatId)

            InputBarView(
                isRecording: audioService.isRecording,
                audioLevel: audioService.audioLevel,
                recordingDuration: audioService.recordingDuration,
                onStartRecording: { audioService.startRecording() },
                onStopRecording: { sendRecording() }
            )
        }
        .onAppear {
            if telegramService.selectedChat?.id != chatId,
               let chat = telegramService.chats.first(where: { $0.id == chatId }) {
                telegramService.selectChat(chat)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                chatToolbarTitle
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: "voiceChat-\(chatId)") {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(TelegramTheme.accent)
                }
            }
        }
    }

    private var chatToolbarTitle: some View {
        HStack(spacing: 8) {
            if let chat = telegramService.selectedChat {
                AvatarView(photo: chat.photo, title: chat.title, size: TelegramTheme.messageAvatarSize)

                VStack(alignment: .leading, spacing: 1) {
                    Text(chat.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(TelegramTheme.textPrimary)

                    Text(connectionStatusText)
                        .font(.system(size: 12))
                        .foregroundColor(TelegramTheme.textSecondary)
                }
            }
        }
    }

    // MARK: - Auth Prompt

    private var authPrompt: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 30) {
                Spacer()

                Image(systemName: "paperplane.fill")
                    .font(.system(size: 70))
                    .foregroundColor(TelegramTheme.accent)

                VStack(spacing: 8) {
                    Text("Telegrowl")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(TelegramTheme.textPrimary)

                    Text("Voice chat for Telegram")
                        .font(.subheadline)
                        .foregroundColor(TelegramTheme.textSecondary)
                }

                Button(action: { showingAuth = true }) {
                    Text("Start Messaging")
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 14)
                        .background(TelegramTheme.accent)
                        .cornerRadius(25)
                }

                #if DEBUG
                Button(action: { telegramService.simulateLogin() }) {
                    Text("Demo Mode")
                        .font(.caption)
                        .foregroundColor(TelegramTheme.textSecondary)
                }
                .padding(.top, 20)
                #endif

                Spacer()
            }
        }
    }

    // MARK: - Voice Control

    private func startVoiceControlIfNeeded() async {
        guard Config.voiceControlEnabled else { return }
        let granted = await VoiceCommandService.requestPermissions()
        if granted {
            voiceCommandService.onAction = { action in
                handleVoiceAction(action, telegramService: telegramService)
            }
            voiceCommandService.start()
        }
    }

    private func handleVoiceAction(_ action: VoiceCommandAction, telegramService: TelegramService?) {
        switch action {
        case .openChat(let chatId, _):
            voiceCommandService.onChatOpening()
            if let chat = telegramService?.chats.first(where: { $0.id == chatId }) {
                telegramService?.selectChat(chat)
            }
            navigationPath = NavigationPath()
            navigationPath.append(chatId)
            navigationPath.append("voiceChat-\(chatId)")

        case .switchChat(let chatId, let chatTitle):
            voiceCommandService.onChatOpening()
            voiceCommandService.stop()
            let synth = AVSpeechSynthesizer()
            let utterance = AVSpeechUtterance(string: "Starting chat with \(chatTitle)")
            utterance.voice = AVSpeechSynthesisVoice(language: Config.speechLocale)
            synth.speak(utterance)
            Task {
                try? await Task.sleep(for: .seconds(2))
                if let chat = telegramService?.chats.first(where: { $0.id == chatId }) {
                    telegramService?.selectChat(chat)
                }
                navigationPath = NavigationPath()
                navigationPath.append(chatId)
                navigationPath.append("voiceChat-\(chatId)")
            }

        case .closeChat:
            navigationPath = NavigationPath()
            voiceCommandService.onChatClosed()

        case .playMessage(let message, _):
            playAnnouncedMessage(message)

        case .exitApp:
            voiceCommandService.stop()
            #if canImport(UIKit)
            UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
            #endif
        }
    }

    private func playAnnouncedMessage(_ message: Message) {
        switch message.content {
        case .messageVoiceNote(let voiceContent):
            TelegramService.shared.downloadVoice(voiceContent.voiceNote) { url in
                if let url {
                    AudioService.shared.play(url: url)
                }
            }

        case .messageText(let text):
            if Config.readTextMessages {
                let utterance = AVSpeechUtterance(string: text.text.text)
                utterance.voice = AVSpeechSynthesisVoice(language: Config.speechLocale)
                AVSpeechSynthesizer().speak(utterance)
            }

        default:
            break
        }
    }

    // MARK: - Helpers

    private var isDisconnected: Bool {
        guard let state = telegramService.connectionState else { return true }
        if case .connectionStateReady = state { return false }
        return true
    }

    private var connectionStatusText: String {
        guard let state = telegramService.connectionState else { return "connecting..." }
        let queueCount = sendQueue.pendingCount
        let queueSuffix = queueCount > 0 ? " (\(queueCount) queued)" : ""

        switch state {
        case .connectionStateReady:
            return queueCount > 0 ? "sending\(queueSuffix)" : "online"
        case .connectionStateConnecting:
            return "connecting...\(queueSuffix)"
        case .connectionStateConnectingToProxy:
            return "connecting to proxy...\(queueSuffix)"
        case .connectionStateUpdating:
            return "updating...\(queueSuffix)"
        case .connectionStateWaitingForNetwork:
            return "waiting for network...\(queueSuffix)"
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

        guard let chatId = telegramService.selectedChat?.id else {
            print("❌ No chat selected")
            showToast(ToastData(message: "No chat selected", style: .warning, icon: "exclamationmark.triangle.fill"))
            return
        }

        showToast(ToastData(message: "Converting audio...", style: .info, icon: "waveform", isLoading: true), autoDismiss: false)

        Task.detached {
            var audioURL = m4aURL
            var waveform: Data? = nil

            do {
                let (oggURL, wf) = try await AudioConverter.convertToOpus(inputURL: m4aURL)
                audioURL = oggURL
                waveform = wf
            } catch {
                print("❌ Conversion failed: \(error), sending M4A as fallback")
            }

            await MainActor.run {
                sendQueue.enqueue(audioURL: audioURL, duration: duration, waveform: waveform, chatId: chatId)

                // Delete the M4A source if we converted to OGG (enqueue moved the OGG)
                if audioURL != m4aURL {
                    try? FileManager.default.removeItem(at: m4aURL)
                }

                let queueCount = sendQueue.pendingCount
                if queueCount > 1 {
                    showToast(ToastData(message: "Queued (\(queueCount) pending)", style: .info, icon: "tray.full"))
                } else {
                    showToast(ToastData(message: "Sending...", style: .info, icon: "paperplane", isLoading: true))
                }
            }
        }
    }

    private func showToast(_ toast: ToastData, autoDismiss: Bool = true) {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        currentToast = toast
        if autoDismiss {
            toastDismissTask = Task {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled {
                    dismissToast()
                }
            }
        }
    }

    private func dismissToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        currentToast = nil
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
                // If url is nil, TelegramService started an async download.
                // handleDeferredVoiceDownload will auto-play when it completes.
            }
        }
    }

    /// Auto-play voice messages that were deferred due to connectivity issues.
    private func handleDeferredVoiceDownload(_ notification: Foundation.Notification) {
        guard Config.autoPlayResponses else { return }
        guard !audioService.isPlaying else { return }

        if let url = notification.userInfo?["url"] as? URL {
            print("📥 Playing deferred voice download: \(url.lastPathComponent)")
            audioService.play(url: url)
        }
    }
}

// MARK: - Connection Banner

struct ConnectionBanner: View {
    let state: ConnectionState?
    let queueCount: Int

    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 22, weight: .semibold))
                .symbolEffect(.pulse, isActive: isPulsing)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))

                if queueCount > 0 {
                    Text("\(queueCount) message\(queueCount == 1 ? "" : "s") waiting to send")
                        .font(.system(size: 13))
                        .opacity(0.85)
                }
            }

            Spacer()
        }
        .foregroundColor(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(backgroundColor)
        .onAppear { isPulsing = true }
    }

    private var iconName: String {
        switch state {
        case .connectionStateWaitingForNetwork, .none:
            return "wifi.slash"
        default:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var title: String {
        switch state {
        case .connectionStateWaitingForNetwork, .none:
            return "No Connection"
        case .connectionStateConnecting:
            return "Connecting..."
        case .connectionStateConnectingToProxy:
            return "Connecting to Proxy..."
        case .connectionStateUpdating:
            return "Updating..."
        default:
            return "Connecting..."
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .connectionStateWaitingForNetwork, .none:
            return TelegramTheme.recordingRed
        default:
            return .orange
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(TelegramService.shared)
        .environmentObject(AudioService.shared)
}

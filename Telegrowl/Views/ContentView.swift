import SwiftUI
import TDLibKit
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var audioService: AudioService
    @StateObject private var voiceCommandService = VoiceCommandService.shared

    @State private var navigationPath = NavigationPath()
    @State private var showingAuth = false
    @State private var currentToast: ToastData?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var retryAction: (() -> Void)?

    var body: some View {
        ZStack {
            if telegramService.isAuthenticated {
                authenticatedView
            } else {
                authPrompt
            }

            // Toast overlay (bottom)
            VStack {
                Spacer()
                if let toast = currentToast {
                    ToastView(toast: toast, onDismiss: { dismissToast() }, onRetry: retryAction)
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
        .onReceive(NotificationCenter.default.publisher(for: .recordingAutoStopped)) { _ in
            sendRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .messageSendFailed)) { notification in
            if let errorMessage = notification.userInfo?["errorMessage"] as? String {
                showToast(ToastData(message: "Send failed: \(errorMessage)", style: .error, icon: "exclamationmark.triangle.fill"), autoDismiss: false)
            }
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

    private var connectionStatusText: String {
        guard let state = telegramService.connectionState else { return "connecting..." }
        switch state {
        case .connectionStateReady:
            return "online"
        case .connectionStateConnecting:
            return "connecting..."
        case .connectionStateConnectingToProxy:
            return "connecting to proxy..."
        case .connectionStateUpdating:
            return "updating..."
        case .connectionStateWaitingForNetwork:
            return "waiting for network..."
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

        let service = telegramService

        showToast(ToastData(message: "Converting audio...", style: .info, icon: "waveform", isLoading: true), autoDismiss: false)

        Task.detached {
            var audioURL = m4aURL
            var waveform: Data? = nil
            var usedFallback = false

            do {
                let (oggURL, wf) = try await AudioConverter.convertToOpus(inputURL: m4aURL)
                audioURL = oggURL
                waveform = wf
            } catch {
                print("❌ Conversion failed: \(error), sending M4A as fallback")
                usedFallback = true
            }

            await MainActor.run {
                showToast(ToastData(message: "Sending...", style: .info, icon: "paperplane", isLoading: true), autoDismiss: false)
            }

            do {
                try await service.sendVoiceMessage(
                    audioURL: audioURL,
                    duration: duration,
                    waveform: waveform,
                    chatId: chatId
                )

                try? FileManager.default.removeItem(at: m4aURL)

                await MainActor.run {
                    if usedFallback {
                        showToast(ToastData(message: "Sent (without Opus conversion)", style: .warning, icon: "exclamationmark.triangle.fill"))
                    } else {
                        showToast(ToastData(message: "Voice message sent", style: .success, icon: "checkmark.circle.fill"))
                    }
                }
            } catch {
                print("❌ Failed to send voice: \(error)")
                let retryURL = audioURL
                await MainActor.run {
                    retryAction = {
                        retrySend(audioURL: retryURL, m4aURL: m4aURL, duration: duration, waveform: waveform, chatId: chatId)
                    }
                    showToast(ToastData(message: "Failed to send", style: .error, icon: "exclamationmark.triangle.fill", hasRetry: true), autoDismiss: false)
                }
            }
        }
    }

    private func retrySend(audioURL: URL, m4aURL: URL, duration: Int, waveform: Data?, chatId: Int64) {
        let service = telegramService
        retryAction = nil
        showToast(ToastData(message: "Sending...", style: .info, icon: "paperplane", isLoading: true), autoDismiss: false)

        Task.detached {
            do {
                try await service.sendVoiceMessage(
                    audioURL: audioURL,
                    duration: duration,
                    waveform: waveform,
                    chatId: chatId
                )
                try? FileManager.default.removeItem(at: m4aURL)
                await MainActor.run {
                    showToast(ToastData(message: "Voice message sent", style: .success, icon: "checkmark.circle.fill"))
                }
            } catch {
                print("❌ Retry failed: \(error)")
                let retryURL = audioURL
                await MainActor.run {
                    retryAction = {
                        retrySend(audioURL: retryURL, m4aURL: m4aURL, duration: duration, waveform: waveform, chatId: chatId)
                    }
                    showToast(ToastData(message: "Failed to send", style: .error, icon: "exclamationmark.triangle.fill", hasRetry: true), autoDismiss: false)
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
        retryAction = nil
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

#Preview {
    ContentView()
        .environmentObject(TelegramService.shared)
        .environmentObject(AudioService.shared)
}

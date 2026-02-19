import SwiftUI
import TDLibKit

// MARK: - Conversation Destination

/// Wraps ConversationView + InputBarView + DictationService for a single chat.
/// Created fresh per navigation push via `.navigationDestination`.
struct ConversationDestination: View {
    let chatId: Int64

    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var audioService: AudioService
    @StateObject private var dictationService = DictationService()

    @State private var messageText = ""
    @State private var isManualRecording = false
    @State private var recordingDuration: TimeInterval = 0
    @State private var recordingTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            ConversationView(chatId: chatId)

            InputBarView(
                messageText: $messageText,
                onSendText: sendTextMessage,
                onAttachment: {},
                isRecording: isManualRecording,
                recordingDuration: recordingDuration,
                onStartRecording: startManualRecording,
                onStopRecording: stopManualRecording,
                dictationState: dictationService.state,
                liveTranscription: dictationService.liveTranscription,
                audioLevel: dictationService.audioLevel,
                isListening: dictationService.isListening,
                lastHeard: dictationService.lastHeard,
                permissionDenied: dictationService.permissionDenied,
                onCancelDictation: { dictationService.cancel() }
            )
        }
        .onAppear {
            if telegramService.selectedChat?.id != chatId,
               let chat = telegramService.chats.first(where: { $0.id == chatId }) {
                telegramService.selectChat(chat)
            }
            Task {
                let result = await DictationService.requestPermissions()
                switch result {
                case .granted:
                    dictationService.start(chatId: chatId)
                case .micDenied:
                    dictationService.permissionDenied = true
                    print("❌ Microphone permission denied — enable in Settings > Privacy > Microphone")
                case .speechDenied:
                    dictationService.permissionDenied = true
                    print("❌ Speech recognition denied — enable in Settings > Privacy > Speech Recognition")
                }
            }
        }
        .onDisappear {
            dictationService.stop()
            if isManualRecording {
                _ = audioService.stopRecording()
                isManualRecording = false
            }
        }
    }

    // MARK: - Text Send

    private func sendTextMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = ""
        MessageSendQueue.shared.enqueueText(text: text, chatId: chatId)
    }

    // MARK: - Manual Recording

    private func startManualRecording() {
        audioService.startRecording()
        isManualRecording = true
        recordingDuration = 0

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] _ in
            Task { @MainActor in
                recordingDuration = audioService.recordingDuration
            }
        }
    }

    private func stopManualRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil

        guard let m4aURL = audioService.stopRecording() else {
            isManualRecording = false
            return
        }

        let duration = Int(audioService.recordingDuration)
        isManualRecording = false

        guard duration > 0 else {
            print("⚠️ Recording too short, not sending")
            return
        }

        let targetChatId = chatId

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
                MessageSendQueue.shared.enqueueVoice(
                    audioURL: audioURL,
                    duration: duration,
                    waveform: waveform,
                    caption: nil,
                    chatId: targetChatId
                )

                // Delete the M4A source if we converted to OGG (enqueue moved the OGG)
                if audioURL != m4aURL {
                    try? FileManager.default.removeItem(at: m4aURL)
                }
            }
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var audioService: AudioService

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
        .onReceive(NotificationCenter.default.publisher(for: .queueSendSucceeded)) { _ in
            showToast(ToastData(message: "Message sent", style: .success, icon: "checkmark.circle.fill"))
        }
        .onChange(of: telegramService.error?.localizedDescription) {
            if let error = telegramService.error {
                showToast(ToastData(message: error.localizedDescription, style: .error, icon: "exclamationmark.triangle.fill"))
                telegramService.error = nil
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
        ConversationDestination(chatId: chatId)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    chatToolbarTitle
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

    // MARK: - Toast

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

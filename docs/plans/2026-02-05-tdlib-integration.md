# TDLib Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Integrate TDLibKit to enable real Telegram communication, replacing stub implementations.

**Architecture:** TDLibKit via SPM provides async/await Swift API. TelegramService becomes a thin wrapper around TdApi, using TDLibKit types directly (no custom TG* wrappers). Demo mode preserved for UI testing.

**Tech Stack:** TDLibKit 3.0+, Swift 5.9, iOS 17+

---

## Task 1: Add TDLibKit Dependency

**Files:**
- Modify: `Package.swift:15-25`

**Step 1: Uncomment TDLibKit dependency**

Edit `Package.swift` to enable TDLibKit:

```swift
dependencies: [
    // TDLib Swift wrapper
    .package(url: "https://github.com/Swiftgram/TDLibKit.git", from: "3.0.0"),
],
targets: [
    .target(
        name: "Telegrowl",
        dependencies: [
            "TDLibKit",
        ],
        path: "Telegrowl"
    ),
]
```

**Step 2: Resolve packages**

Run: `cd /Users/vs/workspace/telegrowl && swift package resolve`
Expected: Package resolved successfully, TDLibKit downloaded

**Step 3: Commit**

```bash
git add Package.swift
git commit -m "chore: add TDLibKit dependency"
```

---

## Task 2: Create Config.swift Template

**Files:**
- Create: `Telegrowl/App/Config.swift.template`

**Step 1: Create template file**

Create `Telegrowl/App/Config.swift.template`:

```swift
import Foundation

/// Configuration for Telegrowl
/// Copy this file to Config.swift and fill in your credentials
/// Get API credentials at https://my.telegram.org/apps
struct Config {
    // MARK: - Telegram API (REQUIRED)
    static let telegramApiId: Int32 = 0  // Your api_id
    static let telegramApiHash = ""       // Your api_hash

    // MARK: - TDLib Paths
    static var tdlibDatabasePath: String {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("tdlib").path
    }

    static var tdlibFilesPath: String {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("tdlib_files").path
    }

    // MARK: - Chat Settings
    static var targetChatId: Int64 = 0
    static var targetChatUsername: String = ""

    // MARK: - Audio Settings
    static var autoPlayResponses: Bool = true
    static var hapticFeedback: Bool = true
    static var silenceDetection: Bool = true
    static var silenceDuration: TimeInterval = 2.0
    static var silenceThreshold: Float = 0.01
    static var maxRecordingDuration: TimeInterval = 60.0
}
```

**Step 2: Commit**

```bash
git add Telegrowl/App/Config.swift.template
git commit -m "chore: add Config.swift template"
```

---

## Task 3: Rewrite TelegramService - Core Structure

**Files:**
- Modify: `Telegrowl/Services/TelegramService.swift:1-120`

**Step 1: Replace imports and class declaration**

Replace lines 1-50 with:

```swift
import Foundation
import Combine
import TDLibKit

// MARK: - Telegram Service

/// Main service for Telegram communication via TDLib
@MainActor
class TelegramService: ObservableObject {
    static let shared = TelegramService()

    // MARK: - TDLib Client
    private var api: TdApi?
    private var isDemoMode = false

    // MARK: - Published State
    @Published var authorizationState: AuthorizationState?
    @Published var connectionState: ConnectionState?
    @Published var currentUser: User?
    @Published var chats: [Chat] = []
    @Published var selectedChat: Chat?
    @Published var messages: [Message] = []
    @Published var error: Swift.Error?

    // Computed for backward compatibility
    var isAuthenticated: Bool {
        if case .authorizationStateReady = authorizationState {
            return true
        }
        return false
    }

    // MARK: - Private
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demo") {
            setupDemoMode()
            return
        }
        #endif

        setupTDLib()
    }
```

**Step 2: Add TDLib setup methods**

Add after init:

```swift
    // MARK: - TDLib Setup

    private func setupTDLib() {
        print("📱 TelegramService: Initializing TDLib...")

        createTDLibDirectories()

        let client = TDLibClient()
        api = TdApi(client: client)

        api?.client.run { [weak self] data in
            do {
                let update = try TdApi.decoder.decode(Update.self, from: data)
                Task { @MainActor in
                    self?.handleUpdate(update)
                }
            } catch {
                print("❌ Failed to decode update: \(error)")
            }
        }

        print("📱 TDLib client created")
    }

    private func createTDLibDirectories() {
        let fileManager = FileManager.default
        let paths = [Config.tdlibDatabasePath, Config.tdlibFilesPath]

        for path in paths {
            if !fileManager.fileExists(atPath: path) {
                try? fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
        }
    }
```

**Step 3: Commit**

```bash
git add Telegrowl/Services/TelegramService.swift
git commit -m "feat(telegram): add TDLibKit initialization"
```

---

## Task 4: Rewrite TelegramService - Update Handler

**Files:**
- Modify: `Telegrowl/Services/TelegramService.swift`

**Step 1: Add update handler**

Add after setup methods:

```swift
    // MARK: - Update Handler

    private func handleUpdate(_ update: Update) {
        switch update {
        case .updateAuthorizationState(let state):
            handleAuthState(state.authorizationState)

        case .updateConnectionState(let state):
            connectionState = state.state

        case .updateNewMessage(let update):
            handleNewMessage(update.message)

        case .updateMessageContent(let update):
            handleMessageContentUpdate(messageId: update.messageId, chatId: update.chatId, content: update.newContent)

        case .updateFile(let update):
            handleFileUpdate(update.file)

        case .updateNewChat(let update):
            if !chats.contains(where: { $0.id == update.chat.id }) {
                chats.append(update.chat)
            }

        case .updateUser(let update):
            if update.user.id == currentUser?.id {
                currentUser = update.user
            }

        default:
            break
        }
    }

    private func handleAuthState(_ state: AuthorizationState) {
        print("📱 Auth state: \(state)")
        authorizationState = state

        switch state {
        case .authorizationStateWaitTdlibParameters:
            Task { await setTdlibParameters() }

        case .authorizationStateReady:
            Task {
                await loadCurrentUser()
                loadChats()
            }

        case .authorizationStateClosed:
            api = nil

        default:
            break
        }
    }

    private func setTdlibParameters() async {
        do {
            try await api?.setTdlibParameters(
                apiHash: Config.telegramApiHash,
                apiId: Config.telegramApiId,
                applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                databaseDirectory: Config.tdlibDatabasePath,
                databaseEncryptionKey: Data(),
                deviceModel: UIDevice.current.model,
                filesDirectory: Config.tdlibFilesPath,
                systemLanguageCode: Locale.current.language.languageCode?.identifier ?? "en",
                systemVersion: UIDevice.current.systemVersion,
                useChatInfoDatabase: true,
                useFileDatabase: true,
                useMessageDatabase: true,
                useSecretChats: false,
                useTestDc: false
            )
            print("📱 TDLib parameters set")
        } catch {
            print("❌ Failed to set TDLib parameters: \(error)")
            self.error = error
        }
    }
```

**Step 2: Commit**

```bash
git add Telegrowl/Services/TelegramService.swift
git commit -m "feat(telegram): add update handler and auth state machine"
```

---

## Task 5: Rewrite TelegramService - Authentication Methods

**Files:**
- Modify: `Telegrowl/Services/TelegramService.swift`

**Step 1: Add auth methods**

Add after update handler:

```swift
    // MARK: - Authentication

    func sendPhoneNumber(_ phone: String) {
        print("📱 Sending phone number: \(phone.prefix(4))****")

        Task {
            do {
                try await api?.setAuthenticationPhoneNumber(
                    phoneNumber: phone,
                    settings: nil
                )
            } catch {
                print("❌ Phone number error: \(error)")
                self.error = error
            }
        }
    }

    func sendCode(_ code: String) {
        print("📱 Sending auth code")

        Task {
            do {
                try await api?.checkAuthenticationCode(code: code)
            } catch {
                print("❌ Code verification error: \(error)")
                self.error = error
            }
        }
    }

    func sendPassword(_ password: String) {
        print("📱 Sending 2FA password")

        Task {
            do {
                try await api?.checkAuthenticationPassword(password: password)
            } catch {
                print("❌ Password error: \(error)")
                self.error = error
            }
        }
    }

    func logout() {
        print("📱 Logging out")

        Task {
            do {
                try await api?.logOut()
            } catch {
                print("❌ Logout error: \(error)")
            }
        }
    }

    private func loadCurrentUser() async {
        do {
            currentUser = try await api?.getMe()
            print("📱 Loaded user: \(currentUser?.firstName ?? "unknown")")
        } catch {
            print("❌ Failed to load user: \(error)")
        }
    }
```

**Step 2: Commit**

```bash
git add Telegrowl/Services/TelegramService.swift
git commit -m "feat(telegram): add authentication methods"
```

---

## Task 6: Rewrite TelegramService - Chat Methods

**Files:**
- Modify: `Telegrowl/Services/TelegramService.swift`

**Step 1: Add chat methods**

Add after auth methods:

```swift
    // MARK: - Chats

    func loadChats(limit: Int = 100) {
        print("📱 Loading chats...")

        Task {
            do {
                let chatList = try await api?.getChats(chatList: .chatListMain, limit: limit)

                // Load chat details for each chat ID
                for chatId in chatList?.chatIds ?? [] {
                    if let chat = try? await api?.getChat(chatId: chatId) {
                        if !chats.contains(where: { $0.id == chat.id }) {
                            chats.append(chat)
                        }
                    }
                }

                print("📱 Loaded \(chats.count) chats")
            } catch {
                print("❌ Failed to load chats: \(error)")
                self.error = error
            }
        }
    }

    func selectChat(_ chat: Chat) {
        selectedChat = chat
        Config.targetChatId = chat.id
        messages = []
        loadMessages(chatId: chat.id)
    }

    func searchChat(username: String) {
        print("📱 Searching for @\(username)")

        Task {
            do {
                let chat = try await api?.searchPublicChat(username: username)
                if let chat = chat, !chats.contains(where: { $0.id == chat.id }) {
                    chats.insert(chat, at: 0)
                }
            } catch {
                print("❌ Search error: \(error)")
                self.error = error
            }
        }
    }
```

**Step 2: Commit**

```bash
git add Telegrowl/Services/TelegramService.swift
git commit -m "feat(telegram): add chat loading and search"
```

---

## Task 7: Rewrite TelegramService - Message Methods

**Files:**
- Modify: `Telegrowl/Services/TelegramService.swift`

**Step 1: Add message methods**

Add after chat methods:

```swift
    // MARK: - Messages

    func loadMessages(chatId: Int64, limit: Int = 50) {
        print("📱 Loading messages for chat \(chatId)")

        Task {
            do {
                let history = try await api?.getChatHistory(
                    chatId: chatId,
                    fromMessageId: 0,
                    limit: limit,
                    offset: 0,
                    onlyLocal: false
                )

                messages = history?.messages ?? []
                print("📱 Loaded \(messages.count) messages")
            } catch {
                print("❌ Failed to load messages: \(error)")
            }
        }
    }

    func sendVoiceMessage(audioURL: URL, duration: Int, waveform: Data?) {
        guard let chat = selectedChat else {
            print("❌ No chat selected")
            return
        }

        print("📤 Sending voice message to chat \(chat.id)")
        print("   Duration: \(duration)s")
        print("   File: \(audioURL.lastPathComponent)")

        Task {
            do {
                let inputFile = InputFile.inputFileLocal(path: audioURL.path)
                let voiceNote = InputMessageContent.inputMessageVoiceNote(
                    InputMessageVoiceNote(
                        caption: nil,
                        duration: duration,
                        selfDestructType: nil,
                        voiceNote: inputFile,
                        waveform: waveform?.base64EncodedString() ?? ""
                    )
                )

                _ = try await api?.sendMessage(
                    chatId: chat.id,
                    inputMessageContent: voiceNote,
                    messageThreadId: 0,
                    options: nil,
                    replyMarkup: nil,
                    replyTo: nil
                )

                print("📤 Voice message sent")
            } catch {
                print("❌ Failed to send voice: \(error)")
                self.error = error
            }
        }
    }

    private func handleNewMessage(_ message: Message) {
        guard message.chatId == selectedChat?.id else { return }

        if !messages.contains(where: { $0.id == message.id }) {
            messages.append(message)
        }

        // Notify for auto-play if incoming voice
        if !message.isOutgoing,
           case .messageVoiceNote = message.content {
            NotificationCenter.default.post(name: .newVoiceMessage, object: message)
        }
    }

    private func handleMessageContentUpdate(messageId: Int64, chatId: Int64, content: MessageContent) {
        if let index = messages.firstIndex(where: { $0.id == messageId && $0.chatId == chatId }) {
            // Messages are structs, need to create updated copy
            var updatedMessage = messages[index]
            // Note: Message.content is let, so we handle this via file updates instead
            print("📱 Message content updated: \(messageId)")
        }
    }
```

**Step 2: Commit**

```bash
git add Telegrowl/Services/TelegramService.swift
git commit -m "feat(telegram): add message loading and sending"
```

---

## Task 8: Rewrite TelegramService - File Download & Demo Mode

**Files:**
- Modify: `Telegrowl/Services/TelegramService.swift`

**Step 1: Add file download and demo mode**

Add after message methods:

```swift
    // MARK: - File Downloads

    func downloadVoice(_ voiceNote: VoiceNote, completion: @escaping (URL?) -> Void) {
        let fileId = voiceNote.voice.id
        print("📥 Downloading voice file: \(fileId)")

        Task {
            do {
                let file = try await api?.downloadFile(
                    fileId: fileId,
                    limit: 0,
                    offset: 0,
                    priority: 32,
                    synchronous: true
                )

                if let path = file?.local.path, !path.isEmpty {
                    print("📥 Downloaded to: \(path)")
                    completion(URL(fileURLWithPath: path))
                } else {
                    completion(nil)
                }
            } catch {
                print("❌ Download error: \(error)")
                completion(nil)
            }
        }
    }

    private func handleFileUpdate(_ file: File) {
        print("📁 File update: \(file.id), downloaded: \(file.local.isDownloadingCompleted)")

        if file.local.isDownloadingCompleted, let path = file.local.path, !path.isEmpty {
            NotificationCenter.default.post(
                name: .voiceDownloaded,
                object: URL(fileURLWithPath: path)
            )
        }
    }

    // MARK: - Demo Mode

    #if DEBUG
    private func setupDemoMode() {
        print("📱 TelegramService: Demo mode enabled")
        isDemoMode = true
        authorizationState = .authorizationStateWaitPhoneNumber
    }

    func simulateLogin() {
        guard isDemoMode else { return }

        authorizationState = .authorizationStateReady

        // Note: Can't easily create mock TDLibKit types as they have internal initializers
        // Demo mode will show empty state but auth will appear successful
        print("📱 Demo: Simulated login")
    }
    #endif
}

// MARK: - Notifications

extension Notification.Name {
    static let newVoiceMessage = Notification.Name("newVoiceMessage")
    static let voiceDownloaded = Notification.Name("voiceDownloaded")
}
```

**Step 2: Commit**

```bash
git add Telegrowl/Services/TelegramService.swift
git commit -m "feat(telegram): add file downloads and demo mode"
```

---

## Task 9: Update AuthView for TDLibKit Types

**Files:**
- Modify: `Telegrowl/Views/AuthView.swift`

**Step 1: Update auth state switch**

Replace lines 13-29 with:

```swift
            Form {
                if let state = telegramService.authorizationState {
                    switch state {
                    case .authorizationStateWaitPhoneNumber:
                        phoneSection

                    case .authorizationStateWaitCode:
                        codeSection

                    case .authorizationStateWaitPassword:
                        passwordSection

                    case .authorizationStateReady:
                        successSection

                    default:
                        // Handle other states (initial, closing, etc.)
                        ProgressView("Connecting...")
                    }
                } else {
                    ProgressView("Initializing...")
                }

                // Show error if present
                if let error = telegramService.error {
                    errorSection(error.localizedDescription)
                }
            }
```

**Step 2: Update error section call**

Replace line 124-127:

```swift
    private func errorSection(_ message: String) -> some View {
        Section {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(message)
            }

            Button("Try Again") {
                telegramService.error = nil
            }
        }
    }
```

**Step 3: Add TDLibKit import**

Add at top of file:

```swift
import SwiftUI
import TDLibKit
```

**Step 4: Commit**

```bash
git add Telegrowl/Views/AuthView.swift
git commit -m "refactor(auth): update for TDLibKit auth states"
```

---

## Task 10: Update ContentView for TDLibKit Types

**Files:**
- Modify: `Telegrowl/Views/ContentView.swift`

**Step 1: Add TDLibKit import**

Add after SwiftUI import:

```swift
import TDLibKit
```

**Step 2: Update connection status helpers**

Replace `connectionStatusColor` (lines 300-308):

```swift
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
```

Replace `connectionStatusText` (lines 311-324):

```swift
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
```

**Step 3: Update handleNewVoiceMessage**

Replace lines 341-355:

```swift
    private func handleNewVoiceMessage(_ notification: Notification) {
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
```

**Step 4: Update chat title access**

Replace line 88:

```swift
                            Text(chatTitle(chat))
```

Add helper method:

```swift
    private func chatTitle(_ chat: Chat) -> String {
        switch chat.type {
        case .chatTypePrivate, .chatTypeSecret:
            return chat.title
        case .chatTypeBasicGroup:
            return chat.title
        case .chatTypeSupergroup:
            return chat.title
        }
    }
```

**Step 5: Commit**

```bash
git add Telegrowl/Views/ContentView.swift
git commit -m "refactor(content): update for TDLibKit types"
```

---

## Task 11: Update ConversationView for TDLibKit Types

**Files:**
- Modify: `Telegrowl/Views/ConversationView.swift`

**Step 1: Add TDLibKit import**

```swift
import SwiftUI
import TDLibKit
```

**Step 2: Update MessageBubble**

Replace struct (lines 33-123):

```swift
struct MessageBubble: View {
    let message: Message
    @EnvironmentObject var audioService: AudioService

    @State private var isPlaying = false

    var body: some View {
        HStack {
            if message.isOutgoing {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                contentView
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.isOutgoing
                            ? Color.blue
                            : Color(hex: "2a2a3e")
                    )
                    .cornerRadius(16)

                HStack(spacing: 4) {
                    Text(formatTime(Date(timeIntervalSince1970: TimeInterval(message.date))))
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))

                    if message.isOutgoing {
                        sendingStateIcon
                    }
                }
            }

            if !message.isOutgoing {
                Spacer(minLength: 60)
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch message.content {
        case .messageText(let text):
            Text(text.text.text)
                .foregroundColor(.white)

        case .messageVoiceNote(let voiceContent):
            VoiceMessageView(
                voiceNote: voiceContent.voiceNote,
                isPlaying: $isPlaying,
                isOutgoing: message.isOutgoing
            )

        case .messagePhoto:
            Image(systemName: "photo")
                .foregroundColor(.white)

        default:
            Text("[Unsupported message]")
                .foregroundColor(.white.opacity(0.5))
                .italic()
        }
    }

    @ViewBuilder
    private var sendingStateIcon: some View {
        if let sendingState = message.sendingState {
            switch sendingState {
            case .messageSendingStatePending:
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
            case .messageSendingStateFailed:
                Image(systemName: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        } else {
            // Message was sent successfully
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
```

**Step 3: Update VoiceMessageView**

Replace struct (lines 127-177):

```swift
struct VoiceMessageView: View {
    let voiceNote: VoiceNote
    @Binding var isPlaying: Bool
    let isOutgoing: Bool

    @EnvironmentObject var audioService: AudioService
    @EnvironmentObject var telegramService: TelegramService

    var body: some View {
        HStack(spacing: 12) {
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                WaveformView(waveform: voiceNote.waveform, isPlaying: isPlaying)
                    .frame(height: 24)

                Text(formatDuration(voiceNote.duration))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .frame(width: 200)
    }

    private func togglePlayback() {
        if isPlaying {
            audioService.stopPlayback()
            isPlaying = false
        } else {
            let localPath = voiceNote.voice.local.path
            if !localPath.isEmpty {
                audioService.play(url: URL(fileURLWithPath: localPath))
                isPlaying = true
            } else {
                // Download first
                telegramService.downloadVoice(voiceNote) { url in
                    if let url = url {
                        audioService.play(url: url)
                        isPlaying = true
                    }
                }
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
```

**Step 4: Update WaveformView**

Replace waveform type (line 182):

```swift
struct WaveformView: View {
    let waveform: Data?
    let isPlaying: Bool
```

Note: TDLibKit's VoiceNote.waveform is already Data, so this may work as-is. If it's String (base64), decode it:

```swift
    private var waveformData: Data? {
        // TDLibKit stores waveform as base64 string
        if let waveform = waveform {
            return waveform
        }
        return nil
    }
```

**Step 5: Commit**

```bash
git add Telegrowl/Views/ConversationView.swift
git commit -m "refactor(conversation): update for TDLibKit Message type"
```

---

## Task 12: Update ChatListView for TDLibKit Types

**Files:**
- Modify: `Telegrowl/Views/ChatListView.swift`

**Step 1: Add TDLibKit import**

```swift
import SwiftUI
import TDLibKit
```

**Step 2: Update filteredChats**

Replace lines 10-18:

```swift
    var filteredChats: [Chat] {
        if searchText.isEmpty {
            return telegramService.chats
        }
        return telegramService.chats.filter { chat in
            chat.title.localizedCaseInsensitiveContains(searchText)
        }
    }
```

**Step 3: Update ChatRow**

Replace struct (lines 79-176):

```swift
struct ChatRow: View {
    let chat: Chat

    var body: some View {
        HStack(spacing: 12) {
            chatAvatar

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(chat.title)
                        .fontWeight(.medium)

                    Spacer()

                    if let lastMessage = chat.lastMessage {
                        Text(formatTime(Date(timeIntervalSince1970: TimeInterval(lastMessage.date))))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    if let username = chatUsername {
                        Text("@\(username)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if chat.unreadCount > 0 {
                        Text("\(chat.unreadCount)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var chatUsername: String? {
        // Username not directly on Chat, would need to fetch from supergroup/user info
        // For MVP, return nil
        nil
    }

    @ViewBuilder
    private var chatAvatar: some View {
        ZStack {
            Circle()
                .fill(avatarGradient)
                .frame(width: 50, height: 50)

            Text(avatarInitials)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
        }
    }

    private var avatarGradient: LinearGradient {
        let colors: [Color] = [
            .red, .orange, .yellow, .green, .blue, .purple, .pink
        ]
        let index = abs(chat.id.hashValue) % colors.count
        return LinearGradient(
            colors: [colors[index], colors[(index + 1) % colors.count]],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var avatarInitials: String {
        let words = chat.title.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(chat.title.prefix(2)).uppercased()
    }

    private func formatTime(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            return formatter.string(from: date)
        }
    }
}
```

**Step 4: Commit**

```bash
git add Telegrowl/Views/ChatListView.swift
git commit -m "refactor(chatlist): update for TDLibKit Chat type"
```

---

## Task 13: Final Cleanup and Build Test

**Step 1: Remove old TG* types from TelegramService**

Ensure the bottom of TelegramService.swift no longer contains TGUser, TGChat, TGMessage, etc. (They should have been removed in Task 3-8).

**Step 2: Build project**

Run: `cd /Users/vs/workspace/telegrowl && swift build 2>&1 | head -50`

Fix any compile errors that arise.

**Step 3: Final commit**

```bash
git add -A
git commit -m "feat: complete TDLibKit integration

- Replace stub implementations with real TDLib calls
- Use TDLibKit types directly (removed TG* wrappers)
- Auth flow: phone → code → 2FA → ready
- Load chats and messages from Telegram
- Send voice messages via TDLib
- Download voice files for playback
- Preserve demo mode for UI testing"
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Add TDLibKit dependency | Package.swift |
| 2 | Create Config template | Config.swift.template |
| 3 | TelegramService core structure | TelegramService.swift |
| 4 | Update handler | TelegramService.swift |
| 5 | Auth methods | TelegramService.swift |
| 6 | Chat methods | TelegramService.swift |
| 7 | Message methods | TelegramService.swift |
| 8 | File download + demo mode | TelegramService.swift |
| 9 | Update AuthView | AuthView.swift |
| 10 | Update ContentView | ContentView.swift |
| 11 | Update ConversationView | ConversationView.swift |
| 12 | Update ChatListView | ChatListView.swift |
| 13 | Final cleanup + build | All |

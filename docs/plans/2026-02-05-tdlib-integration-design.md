# TDLib Integration Design

## Overview

Integrate TDLibKit to enable real Telegram communication in Telegrowl. This replaces the current stub implementation with working TDLib calls.

## Decisions

| Decision | Choice |
|----------|--------|
| TDLib wrapper | TDLibKit via SPM |
| Model types | Use TDLibKit types directly (remove custom TG* types) |
| Client lifecycle | Initialize in TelegramService.init() |
| Demo mode | Preserve for UI testing |

## Dependencies

**Package.swift:**
```swift
dependencies: [
    .package(url: "https://github.com/Swiftgram/TDLibKit.git", from: "3.0.0"),
],
targets: [
    .target(
        name: "Telegrowl",
        dependencies: ["TDLibKit"],
        path: "Telegrowl"
    ),
]
```

## Architecture

### TelegramService Structure

```swift
@MainActor
class TelegramService: ObservableObject {
    static let shared = TelegramService()

    // TDLib client
    private var api: TdApi?
    private var isDemoMode = false

    // Published state (TDLibKit types)
    @Published var authorizationState: AuthorizationState?
    @Published var connectionState: ConnectionState?
    @Published var currentUser: User?
    @Published var chats: [Chat] = []
    @Published var selectedChat: Chat?
    @Published var messages: [Message] = []
    @Published var error: TDLibKit.Error?
}
```

### Initialization

```swift
private init() {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-demo") {
        setupDemoMode()
        return
    }
    #endif
    setupTDLib()
}

private func setupTDLib() {
    api = TdApi(client: TdClientImpl(completionQueue: .main))
    api?.startTdLibUpdateHandler()
    api?.setUpdateHandler { [weak self] update in
        Task { @MainActor in
            self?.handleUpdate(update)
        }
    }
}
```

### Update Handler

```swift
private func handleUpdate(_ update: Update) {
    switch update {
    case .updateAuthorizationState(let state):
        handleAuthState(state.authorizationState)
    case .updateConnectionState(let state):
        connectionState = state.state
    case .updateNewMessage(let msg):
        handleNewMessage(msg.message)
    case .updateFile(let file):
        handleFileUpdate(file.file)
    case .updateNewChat(let chat):
        handleNewChat(chat.chat)
    default:
        break
    }
}
```

### Authentication Flow

TDLib drives auth via state updates:

1. `authorizationStateWaitTdlibParameters` → call `setTdlibParameters()`
2. `authorizationStateWaitPhoneNumber` → UI shows phone input
3. `authorizationStateWaitCode` → UI shows code input
4. `authorizationStateWaitPassword` → UI shows 2FA input
5. `authorizationStateReady` → load user and chats

```swift
private func setTdlibParameters() async throws {
    try await api?.setTdlibParameters(
        apiHash: Config.telegramApiHash,
        apiId: Config.telegramApiId,
        applicationVersion: "1.0",
        databaseDirectory: Config.tdlibDatabasePath,
        deviceModel: "iOS",
        filesDirectory: Config.tdlibFilesPath,
        systemLanguageCode: "en",
        systemVersion: UIDevice.current.systemVersion,
        useSecretChats: false,
        useTestDc: false
    )
}
```

### Sending Voice Messages

```swift
func sendVoiceMessage(audioURL: URL, duration: Int, waveform: Data?) async throws {
    guard let chat = selectedChat else { return }

    let voiceNote = InputMessageVoiceNote(
        caption: nil,
        duration: duration,
        selfDestructType: nil,
        voiceNote: .inputFileLocal(path: audioURL.path),
        waveform: waveform?.base64EncodedString()
    )

    _ = try await api?.sendMessage(
        chatId: chat.id,
        inputMessageContent: .inputMessageVoiceNote(voiceNote),
        messageThreadId: 0,
        options: nil,
        replyMarkup: nil,
        replyTo: nil
    )
}
```

### Downloading Voice Files

```swift
func downloadVoiceFile(_ voiceNote: VoiceNote) async throws -> String? {
    let file = try await api?.downloadFile(
        fileId: voiceNote.voice.id,
        limit: 0,
        offset: 0,
        priority: 32,
        synchronous: true
    )
    return file?.local.path
}
```

## Files to Modify

| File | Changes |
|------|---------|
| `Package.swift` | Uncomment TDLibKit dependency |
| `TelegramService.swift` | Full rewrite with TDLibKit integration |
| `ContentView.swift` | Update type references (TGChat → Chat, etc.) |
| `ConversationView.swift` | Update to use TDLibKit Message type |
| `ChatListView.swift` | Update to use TDLibKit Chat type |
| `AuthView.swift` | Update auth state checks |

## Types to Remove

Remove from TelegramService.swift (lines 362-449):
- `TGUser` → `TDLibKit.User`
- `TGChat` → `TDLibKit.Chat`
- `TGMessage` → `TDLibKit.Message`
- `TGVoiceNote` → `TDLibKit.VoiceNote`
- `TGPhoto` → `TDLibKit.Photo`
- `TGFile` → `TDLibKit.File`
- `TGError` → `TDLibKit.Error`
- `TGUpdate` → `TDLibKit.Update`
- `TGMessageContent` → `TDLibKit.MessageContent`

## Demo Mode

Preserved for UI testing:

```swift
private func setupDemoMode() {
    isDemoMode = true
    authorizationState = .authorizationStateWaitPhoneNumber
}

func simulateLogin() {
    guard isDemoMode else { return }
    authorizationState = .authorizationStateReady
    // Create mock User, Chat, Message objects
}
```

## Implementation Order

1. Update Package.swift with TDLibKit dependency
2. Rewrite TelegramService.swift with TDLib integration
3. Update views to use TDLibKit types
4. Test auth flow on real device
5. Test message sending/receiving

import Foundation
import Combine
import TDLibKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Telegram Service

/// Main service for Telegram communication via TDLib
@MainActor
class TelegramService: ObservableObject {
    static let shared = TelegramService()

    // MARK: - TDLib Client
    private var manager: TDLibClientManager?
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
        if case .authorizationStateReady? = authorizationState {
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

    // MARK: - TDLib Setup

    private func setupTDLib() {
        print("📱 TelegramService: Initializing TDLib...")

        createTDLibDirectories()

        manager = TDLibClientManager()
        api = manager?.createClient(updateHandler: { [weak self] data, client in
            do {
                let update = try client.decoder.decode(Update.self, from: data)
                Task { @MainActor in
                    self?.handleUpdate(update)
                }
            } catch {
                print("❌ Failed to decode update: \(error)")
            }
        })

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
            manager = nil

        default:
            break
        }
    }

    private func setTdlibParameters() async {
        #if canImport(UIKit)
        let deviceModel = UIDevice.current.model
        let systemVersion = UIDevice.current.systemVersion
        #else
        let deviceModel = "Mac"
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #endif

        do {
            try await api?.setTdlibParameters(
                apiHash: Config.telegramApiHash,
                apiId: Config.telegramApiId,
                applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                databaseDirectory: Config.tdlibDatabasePath,
                databaseEncryptionKey: Data(),
                deviceModel: deviceModel,
                filesDirectory: Config.tdlibFilesPath,
                systemLanguageCode: Locale.current.language.languageCode?.identifier ?? "en",
                systemVersion: systemVersion,
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

    // MARK: - Authentication

    func sendPhoneNumber(_ phone: String) {
        print("📱 Sending phone number: \(phone.prefix(4))****")

        #if DEBUG
        if isDemoMode {
            // In demo mode, simulate transition to code entry state.
            // Note: TDLibKit types have internal initializers, so we can't create
            // AuthorizationStateWaitCode with proper parameters. We use a simple
            // state transition that the UI can handle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Transition directly to ready state since we can't create intermediate states
                self.authorizationState = .authorizationStateReady
                print("📱 Demo: Simulated phone verification -> ready")
            }
            return
        }
        #endif

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

    // MARK: - Chats

    func loadChats(limit: Int = 100) {
        print("📱 Loading chats...")

        Task {
            do {
                let chatList = try await api?.getChats(chatList: .chatListMain, limit: limit)

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

                // TDLib returns newest-first, reverse for oldest-first display (standard chat order)
                messages = Array((history?.messages ?? []).reversed())
                print("📱 Loaded \(messages.count) messages")
            } catch {
                print("❌ Failed to load messages: \(error)")
            }
        }
    }

    func sendVoiceMessage(audioURL: URL, duration: Int, waveform: Data?, chatId: Int64? = nil) async throws {
        let targetChatId = chatId ?? selectedChat?.id
        guard let targetChatId else {
            print("❌ No chat selected")
            return
        }

        print("📤 Sending voice message to chat \(targetChatId)")
        print("   Duration: \(duration)s")
        print("   File: \(audioURL.lastPathComponent)")

        let inputFile = InputFile.inputFileLocal(InputFileLocal(path: audioURL.path))
        let voiceNote = InputMessageContent.inputMessageVoiceNote(
            InputMessageVoiceNote(
                caption: nil,
                duration: duration,
                selfDestructType: nil,
                voiceNote: inputFile,
                waveform: waveform ?? Data()
            )
        )

        _ = try await api?.sendMessage(
            chatId: targetChatId,
            inputMessageContent: voiceNote,
            options: nil,
            replyMarkup: nil,
            replyTo: nil,
            topicId: nil
        )

        print("📤 Voice message sent")
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
        guard chatId == selectedChat?.id else { return }

        // Message is a struct with `let content`, so we can't mutate it directly.
        // Reload the updated message from TDLib instead.
        Task {
            do {
                if let updatedMessage = try await api?.getMessage(chatId: chatId, messageId: messageId) {
                    if let index = messages.firstIndex(where: { $0.id == messageId }) {
                        messages[index] = updatedMessage
                        print("📱 Message content updated: \(messageId)")
                    }
                }
            } catch {
                print("❌ Failed to reload message: \(error)")
            }
        }
    }

    // MARK: - File Downloads

    func downloadPhoto(file: File) async throws -> File {
        guard let api else { throw TelegramServiceError.notConnected }
        return try await api.downloadFile(
            fileId: file.id,
            limit: 0,
            offset: 0,
            priority: 1,
            synchronous: true
        )
    }

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

        if file.local.isDownloadingCompleted, !file.local.path.isEmpty {
            NotificationCenter.default.post(
                name: .voiceDownloaded,
                object: URL(fileURLWithPath: file.local.path)
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
        print("📱 Demo: Simulated login")
    }
    #endif
}

// MARK: - Errors

enum TelegramServiceError: Error {
    case notConnected
}

// MARK: - Notifications

extension Foundation.Notification.Name {
    static let newVoiceMessage = Foundation.Notification.Name("newVoiceMessage")
    static let voiceDownloaded = Foundation.Notification.Name("voiceDownloaded")
}

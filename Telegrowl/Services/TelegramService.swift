import Foundation
import Combine
import Network
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
    private(set) var api: TDLibClient?
    private var isDemoMode = false

    // MARK: - Published State
    @Published var authorizationState: AuthorizationState?
    @Published var connectionState: ConnectionState?
    @Published var currentUser: User?
    @Published var chats: [Chat] = []
    @Published var selectedChat: Chat?
    @Published var messages: [Message] = []
    @Published var error: Swift.Error?
    @Published var isLoadingMore = false
    @Published var hasMoreMessages = true

    // Computed for backward compatibility
    var isAuthenticated: Bool {
        if case .authorizationStateReady? = authorizationState {
            return true
        }
        return false
    }

    // MARK: - Private
    private var cancellables = Set<AnyCancellable>()
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "com.telegrowl.networkMonitor")

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
        api = manager?.createClient(updateHandler: { [weak self] (data: Data, client: TDLibClient) in
            do {
                let update = try client.decoder.decode(Update.self, from: data)
                Task { @MainActor in
                    self?.handleUpdate(update)
                }
            } catch {
                print("❌ Failed to decode update: \(error)")
            }
        })

        print("📱 TDLib client created, api=\(api != nil ? "ok" : "nil")")

        // Reduce TDLib internal log noise (2=warnings, 4=debug)
        Task {
            #if DEBUG
            try? await api?.setLogVerbosityLevel(newVerbosityLevel: 4)
            #else
            try? await api?.setLogVerbosityLevel(newVerbosityLevel: 2)
            #endif
        }

        startNetworkMonitor()
    }

    // MARK: - Network Monitoring

    /// TDLib on iOS doesn't auto-detect network availability.
    /// We must inform it via setNetworkType when the network changes.
    private func startNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let networkType: NetworkType
            if path.status == .satisfied {
                if path.usesInterfaceType(.wifi) {
                    networkType = .networkTypeWiFi
                } else if path.usesInterfaceType(.cellular) {
                    networkType = .networkTypeMobile
                } else {
                    networkType = .networkTypeOther
                }
            } else {
                networkType = .networkTypeNone
            }

            print("📱 Network changed: \(networkType)")
            Task { @MainActor in
                self?.updateNetworkType(networkType)
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    private func updateNetworkType(_ type: NetworkType) {
        Task {
            do {
                try await api?.setNetworkType(type: type)
                print("📱 TDLib network type set to: \(type)")
            } catch {
                print("❌ Failed to set network type: \(error)")
            }
        }
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
            print("📱 Connection state: \(state.state)")
            connectionState = state.state

        case .updateNewMessage(let update):
            handleNewMessage(update.message)

        case .updateMessageContent(let update):
            handleMessageContentUpdate(messageId: update.messageId, chatId: update.chatId, content: update.newContent)

        case .updateMessageSendSucceeded(let update):
            handleMessageSendSucceeded(oldMessageId: update.oldMessageId, message: update.message)

        case .updateMessageSendFailed(let update):
            handleMessageSendFailed(oldMessageId: update.oldMessageId, message: update.message, errorMessage: update.error.message)

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
        messages = []
        hasMoreMessages = true
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
                hasMoreMessages = messages.count >= limit
                print("📱 Loaded \(messages.count) messages")
            } catch {
                print("❌ Failed to load messages: \(error)")
            }
        }
    }

    func loadMoreMessages(chatId: Int64) {
        guard !isLoadingMore, hasMoreMessages else { return }
        guard let oldestMessageId = messages.first?.id else { return }

        isLoadingMore = true
        print("📱 Loading more messages before \(oldestMessageId)")

        Task {
            do {
                let history = try await api?.getChatHistory(
                    chatId: chatId,
                    fromMessageId: oldestMessageId,
                    limit: 30,
                    offset: 0,
                    onlyLocal: false
                )

                let olderMessages = Array((history?.messages ?? []).reversed())
                if olderMessages.isEmpty {
                    hasMoreMessages = false
                    print("📱 No more messages to load")
                } else {
                    let existingIds = Set(messages.map { $0.id })
                    let newMessages = olderMessages.filter { !existingIds.contains($0.id) }
                    if newMessages.isEmpty {
                        hasMoreMessages = false
                    } else {
                        messages.insert(contentsOf: newMessages, at: 0)
                        print("📱 Loaded \(newMessages.count) more messages (total: \(messages.count))")
                    }
                }
                isLoadingMore = false
            } catch {
                print("❌ Failed to load more messages: \(error)")
                isLoadingMore = false
            }
        }
    }

    @discardableResult
    func sendVoiceMessage(audioURL: URL, duration: Int, waveform: Data?, caption: String? = nil, chatId: Int64? = nil) async throws -> Int64 {
        let targetChatId = chatId ?? selectedChat?.id
        guard let targetChatId else {
            print("❌ No chat selected")
            return 0
        }

        // Resolve symlinks to get canonical path that TDLib's realpath() can find
        let resolvedURL = audioURL.resolvingSymlinksInPath()
        let filePath = resolvedURL.path

        print("📤 Sending voice message to chat \(targetChatId)")
        print("   Duration: \(duration)s")
        print("   File: \(audioURL.lastPathComponent)")
        print("   Path: \(filePath)")
        print("   Exists: \(FileManager.default.fileExists(atPath: filePath))")

        let inputFile = InputFile.inputFileLocal(InputFileLocal(path: filePath))
        let captionText: FormattedText? = caption.map { FormattedText(entities: [], text: $0) }
        let voiceNote = InputMessageContent.inputMessageVoiceNote(
            InputMessageVoiceNote(
                caption: captionText,
                duration: duration,
                selfDestructType: nil,
                voiceNote: inputFile,
                waveform: waveform ?? Data()
            )
        )

        do {
            let result = try await api?.sendMessage(
                chatId: targetChatId,
                inputMessageContent: voiceNote,
                options: nil,
                replyMarkup: nil,
                replyTo: nil,
                topicId: nil
            )
            let msgId = result?.id ?? 0
            print("📤 sendMessage returned: id=\(msgId), sendingState=\(String(describing: result?.sendingState))")
            return msgId
        } catch {
            print("📤 sendMessage threw: \(error)")
            throw error
        }
    }

    @discardableResult
    func sendTextMessage(text: String, chatId: Int64) async throws -> Int64 {
        guard let api else {
            print("❌ TDLib client not ready")
            throw TelegramServiceError.notConnected
        }

        print("📤 Sending text message to chat \(chatId)")

        let formattedText = FormattedText(entities: [], text: text)
        let content = InputMessageContent.inputMessageText(
            InputMessageText(
                clearDraft: true,
                linkPreviewOptions: nil,
                text: formattedText
            )
        )

        let result = try await api.sendMessage(
            chatId: chatId,
            inputMessageContent: content,
            options: nil,
            replyMarkup: nil,
            replyTo: nil,
            topicId: nil
        )
        let msgId = result?.id ?? 0
        print("📤 sendTextMessage returned: id=\(msgId)")
        return msgId
    }

    private func handleNewMessage(_ message: Message) {
        // Append to messages array if viewing this chat
        if message.chatId == selectedChat?.id {
            if !messages.contains(where: { $0.id == message.id }) {
                messages.append(message)
            }
        }

        // Notify for incoming messages (any chat)
        if !message.isOutgoing {
            NotificationCenter.default.post(name: .newIncomingMessage, object: message)

            // Legacy: specific voice note notification
            if case .messageVoiceNote = message.content {
                NotificationCenter.default.post(name: .newVoiceMessage, object: message)
            }
        }
    }

    private func handleMessageSendSucceeded(oldMessageId: Int64, message: Message) {
        // Replace the local message (with temp ID) with the server message
        if let index = messages.firstIndex(where: { $0.id == oldMessageId }) {
            messages[index] = message
            print("📤 Message send succeeded: \(oldMessageId) → \(message.id)")
        }

        NotificationCenter.default.post(
            name: .messageSendSucceeded,
            object: nil,
            userInfo: ["oldMessageId": oldMessageId, "newMessageId": message.id]
        )
    }

    private func handleMessageSendFailed(oldMessageId: Int64, message: Message, errorMessage: String) {
        print("❌ Message send failed: \(oldMessageId), error: \(errorMessage)")

        // Update the local message to show failure state
        if let index = messages.firstIndex(where: { $0.id == oldMessageId }) {
            messages[index] = message
        }

        // Post notification so queue/UI can handle retry
        NotificationCenter.default.post(
            name: .messageSendFailed,
            object: message,
            userInfo: ["errorMessage": errorMessage, "oldMessageId": oldMessageId]
        )
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

    /// File IDs with pending (async) voice downloads. When the download completes
    /// via updateFile, we post `.voiceDownloaded` so callers can play the file.
    private var pendingVoiceDownloads = Set<Int>()

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

        // If already downloaded locally, return immediately
        if !voiceNote.voice.local.path.isEmpty && voiceNote.voice.local.isDownloadingCompleted {
            print("📥 Voice file already local: \(voiceNote.voice.local.path)")
            completion(URL(fileURLWithPath: voiceNote.voice.local.path))
            return
        }

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
                    // Synchronous download returned no path — start async download
                    // so TDLib retries when connectivity returns
                    print("📥 Sync download returned no path, starting async download for \(fileId)")
                    startAsyncVoiceDownload(fileId: fileId)
                    completion(nil)
                }
            } catch {
                print("❌ Download error: \(error), starting async download for \(fileId)")
                startAsyncVoiceDownload(fileId: fileId)
                completion(nil)
            }
        }
    }

    /// Start a non-blocking download that TDLib will complete when connectivity returns.
    private func startAsyncVoiceDownload(fileId: Int) {
        pendingVoiceDownloads.insert(fileId)

        Task {
            do {
                try await api?.downloadFile(
                    fileId: fileId,
                    limit: 0,
                    offset: 0,
                    priority: 32,
                    synchronous: false
                )
                print("📥 Async download queued for fileId=\(fileId)")
            } catch {
                print("❌ Async download request failed for fileId=\(fileId): \(error)")
            }
        }
    }

    private func handleFileUpdate(_ file: File) {
        if file.local.isDownloadingCompleted, !file.local.path.isEmpty {
            let wasPending = pendingVoiceDownloads.remove(file.id) != nil
            if wasPending {
                print("📥 Deferred voice download completed: fileId=\(file.id) -> \(file.local.path)")
            }

            NotificationCenter.default.post(
                name: .voiceDownloaded,
                object: nil,
                userInfo: [
                    "fileId": file.id,
                    "url": URL(fileURLWithPath: file.local.path)
                ]
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

enum TelegramServiceError: Swift.Error {
    case notConnected
}

// MARK: - Notifications

extension Foundation.Notification.Name {
    static let newIncomingMessage = Foundation.Notification.Name("newIncomingMessage")
    static let newVoiceMessage = Foundation.Notification.Name("newVoiceMessage")
    static let messageSendFailed = Foundation.Notification.Name("messageSendFailed")
    static let voiceDownloaded = Foundation.Notification.Name("voiceDownloaded")
}

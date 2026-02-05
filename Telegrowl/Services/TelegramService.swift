import Foundation
import Combine
import TDLibKit
import UIKit

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

    // MARK: - Placeholder methods (to be implemented in tasks 4-8)

    private func handleUpdate(_ update: Update) {
        // Task 4 will implement this
    }

    private func setupDemoMode() {
        isDemoMode = true
        authorizationState = .authorizationStateWaitPhoneNumber
    }

    // MARK: - Demo Mode (for testing without TDLib)

    #if DEBUG
    func simulateLogin() {
        authorizationState = .authorizationStateReady
        // Note: currentUser, chats, selectedChat now use TDLibKit types
        // Full demo mode implementation will be updated in later tasks
    }
    #endif
    
    // MARK: - Authentication
    
    func sendPhoneNumber(_ phone: String) {
        print("📱 Sending phone number: \(phone.prefix(4))****")
        
        // TODO: TDLib call
        // td_send(clientId, SetAuthenticationPhoneNumber(phone_number: phone))
        
        authState = .waitingCode(codeInfo: "Code sent to \(phone)")
    }
    
    func sendCode(_ code: String) {
        print("📱 Sending auth code")
        
        // TODO: TDLib call
        // td_send(clientId, CheckAuthenticationCode(code: code))
        
        // For demo:
        #if DEBUG
        simulateLogin()
        #endif
    }
    
    func sendPassword(_ password: String) {
        print("📱 Sending 2FA password")
        
        // TODO: TDLib call
        // td_send(clientId, CheckAuthenticationPassword(password: password))
    }
    
    func logout() {
        print("📱 Logging out")
        authState = .loggingOut
        
        // TODO: TDLib call
        // td_send(clientId, LogOut())
        
        isAuthenticated = false
        authState = .waitingPhoneNumber
        currentUser = nil
        chats = []
        selectedChat = nil
        messages = []
    }
    
    // MARK: - Chats
    
    func loadChats(limit: Int = 100) {
        print("📱 Loading chats...")
        
        // TODO: TDLib call
        // td_send(clientId, GetChats(chat_list: nil, limit: limit))
    }
    
    func selectChat(_ chat: TGChat) {
        selectedChat = chat
        Config.targetChatId = chat.id
        loadMessages(chatId: chat.id)
    }
    
    func searchChat(username: String) {
        print("📱 Searching for @\(username)")
        
        // TODO: TDLib call
        // td_send(clientId, SearchPublicChat(username: username))
    }
    
    // MARK: - Messages
    
    func loadMessages(chatId: Int64, limit: Int = 50) {
        print("📱 Loading messages for chat \(chatId)")
        
        // TODO: TDLib call
        // td_send(clientId, GetChatHistory(chat_id: chatId, from_message_id: 0, limit: limit))
    }
    
    func sendVoiceMessage(audioURL: URL, duration: Int, waveform: Data?) {
        guard let chat = selectedChat else {
            print("❌ No chat selected")
            error = TGError(code: -1, message: "No chat selected")
            return
        }
        
        print("📤 Sending voice message to chat \(chat.id)")
        print("   Duration: \(duration)s")
        print("   File: \(audioURL.lastPathComponent)")
        
        // Create optimistic local message
        let localMessage = TGMessage(
            id: Int64.random(in: 1...Int64.max),
            chatId: chat.id,
            senderId: currentUser?.id ?? 0,
            content: .voice(TGVoiceNote(
                duration: duration,
                waveform: waveform,
                localPath: audioURL.path,
                remoteId: nil
            )),
            date: Date(),
            isOutgoing: true,
            sendingState: .pending
        )
        
        messages.append(localMessage)
        
        // TODO: TDLib call
        // let inputFile = InputFileLocal(path: audioURL.path)
        // let voiceNote = InputMessageVoiceNote(
        //     voice_note: inputFile,
        //     duration: duration,
        //     waveform: waveform?.base64EncodedString()
        // )
        // td_send(clientId, SendMessage(chat_id: chat.id, input_message_content: voiceNote))
        
        // For demo, simulate success
        #if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if let index = self?.messages.firstIndex(where: { $0.id == localMessage.id }) {
                self?.messages[index].sendingState = .sent
            }
            
            // Simulate response after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self?.simulateIncomingVoice(chatId: chat.id)
            }
        }
        #endif
    }
    
    #if DEBUG
    private func simulateIncomingVoice(chatId: Int64) {
        let response = TGMessage(
            id: Int64.random(in: 1...Int64.max),
            chatId: chatId,
            senderId: chatId,
            content: .voice(TGVoiceNote(
                duration: 5,
                waveform: nil,
                localPath: nil,
                remoteId: "demo_voice_123"
            )),
            date: Date(),
            isOutgoing: false,
            sendingState: .sent
        )
        
        messages.append(response)
        NotificationCenter.default.post(name: .newVoiceMessage, object: response)
    }
    #endif
    
    func downloadVoice(_ voiceNote: TGVoiceNote, completion: @escaping (URL?) -> Void) {
        guard let remoteId = voiceNote.remoteId else {
            completion(nil)
            return
        }
        
        print("📥 Downloading voice: \(remoteId)")
        
        // TODO: TDLib call
        // td_send(clientId, DownloadFile(file_id: remoteId, priority: 32))
        
        // For demo
        #if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Return a demo audio file path
            completion(nil)
        }
        #endif
    }
    
    // MARK: - Update Handler
    
    private func handleUpdate(_ update: TGUpdate) {
        switch update {
        case .authorizationState(let state):
            handleAuthorizationState(state)
            
        case .connectionState(let state):
            handleConnectionState(state)
            
        case .newMessage(let message):
            handleNewMessage(message)
            
        case .messageContent(let messageId, let chatId, let content):
            handleMessageContentUpdate(messageId: messageId, chatId: chatId, content: content)
            
        case .file(let file):
            handleFileUpdate(file)
            
        case .newChat(let chat):
            if !chats.contains(where: { $0.id == chat.id }) {
                chats.append(chat)
            }
        }
    }
    
    private func handleAuthorizationState(_ state: AuthState) {
        authState = state
        
        switch state {
        case .ready:
            isAuthenticated = true
            loadChats()
            
        case .closed:
            isAuthenticated = false
            
        default:
            break
        }
    }
    
    private func handleConnectionState(_ state: ConnectionState) {
        connectionState = state
    }
    
    private func handleNewMessage(_ message: TGMessage) {
        if message.chatId == selectedChat?.id {
            if !messages.contains(where: { $0.id == message.id }) {
                messages.append(message)
            }
            
            // Notify for auto-play if it's an incoming voice message
            if !message.isOutgoing, case .voice = message.content {
                NotificationCenter.default.post(name: .newVoiceMessage, object: message)
            }
        }
    }
    
    private func handleMessageContentUpdate(messageId: Int64, chatId: Int64, content: TGMessageContent) {
        if let index = messages.firstIndex(where: { $0.id == messageId && $0.chatId == chatId }) {
            messages[index].content = content
        }
    }
    
    private func handleFileUpdate(_ file: TGFile) {
        // Update file download progress
        print("📁 File update: \(file.id), downloaded: \(file.isDownloaded)")
    }
}

// MARK: - Models

struct TGUser: Identifiable, Equatable {
    let id: Int64
    let firstName: String
    let lastName: String?
    let username: String?
    
    var displayName: String {
        if let lastName = lastName {
            return "\(firstName) \(lastName)"
        }
        return firstName
    }
}

struct TGChat: Identifiable, Equatable {
    let id: Int64
    let title: String
    let username: String?
    let type: ChatType
    var unreadCount: Int
    var lastMessage: TGMessage?
    
    enum ChatType {
        case `private`
        case group
        case supergroup
        case channel
    }
}

struct TGMessage: Identifiable, Equatable {
    let id: Int64
    let chatId: Int64
    let senderId: Int64
    var content: TGMessageContent
    let date: Date
    let isOutgoing: Bool
    var sendingState: SendingState
    
    enum SendingState {
        case pending
        case sent
        case failed
    }
}

enum TGMessageContent: Equatable {
    case text(String)
    case voice(TGVoiceNote)
    case photo(TGPhoto)
    case other
}

struct TGVoiceNote: Equatable {
    let duration: Int
    let waveform: Data?
    var localPath: String?
    var remoteId: String?
}

struct TGPhoto: Equatable {
    let id: String
    var localPath: String?
}

struct TGFile: Identifiable {
    let id: Int32
    var localPath: String?
    var isDownloaded: Bool
    var downloadedSize: Int
    var expectedSize: Int
}

struct TGError: Error, Identifiable {
    let id = UUID()
    let code: Int
    let message: String
}

enum TGUpdate {
    case authorizationState(TelegramService.AuthState)
    case connectionState(TelegramService.ConnectionState)
    case newMessage(TGMessage)
    case messageContent(messageId: Int64, chatId: Int64, content: TGMessageContent)
    case file(TGFile)
    case newChat(TGChat)
}

// MARK: - Notifications

extension Notification.Name {
    static let newVoiceMessage = Notification.Name("newVoiceMessage")
    static let voiceDownloaded = Notification.Name("voiceDownloaded")
}

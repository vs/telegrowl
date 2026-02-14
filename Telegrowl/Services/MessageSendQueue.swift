import Foundation
import Combine
import TDLibKit

// MARK: - Queue Item

struct QueueItem: Codable, Identifiable {
    let id: UUID
    let chatId: Int64
    let audioFileName: String       // filename within send_queue/ dir
    let duration: Int
    let waveformBase64: String?     // Data as base64 for JSON persistence
    let enqueuedAt: Double          // timeIntervalSince1970
    var localMessageId: Int64?      // TDLib temp ID (set after sendMessage returns)
    var retryCount: Int = 0
    var lastError: String?
    var state: ItemState = .pending

    enum ItemState: String, Codable {
        case pending           // Ready to send
        case sending           // sendVoiceMessage in flight
        case awaitingConfirm   // TDLib accepted, waiting for success/failure update
        case retryWait         // Backoff timer active
    }

    var waveform: Data? {
        guard let base64 = waveformBase64 else { return nil }
        return Data(base64Encoded: base64)
    }

    var audioURL: URL {
        MessageSendQueue.queueDirectory.appendingPathComponent(audioFileName)
    }
}

// MARK: - Message Send Queue

@MainActor
class MessageSendQueue: ObservableObject {
    static let shared = MessageSendQueue()

    static let queueDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("send_queue", isDirectory: true)
    }()

    private static let queueFile: URL = {
        queueDirectory.appendingPathComponent("queue.json")
    }()

    // MARK: - Published State

    @Published var items: [QueueItem] = []
    @Published var isProcessing: Bool = false

    var pendingCount: Int {
        items.count
    }

    // MARK: - Private

    private var retryTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        observeNotifications()
        observeConnection()
    }

    // MARK: - Enqueue

    func enqueue(audioURL: URL, duration: Int, waveform: Data?, chatId: Int64) {
        ensureDirectory()

        // Move audio file into send_queue/ directory
        let fileName = "\(UUID().uuidString).\(audioURL.pathExtension)"
        let destination = Self.queueDirectory.appendingPathComponent(fileName)

        do {
            try FileManager.default.moveItem(at: audioURL, to: destination)
        } catch {
            print("❌ SendQueue: failed to move audio to queue dir: \(error)")
            // Try copy as fallback (e.g. cross-volume)
            do {
                try FileManager.default.copyItem(at: audioURL, to: destination)
                try? FileManager.default.removeItem(at: audioURL)
            } catch {
                print("❌ SendQueue: failed to copy audio: \(error)")
                return
            }
        }

        let item = QueueItem(
            id: UUID(),
            chatId: chatId,
            audioFileName: fileName,
            duration: duration,
            waveformBase64: waveform?.base64EncodedString(),
            enqueuedAt: Foundation.Date().timeIntervalSince1970
        )

        items.append(item)
        persist()
        print("📤 SendQueue: enqueued \(fileName) for chat \(chatId) (\(items.count) in queue)")
        processNext()
    }

    // MARK: - Processing

    func processNext() {
        // Don't start if already sending one
        guard !items.contains(where: { $0.state == .sending }) else { return }

        // Find first pending item
        guard let index = items.firstIndex(where: { $0.state == .pending }) else {
            isProcessing = false
            return
        }

        // Check connection
        guard case .connectionStateReady = TelegramService.shared.connectionState else {
            print("📤 SendQueue: waiting for connection...")
            return
        }

        isProcessing = true
        items[index].state = .sending
        persist()

        let item = items[index]
        print("📤 SendQueue: sending \(item.audioFileName) (attempt \(item.retryCount + 1))")

        Task {
            do {
                let messageId = try await TelegramService.shared.sendVoiceMessage(
                    audioURL: item.audioURL,
                    duration: item.duration,
                    waveform: item.waveform,
                    chatId: item.chatId
                )

                // Store the local message ID for matching send success/failure updates
                if let idx = items.firstIndex(where: { $0.id == item.id }) {
                    items[idx].localMessageId = messageId
                    items[idx].state = .awaitingConfirm
                    persist()
                    print("📤 SendQueue: awaiting confirm for localId=\(messageId)")
                }
            } catch {
                print("❌ SendQueue: sendVoiceMessage threw: \(error)")
                handleSendError(itemId: item.id, error: error.localizedDescription)
            }
        }
    }

    // MARK: - TDLib Update Handlers

    private func handleSendSucceeded(oldMessageId: Int64) {
        guard let index = items.firstIndex(where: { $0.localMessageId == oldMessageId }) else {
            return
        }

        let item = items[index]
        print("📤 SendQueue: send succeeded for \(item.audioFileName)")

        // Delete audio file from queue directory
        try? FileManager.default.removeItem(at: item.audioURL)

        items.remove(at: index)
        persist()

        NotificationCenter.default.post(name: .queueSendSucceeded, object: nil)

        // Process next in queue
        processNext()
    }

    private func handleSendFailed(oldMessageId: Int64, message: Any?, errorMessage: String) {
        guard let index = items.firstIndex(where: { $0.localMessageId == oldMessageId }) else {
            return
        }

        let item = items[index]
        print("❌ SendQueue: send failed for \(item.audioFileName): \(errorMessage)")

        // Try to extract canRetry/retryAfter from the TDLib message sending state
        var canRetry = false
        var retryAfter: Double = 0

        if let msg = message as? Message,
           case .messageSendingStateFailed(let failedState) = msg.sendingState {
            canRetry = failedState.canRetry
            retryAfter = failedState.retryAfter
        }

        if canRetry {
            // Use TDLib's resendMessages after the required delay
            let chatId = item.chatId
            let msgId = oldMessageId
            let itemId = item.id

            items[index].state = .retryWait
            persist()

            let delay = max(retryAfter, 1.0)
            print("📤 SendQueue: TDLib says canRetry, waiting \(delay)s then resending...")

            Task {
                try? await Task.sleep(for: .seconds(delay))

                do {
                    let result = try await TelegramService.shared.api?.resendMessages(
                        chatId: chatId,
                        messageIds: [msgId],
                        paidMessageStarCount: nil,
                        quote: nil
                    )

                    // Update with new message ID
                    if let newMsg = result?.messages?.first,
                       let idx = items.firstIndex(where: { $0.id == itemId }) {
                        items[idx].localMessageId = newMsg.id
                        items[idx].state = .awaitingConfirm
                        persist()
                        print("📤 SendQueue: resendMessages succeeded, new localId=\(newMsg.id)")
                    }
                } catch {
                    print("❌ SendQueue: resendMessages failed: \(error), falling back to fresh send")
                    fallbackRetry(itemId: itemId, errorMessage: errorMessage)
                }
            }
        } else {
            // Can't use TDLib resend — retry from scratch
            fallbackRetry(itemId: item.id, errorMessage: errorMessage)
        }
    }

    private func fallbackRetry(itemId: UUID, errorMessage: String) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }

        items[index].retryCount += 1
        items[index].localMessageId = nil
        items[index].lastError = errorMessage
        items[index].state = .retryWait
        persist()

        let retryCount = items[index].retryCount
        let delay = min(pow(2.0, Double(retryCount)) * 2.0, 60.0)
        print("📤 SendQueue: scheduling retry #\(retryCount) in \(delay)s")

        retryTask?.cancel()
        retryTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }

            if let idx = items.firstIndex(where: { $0.id == itemId && $0.state == .retryWait }) {
                items[idx].state = .pending
                persist()
                processNext()
            }
        }
    }

    private func handleSendError(itemId: UUID, error: String) {
        fallbackRetry(itemId: itemId, errorMessage: error)
    }

    // MARK: - Notifications

    private func observeNotifications() {
        NotificationCenter.default.publisher(for: .messageSendSucceeded)
            .sink { [weak self] notification in
                Task { @MainActor [weak self] in
                    if let oldId = notification.userInfo?["oldMessageId"] as? Int64 {
                        self?.handleSendSucceeded(oldMessageId: oldId)
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .messageSendFailed)
            .sink { [weak self] notification in
                Task { @MainActor [weak self] in
                    if let oldId = notification.userInfo?["oldMessageId"] as? Int64 {
                        let errorMsg = notification.userInfo?["errorMessage"] as? String ?? "Unknown error"
                        self?.handleSendFailed(oldMessageId: oldId, message: notification.object, errorMessage: errorMsg)
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Connection Awareness

    private func observeConnection() {
        TelegramService.shared.$connectionState
            .removeDuplicates(by: { old, new in
                if case .connectionStateReady = old, case .connectionStateReady = new { return true }
                return false
            })
            .sink { [weak self] state in
                Task { @MainActor [weak self] in
                    if case .connectionStateReady = state {
                        print("📤 SendQueue: connection ready, processing queue...")
                        self?.processNext()
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Persistence

    func persist() {
        ensureDirectory()

        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: Self.queueFile, options: .atomic)
        } catch {
            print("❌ SendQueue: persist failed: \(error)")
        }
    }

    func load() {
        guard FileManager.default.fileExists(atPath: Self.queueFile.path) else {
            print("📤 SendQueue: no persisted queue found")
            return
        }

        do {
            let data = try Data(contentsOf: Self.queueFile)
            var loadedItems = try JSONDecoder().decode([QueueItem].self, from: data)

            // Crash recovery: reset in-flight items to pending
            for i in loadedItems.indices {
                switch loadedItems[i].state {
                case .sending, .awaitingConfirm, .retryWait:
                    loadedItems[i].state = .pending
                    loadedItems[i].localMessageId = nil
                case .pending:
                    break
                }
            }

            // Remove items whose audio files no longer exist
            loadedItems = loadedItems.filter { item in
                let exists = FileManager.default.fileExists(atPath: item.audioURL.path)
                if !exists {
                    print("⚠️ SendQueue: audio file missing for \(item.audioFileName), dropping")
                }
                return exists
            }

            items = loadedItems
            persist()

            if !items.isEmpty {
                print("📤 SendQueue: loaded \(items.count) persisted items")
                processNext()
            }
        } catch {
            print("❌ SendQueue: load failed: \(error)")
        }
    }

    private func ensureDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.queueDirectory.path) {
            try? fm.createDirectory(at: Self.queueDirectory, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Notifications

extension Foundation.Notification.Name {
    static let messageSendSucceeded = Foundation.Notification.Name("messageSendSucceeded")
    static let queueSendSucceeded = Foundation.Notification.Name("queueSendSucceeded")
}

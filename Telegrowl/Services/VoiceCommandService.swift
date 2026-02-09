import Foundation
import AVFoundation
import Speech
import Combine
import TDLibKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Voice Command State

enum VoiceCommandState: Equatable {
    case idle
    case listening
    case paused
    case announcing
    case awaitingResponse
    case transitioning
}

// MARK: - Announcement

struct Announcement: Equatable {
    let chatId: Int64
    let chatTitle: String
    let message: Message

    static func == (lhs: Announcement, rhs: Announcement) -> Bool {
        lhs.chatId == rhs.chatId && lhs.message.id == rhs.message.id
    }
}

// MARK: - Voice Command Action

enum VoiceCommandAction {
    case openChat(chatId: Int64, chatTitle: String)
    case switchChat(chatId: Int64, chatTitle: String)
    case closeChat
    case playMessage(message: Message, chatTitle: String)
    case exitApp
}

// MARK: - Voice Command Service

/// Global voice command service — singleton, runs from app launch.
/// Listens for voice commands on the contacts view via AVAudioEngine + SFSpeechRecognizer.
/// Uses AVSpeechSynthesizer for announcements.
@MainActor
class VoiceCommandService: NSObject, ObservableObject {
    static let shared = VoiceCommandService()

    // MARK: - Published State

    @Published var state: VoiceCommandState = .idle
    @Published var audioLevel: Float = -160.0

    // MARK: - Action Callback

    /// ContentView sets this to handle navigation actions from voice commands.
    var onAction: ((VoiceCommandAction) -> Void)?

    // MARK: - Private Properties

    private let audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private nonisolated(unsafe) var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRestartTimer: Timer?

    private let synthesizer = AVSpeechSynthesizer()

    private var announcementQueue: [Announcement] = []
    private var currentAnnouncement: Announcement?
    private var announcementWindowTimer: Timer?

    private var messageCancellable: AnyCancellable?
    private var interruptionCancellable: AnyCancellable?
    private var foregroundCancellable: AnyCancellable?
    private var backgroundCancellable: AnyCancellable?

    // Silence-bounded command detection
    private var isSpeaking = false
    private var silenceStart: Foundation.Date = .distantPast
    private var speechStart: Foundation.Date?
    private var lastTranscription: String = ""
    private var transcriptionAtSpeechStart: String = ""

    // Track whether we were listening before backgrounding
    private var wasListeningBeforeBackground = false

    // Prevents error-handler restarts during TTS
    private var isSpeakingTTS = false

    // MARK: - Initialization

    private override init() {
        super.init()
        synthesizer.delegate = self
        observeAppLifecycle()
    }

    // MARK: - Public Methods

    func start() {
        guard Config.voiceControlEnabled else {
            print("🎤 VoiceCommand: voice control disabled in settings")
            return
        }
        guard state == .idle || state == .paused else {
            print("🎤 VoiceCommand: already running (state=\(state))")
            return
        }

        print("🎤 VoiceCommand: starting")
        setupAudioSession()
        startEngine()
        startSpeechRecognition()
        observeIncomingMessages()
        observeAudioInterruptions()
        state = .listening
    }

    func stop() {
        print("🎤 VoiceCommand: stopping")
        stopEngine()
        stopSpeechRecognition()
        synthesizer.stopSpeaking(at: .immediate)
        messageCancellable?.cancel()
        messageCancellable = nil
        interruptionCancellable?.cancel()
        interruptionCancellable = nil
        announcementWindowTimer?.invalidate()
        announcementWindowTimer = nil
        announcementQueue.removeAll()
        currentAnnouncement = nil
        state = .idle
    }

    func pause() {
        guard state == .listening || state == .awaitingResponse else { return }
        print("🎤 VoiceCommand: paused")
        stopEngine()
        stopSpeechRecognition()
        announcementWindowTimer?.invalidate()
        announcementWindowTimer = nil
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        print("🎤 VoiceCommand: resuming")
        setupAudioSession()
        startEngine()
        startSpeechRecognition()
        state = .listening
    }

    /// Call this when VoiceChatService finishes (user said "close" or navigated back).
    func onChatClosed() {
        guard state == .idle || state == .transitioning else { return }
        print("🎤 VoiceCommand: chat closed, restarting")
        start()
    }

    /// Call this before entering a chat — stops the command service.
    func onChatOpening() {
        print("🎤 VoiceCommand: chat opening, stopping for handoff")
        state = .transitioning
        stop()
    }

    // MARK: - Audio Session

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true)
        } catch {
            print("❌ VoiceCommand: audio session setup failed: \(error)")
        }
    }

    // MARK: - Audio Engine

    private func startEngine() {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        do {
            try audioEngine.start()
            print("🎤 VoiceCommand: engine started")
        } catch {
            print("❌ VoiceCommand: engine start failed: \(error)")
        }
    }

    private func stopEngine() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    // MARK: - Buffer Processing & Silence Detection

    private nonisolated func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Feed speech recognizer
        recognitionRequest?.append(buffer)

        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var sumOfSquares: Float = 0
        for i in 0..<frameCount {
            let sample = channelData[i]
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(frameCount))
        let db = rms > 0 ? 20 * log10(rms) : -160.0

        let threshold = Config.vadThreshold
        let isVoice = db > threshold

        Task { @MainActor [weak self] in
            self?.audioLevel = db
            self?.handleSilenceDetection(isVoice: isVoice)
        }
    }

    private func handleSilenceDetection(isVoice: Bool) {
        let now = Foundation.Date()

        if isVoice {
            if !isSpeaking {
                // Transition: silent -> speaking
                isSpeaking = true
                speechStart = now
                // Capture current transcription at speech start
                transcriptionAtSpeechStart = lastTranscription
            }
            // Reset silence timer while speaking
            silenceStart = now
        } else {
            if isSpeaking {
                let silenceDuration = now.timeIntervalSince(silenceStart)
                if silenceDuration >= Config.commandSilenceGap {
                    // Transition: speaking -> silent (with sufficient gap)
                    isSpeaking = false
                    evaluateCommandCandidate()
                    speechStart = nil
                }
            } else {
                silenceStart = now
            }
        }
    }

    private func evaluateCommandCandidate() {
        // Get the text spoken since speech started
        let fullText = lastTranscription.lowercased()
        let baseText = transcriptionAtSpeechStart.lowercased()

        // Extract just the new words spoken in this segment
        var commandText = fullText
        if !baseText.isEmpty && fullText.hasPrefix(baseText) {
            commandText = String(fullText.dropFirst(baseText.count)).trimmingCharacters(in: .whitespaces)
        }

        guard !commandText.isEmpty else { return }
        print("🎤 VoiceCommand: command candidate: \"\(commandText)\"")

        matchCommand(commandText)
    }

    // MARK: - Command Matching

    private func matchCommand(_ text: String) {
        let text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Resume command works even when paused
        if text.hasSuffix(Config.resumeCommand.lowercased()) {
            if state == .paused {
                resume()
            }
            return
        }

        // All other commands require listening or awaitingResponse
        guard state == .listening || state == .awaitingResponse else { return }

        // Pause
        if text.hasSuffix(Config.pauseCommand.lowercased()) {
            pause()
            return
        }

        // Exit
        if text.hasSuffix(Config.exitCommand.lowercased()) {
            print("🎤 VoiceCommand: exit command")
            onAction?(.exitApp)
            return
        }

        // Chat with {name}
        let chatPrefix = Config.chatWithPrefix.lowercased()
        if let range = text.range(of: chatPrefix, options: .caseInsensitive) {
            let nameQuery = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !nameQuery.isEmpty {
                handleChatWithCommand(nameQuery: nameQuery)
                return
            }
        }

        // Commands only active during announcement window
        if state == .awaitingResponse, let announcement = currentAnnouncement {
            // Play
            if text.hasSuffix(Config.playCommand.lowercased()) {
                print("🎤 VoiceCommand: play command for \(announcement.chatTitle)")
                announcementWindowTimer?.invalidate()
                announcementWindowTimer = nil
                onAction?(.playMessage(message: announcement.message, chatTitle: announcement.chatTitle))
                currentAnnouncement = nil
                processNextAnnouncement()
                return
            }

            // Chat (enter chat with announced contact)
            if text.hasSuffix(Config.chatCommand.lowercased()) {
                print("🎤 VoiceCommand: chat command for \(announcement.chatTitle)")
                announcementWindowTimer?.invalidate()
                announcementWindowTimer = nil
                currentAnnouncement = nil
                announceAndOpenChat(chatId: announcement.chatId, chatTitle: announcement.chatTitle)
                return
            }
        }
    }

    // MARK: - Chat With Command

    private func handleChatWithCommand(nameQuery: String) {
        let chats = TelegramService.shared.chats
        let aliases = Config.voiceAliases

        // 1. Check aliases first (exact match, case-insensitive)
        for (chatId, alias) in aliases {
            if alias.lowercased() == nameQuery.lowercased() {
                if let chat = chats.first(where: { $0.id == chatId }) {
                    announceAndOpenChat(chatId: chat.id, chatTitle: chat.title)
                    return
                }
            }
        }

        // 2. Check chat titles (substring match, case-insensitive)
        for chat in chats {
            if chat.title.lowercased().contains(nameQuery.lowercased()) {
                announceAndOpenChat(chatId: chat.id, chatTitle: chat.title)
                return
            }
        }

        // No match
        print("🎤 VoiceCommand: contact not found for \"\(nameQuery)\"")
        speak("Contact not found")
    }

    private func announceAndOpenChat(chatId: Int64, chatTitle: String) {
        state = .transitioning
        announcementWindowTimer?.invalidate()
        announcementWindowTimer = nil
        announcementQueue.removeAll()
        currentAnnouncement = nil

        speak("Starting chat with \(chatTitle)") { [weak self] in
            self?.onAction?(.openChat(chatId: chatId, chatTitle: chatTitle))
        }
    }

    // MARK: - Incoming Message Announcements

    private func observeIncomingMessages() {
        messageCancellable = NotificationCenter.default
            .publisher(for: .newIncomingMessage)
            .sink { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleIncomingMessage(notification)
                }
            }
    }

    private func handleIncomingMessage(_ notification: Foundation.Notification) {
        guard let message = notification.object as? Message,
              !message.isOutgoing else { return }

        // Only queue announcements when we're on the contacts view
        guard state == .listening || state == .awaitingResponse || state == .announcing else { return }

        let chatId = message.chatId
        guard let chat = TelegramService.shared.chats.first(where: { $0.id == chatId }) else { return }

        let displayName = Config.voiceAlias(for: chatId) ?? chat.title
        let announcement = Announcement(chatId: chatId, chatTitle: displayName, message: message)

        // Deduplicate: replace existing announcement for same chatId
        announcementQueue.removeAll { $0.chatId == chatId }
        announcementQueue.append(announcement)

        print("🎤 VoiceCommand: queued announcement for \(displayName) (\(announcementQueue.count) in queue)")

        // If we're just listening, start processing
        if state == .listening {
            processNextAnnouncement()
        }
    }

    private func processNextAnnouncement() {
        guard !announcementQueue.isEmpty else {
            if state != .paused && state != .transitioning && state != .idle {
                state = .listening
            }
            return
        }

        let announcement = announcementQueue.removeFirst()
        currentAnnouncement = announcement
        state = .announcing

        let displayName = announcement.chatTitle
        speak("Message from \(displayName)") { [weak self] in
            self?.startAnnouncementWindow()
        }
    }

    private func startAnnouncementWindow() {
        state = .awaitingResponse
        print("🎤 VoiceCommand: announcement window open (\(Config.announcementWindow)s)")

        announcementWindowTimer = Timer.scheduledTimer(withTimeInterval: Config.announcementWindow, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .awaitingResponse else { return }
                print("🎤 VoiceCommand: announcement window expired")
                self.currentAnnouncement = nil
                self.processNextAnnouncement()
            }
        }
    }

    // MARK: - TTS

    private var ttsCompletion: (() -> Void)?

    private func speak(_ text: String, completion: (() -> Void)? = nil) {
        // Stop listening while speaking to avoid mic feedback
        isSpeakingTTS = true
        stopEngine()
        stopSpeechRecognition()

        ttsCompletion = completion

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Config.speechLocale)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        print("🗣️ VoiceCommand: speaking: \"\(text)\"")
        synthesizer.speak(utterance)
    }

    private func onTTSFinished() {
        isSpeakingTTS = false
        let completion = ttsCompletion
        ttsCompletion = nil

        // Resume listening after TTS — reset silence detection state
        if state != .idle && state != .transitioning {
            isSpeaking = false
            silenceStart = Foundation.Date()
            speechStart = nil
            setupAudioSession()
            startEngine()
            startSpeechRecognition()
        }

        completion?()
    }

    // MARK: - Speech Recognition

    private func startSpeechRecognition() {
        // Reset transcription state for fresh session
        lastTranscription = ""
        transcriptionAtSpeechStart = ""

        let locale = Locale(identifier: Config.speechLocale)
        speechRecognizer = SFSpeechRecognizer(locale: locale)
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            print("⚠️ VoiceCommand: speech recognition not available for locale \(Config.speechLocale)")
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = true

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.lastTranscription = text
                }
            }

            if let error {
                print("⚠️ VoiceCommand: speech recognition error: \(error)")
                Task { @MainActor in
                    // Don't restart during TTS — onTTSFinished will handle it
                    guard !self.isSpeakingTTS else { return }
                    self.restartSpeechRecognition()
                }
            }
        }

        // Rolling restart every 50s
        recognitionRestartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.restartSpeechRecognition()
            }
        }

        print("🗣️ VoiceCommand: speech recognition started (locale=\(Config.speechLocale))")
    }

    private func stopSpeechRecognition() {
        recognitionRestartTimer?.invalidate()
        recognitionRestartTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        speechRecognizer = nil
    }

    private func restartSpeechRecognition() {
        stopSpeechRecognition()
        if state == .listening || state == .awaitingResponse || state == .paused {
            startSpeechRecognition()
        }
    }

    // MARK: - Audio Interruptions

    private func observeAudioInterruptions() {
        interruptionCancellable = NotificationCenter.default
            .publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let info = notification.userInfo,
                          let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

                    switch type {
                    case .began:
                        print("🎤 VoiceCommand: audio interruption began")
                        if self.state == .listening || self.state == .awaitingResponse {
                            self.stopEngine()
                            self.stopSpeechRecognition()
                            self.state = .paused
                        }

                    case .ended:
                        print("🎤 VoiceCommand: audio interruption ended")

                    @unknown default:
                        break
                    }
                }
            }
    }

    // MARK: - App Lifecycle

    private func observeAppLifecycle() {
        #if canImport(UIKit)
        foregroundCancellable = NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.wasListeningBeforeBackground {
                        self.wasListeningBeforeBackground = false
                        self.start()
                    }
                }
            }

        backgroundCancellable = NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.state == .listening || self.state == .awaitingResponse {
                        self.wasListeningBeforeBackground = true
                        self.stop()
                    }
                }
            }
        #endif
    }

    // MARK: - Permissions

    static func requestPermissions() async -> Bool {
        let micGranted = await AVAudioApplication.requestRecordPermission()

        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        return micGranted && speechGranted
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension VoiceCommandService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.onTTSFinished()
        }
    }
}

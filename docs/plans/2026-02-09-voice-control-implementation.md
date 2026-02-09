# Voice Control Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Telegrowl fully voice-controlled from launch with a global VoiceCommandService that listens for commands on the contacts view, and enhanced VoiceChatService that handles commands in the chat view.

**Architecture:** New `VoiceCommandService` singleton owns mic + speech recognition on the contacts screen. Clean handoff to per-session `VoiceChatService` when entering a chat. `Config` expanded with all command words + locale. `TelegramService` extended with a new `.newTextMessage` notification. `ContentView` orchestrates programmatic navigation from voice commands.

**Tech Stack:** Swift/SwiftUI, AVFoundation (AVAudioEngine, AVSpeechSynthesizer), Speech framework (SFSpeechRecognizer), TDLibKit, UserDefaults

---

### Task 1: Add New Config Properties

**Files:**
- Modify: `Telegrowl/App/Config.swift.template` (lines 30-43 Keys enum, lines 49-61 registerDefaults, add new computed properties)

**Step 1: Add new UserDefaults keys to the Keys enum**

Add these keys inside `private enum Keys` after the existing `minRecordingDuration` key:

```swift
static let voiceControlEnabled = "voiceControlEnabled"
static let speechLocale = "speechLocale"
static let exitCommand = "exitCommand"
static let chatWithPrefix = "chatWithPrefix"
static let playCommand = "playCommand"
static let chatCommand = "chatCommand"
static let closeCommand = "closeCommand"
static let pauseCommand = "pauseCommand"
static let resumeCommand = "resumeCommand"
static let readTextMessages = "readTextMessages"
static let announceCrossChat = "announceCrossChat"
static let commandSilenceGap = "commandSilenceGap"
static let announcementWindow = "announcementWindow"
static let voiceAliases = "voiceAliases"
```

**Step 2: Register defaults for new keys**

Add to the `registerDefaults()` dictionary:

```swift
Keys.voiceControlEnabled: true,
Keys.speechLocale: "en-US",
Keys.exitCommand: "exit",
Keys.chatWithPrefix: "chat with",
Keys.playCommand: "play",
Keys.chatCommand: "chat",
Keys.closeCommand: "close",
Keys.pauseCommand: "stop listening",
Keys.resumeCommand: "start listening",
Keys.readTextMessages: true,
Keys.announceCrossChat: true,
Keys.commandSilenceGap: 0.75,
Keys.announcementWindow: 5.0,
```

**Step 3: Add computed properties after `minRecordingDuration`**

```swift
// MARK: - Voice Control Settings (Persistent)

static var voiceControlEnabled: Bool {
    get { defaults.bool(forKey: Keys.voiceControlEnabled) }
    set { defaults.set(newValue, forKey: Keys.voiceControlEnabled) }
}

static var speechLocale: String {
    get { defaults.string(forKey: Keys.speechLocale) ?? "en-US" }
    set { defaults.set(newValue, forKey: Keys.speechLocale) }
}

static var exitCommand: String {
    get { defaults.string(forKey: Keys.exitCommand) ?? "exit" }
    set { defaults.set(newValue, forKey: Keys.exitCommand) }
}

static var chatWithPrefix: String {
    get { defaults.string(forKey: Keys.chatWithPrefix) ?? "chat with" }
    set { defaults.set(newValue, forKey: Keys.chatWithPrefix) }
}

static var playCommand: String {
    get { defaults.string(forKey: Keys.playCommand) ?? "play" }
    set { defaults.set(newValue, forKey: Keys.playCommand) }
}

static var chatCommand: String {
    get { defaults.string(forKey: Keys.chatCommand) ?? "chat" }
    set { defaults.set(newValue, forKey: Keys.chatCommand) }
}

static var closeCommand: String {
    get { defaults.string(forKey: Keys.closeCommand) ?? "close" }
    set { defaults.set(newValue, forKey: Keys.closeCommand) }
}

static var pauseCommand: String {
    get { defaults.string(forKey: Keys.pauseCommand) ?? "stop listening" }
    set { defaults.set(newValue, forKey: Keys.pauseCommand) }
}

static var resumeCommand: String {
    get { defaults.string(forKey: Keys.resumeCommand) ?? "start listening" }
    set { defaults.set(newValue, forKey: Keys.resumeCommand) }
}

static var readTextMessages: Bool {
    get { defaults.bool(forKey: Keys.readTextMessages) }
    set { defaults.set(newValue, forKey: Keys.readTextMessages) }
}

static var announceCrossChat: Bool {
    get { defaults.bool(forKey: Keys.announceCrossChat) }
    set { defaults.set(newValue, forKey: Keys.announceCrossChat) }
}

static var commandSilenceGap: Double {
    get { defaults.double(forKey: Keys.commandSilenceGap) }
    set { defaults.set(newValue, forKey: Keys.commandSilenceGap) }
}

static var announcementWindow: Double {
    get { defaults.double(forKey: Keys.announcementWindow) }
    set { defaults.set(newValue, forKey: Keys.announcementWindow) }
}

// MARK: - Voice Aliases

static var voiceAliases: [Int64: String] {
    get {
        guard let dict = defaults.dictionary(forKey: Keys.voiceAliases) as? [String: String] else { return [:] }
        var result: [Int64: String] = [:]
        for (key, value) in dict {
            if let id = Int64(key) {
                result[id] = value
            }
        }
        return result
    }
    set {
        let dict = Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value) })
        defaults.set(dict, forKey: Keys.voiceAliases)
    }
}

static func setVoiceAlias(chatId: Int64, alias: String) {
    var aliases = voiceAliases
    aliases[chatId] = alias
    voiceAliases = aliases
}

static func removeVoiceAlias(chatId: Int64) {
    var aliases = voiceAliases
    aliases.removeValue(forKey: chatId)
    voiceAliases = aliases
}

/// Returns the voice alias for a chat, or nil if none set.
static func voiceAlias(for chatId: Int64) -> String? {
    voiceAliases[chatId]
}
```

**Step 4: Verify it compiles**

Run: `cd /Users/vs/workspace/telegrowl && xcodebuild -scheme Telegrowl -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add Telegrowl/App/Config.swift.template
# Also add Config.swift if it exists and was modified
git commit -m "feat: add voice control config properties and voice aliases"
```

---

### Task 2: Extend TelegramService with New Notifications

**Files:**
- Modify: `Telegrowl/Services/TelegramService.swift`

The current `handleNewMessage` only posts `.newVoiceMessage` for incoming voice notes. We need:
1. A `.newTextMessage` notification for incoming text messages
2. A general `.newIncomingMessage` notification for any incoming message (used by VoiceCommandService)
3. Make `handleNewMessage` also fire for messages in non-selected chats (currently filtered to `selectedChat` only)

**Step 1: Add new notification names**

In the `extension Foundation.Notification.Name` at the bottom of the file (around line 530), add:

```swift
static let newIncomingMessage = Foundation.Notification.Name("newIncomingMessage")
```

**Step 2: Modify `handleNewMessage` to notify about all incoming messages**

Replace the current `handleNewMessage` method (around line 420) with:

```swift
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
```

**Step 3: Verify it compiles**

Run: `cd /Users/vs/workspace/telegrowl && xcodebuild -scheme Telegrowl -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Telegrowl/Services/TelegramService.swift
git commit -m "feat: add newIncomingMessage notification for all incoming messages"
```

---

### Task 3: Create VoiceCommandService — Core Engine

**Files:**
- Create: `Telegrowl/Services/VoiceCommandService.swift`

This is the largest task. Create the full VoiceCommandService with:
- AVAudioEngine + SFSpeechRecognizer for command listening
- Silence-bounded command detection (0.75s gaps)
- AVSpeechSynthesizer for TTS announcements
- State machine: idle, listening, paused, announcing, awaitingResponse, transitioning
- Contact name matching (alias-first, then chat title substring)
- Announcement queue (deduplicated per chatId)
- 5-second response window after announcements
- Audio interruption handling
- Background/foreground handling

**Step 1: Create VoiceCommandService.swift**

```swift
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

                    // Check if there was enough silence BEFORE speech started
                    if let speechStartTime = speechStart {
                        // The silence before speech is measured from the last silence start before speechStart
                        // Since we set silenceStart = now when voice stops, we need to track differently.
                        // Actually: when isSpeaking became true, the silence duration before that was
                        // (speechStartTime - previous silenceStart). We'll check this via a separate tracker.
                        evaluateCommandCandidate()
                    }
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
                // After playing, process next announcement or return to listening
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

        // Only queue announcements when we're on the contacts view (listening/awaitingResponse)
        guard state == .listening || state == .awaitingResponse || state == .announcing else { return }

        let chatId = message.chatId
        guard let chat = TelegramService.shared.chats.first(where: { $0.id == chatId }) else { return }

        let displayName = Config.voiceAlias(for: chatId) ?? chat.title
        let announcement = Announcement(chatId: chatId, chatTitle: displayName, message: message)

        // Deduplicate: replace existing announcement for same chatId
        announcementQueue.removeAll { $0.chatId == chatId }
        announcementQueue.append(announcement)

        print("🎤 VoiceCommand: queued announcement for \(displayName) (\(announcementQueue.count) in queue)")

        // If we're just listening (not already announcing/awaiting), start processing
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
        let completion = ttsCompletion
        ttsCompletion = nil

        // Resume listening after TTS
        if state != .idle && state != .transitioning {
            setupAudioSession()
            startEngine()
            startSpeechRecognition()
        }

        completion?()
    }

    // MARK: - Speech Recognition

    private func startSpeechRecognition() {
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
                        // Stay paused — user must resume manually or via "start listening"

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
```

**Step 2: Regenerate Xcode project**

Run: `cd /Users/vs/workspace/telegrowl && xcodegen generate`
Expected: `Generated project Telegrowl.xcodeproj`

**Step 3: Verify it compiles**

Run: `cd /Users/vs/workspace/telegrowl && xcodebuild -scheme Telegrowl -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Telegrowl/Services/VoiceCommandService.swift project.yml
git commit -m "feat: add VoiceCommandService with command detection, TTS, and announcement queue"
```

---

### Task 4: Extend VoiceChatService with New Commands

**Files:**
- Modify: `Telegrowl/Services/VoiceChatService.swift`

Add "close", "chat with X", and cross-chat announcement support to VoiceChatService.

**Step 1: Add an action callback and cross-chat state**

Add after the existing `@Published var audioLevel` (around line 38):

```swift
/// Action callback for commands that require navigation (close, switch chat).
var onAction: ((VoiceCommandAction) -> Void)?

// Cross-chat announcements
private var crossChatAnnouncement: (chatId: Int64, chatTitle: String, message: Message)?
private var crossChatWindowTimer: Timer?
private var crossChatCancellable: AnyCancellable?
private let synthesizer = AVSpeechSynthesizer()
private var ttsCompletion: (() -> Void)?
```

**Step 2: Modify the speech recognition handler to recognize new commands**

Replace the `recognitionTask` callback inside `startSpeechRecognition()` (around line 510) with:

```swift
recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
    guard let self else { return }

    if let result {
        let text = result.bestTranscription.formattedString.lowercased()
        let muteCmd = Config.muteCommand.lowercased()
        let unmuteCmd = Config.unmuteCommand.lowercased()
        let closeCmd = Config.closeCommand.lowercased()
        let chatPrefix = Config.chatWithPrefix.lowercased()
        let playCmd = Config.playCommand.lowercased()
        let chatCmd = Config.chatCommand.lowercased()

        // Check unmute first (since "unmute" contains "mute")
        if text.hasSuffix(unmuteCmd) && self.isMuted {
            Task { @MainActor in self.unmute() }
        } else if text.hasSuffix(muteCmd) && !self.isMuted {
            Task { @MainActor in self.mute() }
        } else if text.hasSuffix(closeCmd) {
            Task { @MainActor in self.handleCloseCommand() }
        } else if let range = text.range(of: chatPrefix, options: .backwards) {
            let nameQuery = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !nameQuery.isEmpty {
                Task { @MainActor in self.handleSwitchChatCommand(nameQuery: nameQuery) }
            }
        } else if self.crossChatAnnouncement != nil {
            if text.hasSuffix(chatCmd) {
                Task { @MainActor in self.handleCrossChatCommand() }
            } else if text.hasSuffix(playCmd) {
                Task { @MainActor in self.handleCrossChatPlay() }
            }
        }
    }

    if let error {
        print("⚠️ VoiceChat: speech recognition error: \(error)")
        Task { @MainActor in self.restartSpeechRecognition() }
    }
}
```

**Step 3: Add the command handler methods**

Add before `// MARK: - Permissions`:

```swift
// MARK: - Voice Command Handlers

private func handleCloseCommand() {
    print("🎧 VoiceChat: close command received")
    discardRecording()
    stop()
    onAction?(.closeChat)
}

private func handleSwitchChatCommand(nameQuery: String) {
    let chats = TelegramService.shared.chats
    let aliases = Config.voiceAliases

    // Alias first
    for (chatId, alias) in aliases {
        if alias.lowercased() == nameQuery.lowercased() {
            if let chat = chats.first(where: { $0.id == chatId }) {
                print("🎧 VoiceChat: switching to \(chat.title) (via alias)")
                discardRecording()
                stop()
                onAction?(.switchChat(chatId: chat.id, chatTitle: chat.title))
                return
            }
        }
    }

    // Chat title substring
    for chat in chats {
        if chat.title.lowercased().contains(nameQuery.lowercased()) {
            print("🎧 VoiceChat: switching to \(chat.title)")
            discardRecording()
            stop()
            onAction?(.switchChat(chatId: chat.id, chatTitle: chat.title))
            return
        }
    }

    print("🎧 VoiceChat: contact not found for \"\(nameQuery)\"")
}

// MARK: - Cross-Chat Announcements

private func observeCrossChatMessages() {
    guard Config.announceCrossChat else { return }

    crossChatCancellable = NotificationCenter.default
        .publisher(for: .newIncomingMessage)
        .sink { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleCrossChatMessage(notification)
            }
        }
}

private func handleCrossChatMessage(_ notification: Foundation.Notification) {
    guard let message = notification.object as? Message,
          !message.isOutgoing,
          message.chatId != chatId else { return }

    guard let chat = TelegramService.shared.chats.first(where: { $0.id == message.chatId }) else { return }
    let displayName = Config.voiceAlias(for: message.chatId) ?? chat.title

    // Store the announcement — will be spoken during next silence gap
    crossChatAnnouncement = (chatId: message.chatId, chatTitle: displayName, message: message)
    print("🎧 VoiceChat: cross-chat message from \(displayName), waiting for silence to announce")
}

/// Called from handleVAD when we detect a silence gap and there's a pending cross-chat announcement.
private func announceCrossChat() {
    guard let announcement = crossChatAnnouncement else { return }

    // Pause engine for TTS
    stopEngine()
    stopSpeechRecognition()

    let utterance = AVSpeechUtterance(string: "Message from \(announcement.chatTitle)")
    utterance.voice = AVSpeechSynthesisVoice(language: Config.speechLocale)

    ttsCompletion = { [weak self] in
        guard let self else { return }
        // Resume engine after TTS
        self.setupAudioSession()
        self.startEngine()
        self.startSpeechRecognition()

        // Start cross-chat response window
        self.crossChatWindowTimer = Timer.scheduledTimer(withTimeInterval: Config.announcementWindow, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.crossChatAnnouncement = nil
                self?.crossChatWindowTimer = nil
            }
        }
    }

    synthesizer.delegate = self
    synthesizer.speak(utterance)
}

private func handleCrossChatCommand() {
    guard let announcement = crossChatAnnouncement else { return }
    crossChatWindowTimer?.invalidate()
    crossChatWindowTimer = nil
    crossChatAnnouncement = nil

    print("🎧 VoiceChat: switching to cross-chat \(announcement.chatTitle)")
    discardRecording()
    stop()
    onAction?(.switchChat(chatId: announcement.chatId, chatTitle: announcement.chatTitle))
}

private func handleCrossChatPlay() {
    guard let announcement = crossChatAnnouncement else { return }
    crossChatWindowTimer?.invalidate()
    crossChatWindowTimer = nil
    crossChatAnnouncement = nil

    print("🎧 VoiceChat: playing cross-chat message from \(announcement.chatTitle)")
    onAction?(.playMessage(message: announcement.message, chatTitle: announcement.chatTitle))
}
```

**Step 4: Add cross-chat observation call in `start()`**

In the `start(chatId:)` method, add after `observeAudioInterruptions()`:

```swift
observeCrossChatMessages()
```

**Step 5: Add cross-chat announcement trigger in `handleVAD`**

In `handleVAD`, inside the `.listening` case, before the voice check, add:

```swift
// Announce cross-chat messages during silence
if crossChatAnnouncement != nil && !isMuted {
    announceCrossChat()
    return
}
```

**Step 6: Clean up cross-chat state in `stop()`**

Add to the `stop()` method:

```swift
crossChatCancellable?.cancel()
crossChatCancellable = nil
crossChatWindowTimer?.invalidate()
crossChatWindowTimer = nil
crossChatAnnouncement = nil
synthesizer.stopSpeaking(at: .immediate)
```

**Step 7: Make VoiceChatService conform to AVSpeechSynthesizerDelegate**

Add at the bottom of the file:

```swift
// MARK: - AVSpeechSynthesizerDelegate

extension VoiceChatService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.ttsCompletion?()
            self.ttsCompletion = nil
        }
    }
}
```

**Step 8: Verify it compiles**

Run: `cd /Users/vs/workspace/telegrowl && xcodebuild -scheme Telegrowl -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 9: Commit**

```bash
git add Telegrowl/Services/VoiceChatService.swift
git commit -m "feat: add close, chat-switch, and cross-chat commands to VoiceChatService"
```

---

### Task 5: Wire Up ContentView for Voice-Driven Navigation

**Files:**
- Modify: `Telegrowl/Views/ContentView.swift`

ContentView needs to:
1. Start VoiceCommandService after auth
2. Handle VoiceCommandAction callbacks for navigation
3. Handle handoffs between VoiceCommandService and VoiceChatService
4. Navigate programmatically via voice commands (without manual taps)

**Step 1: Add VoiceCommandService state observation**

Add a new `@StateObject` at the top of `ContentView`:

```swift
@StateObject private var voiceCommandService = VoiceCommandService.shared
```

**Step 2: Add voice control startup after authentication**

Add an `.onChange` modifier for auth state after the existing `.onChange(of: telegramService.error)`:

```swift
.task {
    // Start voice control once authenticated
    if telegramService.isAuthenticated {
        await startVoiceControlIfNeeded()
    }
}
.onChange(of: telegramService.isAuthenticated) { _, isAuth in
    if isAuth {
        Task { await startVoiceControlIfNeeded() }
    }
}
```

**Step 3: Add the startup and action handler methods**

Add before `// MARK: - Helpers`:

```swift
// MARK: - Voice Control

private func startVoiceControlIfNeeded() async {
    guard Config.voiceControlEnabled else { return }
    let granted = await VoiceCommandService.requestPermissions()
    if granted {
        voiceCommandService.onAction = { [weak telegramService] action in
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
        // Navigate to voice chat directly
        navigationPath = NavigationPath()
        navigationPath.append(chatId)
        navigationPath.append("voiceChat-\(chatId)")

    case .switchChat(let chatId, let chatTitle):
        // VoiceChatService already stopped itself
        // VoiceCommandService announces, then opens new chat
        voiceCommandService.onChatOpening()
        voiceCommandService.stop()
        // Brief announcement then open
        let synth = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: "Starting chat with \(chatTitle)")
        utterance.voice = AVSpeechSynthesisVoice(language: Config.speechLocale)
        synth.speak(utterance)
        // Navigate after small delay for announcement
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
        // Graceful exit — not common on iOS but possible via suspend
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
```

**Step 4: Wire VoiceChatService action callback in the voice chat destination**

In the `navigationView` computed property, modify the voice chat `NavigationDestination` for String to pass an action handler:

Replace the existing string destination with:

```swift
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
```

**Step 5: Stop VoiceCommandService when entering voice chat manually (tap)**

In the `conversationDestination` toolbar trailing button, the existing waveform NavigationLink should also trigger the handoff. Add `.simultaneousGesture` or use `.onAppear` in VoiceChatView. The cleanest approach: in VoiceChatView's `.task`, call `VoiceCommandService.shared.onChatOpening()`. This is handled in Task 6.

**Step 6: Restart VoiceCommandService when navigating back**

Add an `.onChange` to detect when navigation pops back to root:

```swift
.onChange(of: navigationPath.count) { oldCount, newCount in
    if newCount == 0 && oldCount > 0 {
        // Returned to contacts view
        voiceCommandService.onChatClosed()
    }
}
```

**Step 7: Verify it compiles**

Run: `cd /Users/vs/workspace/telegrowl && xcodebuild -scheme Telegrowl -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 8: Commit**

```bash
git add Telegrowl/Views/ContentView.swift
git commit -m "feat: wire voice command navigation and service handoffs in ContentView"
```

---

### Task 6: Update VoiceChatView for Action Callback

**Files:**
- Modify: `Telegrowl/Views/VoiceChatView.swift`

VoiceChatView needs to accept an action callback and pass it to VoiceChatService, and notify VoiceCommandService on entry.

**Step 1: Add action callback parameter and pass to service**

Replace the struct declaration and add the callback:

```swift
struct VoiceChatView: View {
    @StateObject private var voiceChatService = VoiceChatService()
    @Environment(\.dismiss) var dismiss

    let chatId: Int64
    let chatTitle: String
    var onAction: ((VoiceCommandAction) -> Void)?

    // ... rest of body stays the same
```

**Step 2: Modify the `.task` to wire the action callback and notify VoiceCommandService**

Replace the existing `.task` modifier:

```swift
.task {
    // Stop VoiceCommandService for handoff
    VoiceCommandService.shared.onChatOpening()

    let granted = await VoiceChatService.requestPermissions()
    if granted {
        voiceChatService.onAction = { action in
            switch action {
            case .closeChat:
                dismiss()
            default:
                onAction?(action)
                dismiss()
            }
        }
        voiceChatService.start(chatId: chatId)
    } else {
        dismiss()
    }
}
```

**Step 3: Verify it compiles**

Run: `cd /Users/vs/workspace/telegrowl && xcodebuild -scheme Telegrowl -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Telegrowl/Views/VoiceChatView.swift
git commit -m "feat: add voice action callback to VoiceChatView"
```

---

### Task 7: Add Voice Alias UI to ChatListView

**Files:**
- Modify: `Telegrowl/Views/ChatListView.swift`

Add long-press context menu for alias management, display aliases on rows, and show a listening indicator.

**Step 1: Add state for alias editing**

Add after the existing `@State` properties in `ChatListView`:

```swift
@StateObject private var voiceCommandService = VoiceCommandService.shared
@State private var aliasEditChatId: Int64?
@State private var aliasEditText = ""
@State private var showingAliasAlert = false
```

**Step 2: Add context menu to chat rows**

Wrap the existing `NavigationLink` inside `ForEach` with a `.contextMenu`:

```swift
NavigationLink(value: chat.id) {
    ChatRow(chat: chat)
}
.listRowInsets(EdgeInsets(top: 0, leading: TelegramTheme.chatListAvatarInset, bottom: 0, trailing: 16))
.contextMenu {
    let alias = Config.voiceAlias(for: chat.id)
    if let alias {
        Button {
            aliasEditChatId = chat.id
            aliasEditText = alias
            showingAliasAlert = true
        } label: {
            Label("Edit Voice Alias (\(alias))", systemImage: "pencil")
        }
        Button(role: .destructive) {
            Config.removeVoiceAlias(chatId: chat.id)
        } label: {
            Label("Clear Voice Alias", systemImage: "trash")
        }
    } else {
        Button {
            aliasEditChatId = chat.id
            aliasEditText = ""
            showingAliasAlert = true
        } label: {
            Label("Set Voice Alias", systemImage: "mic.badge.plus")
        }
    }
}
```

**Step 3: Add the alias alert**

Add after the `.sheet(isPresented: $showingSettings)`:

```swift
.alert("Voice Alias", isPresented: $showingAliasAlert) {
    TextField("Alias (e.g. bot)", text: $aliasEditText)
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
    Button("Save") {
        if let chatId = aliasEditChatId, !aliasEditText.trimmingCharacters(in: .whitespaces).isEmpty {
            Config.setVoiceAlias(chatId: chatId, alias: aliasEditText.trimmingCharacters(in: .whitespaces))
        }
    }
    Button("Cancel", role: .cancel) { }
} message: {
    Text("Set a short name for voice commands (e.g. \"bot\" instead of the full name)")
}
```

**Step 4: Display alias on ChatRow**

Modify `ChatRow` to show the alias. In the top-line `HStack` of `ChatRow`, replace the title `Text` with:

```swift
VStack(alignment: .leading, spacing: 1) {
    Text(chat.title)
        .font(TelegramTheme.titleFont)
        .foregroundColor(TelegramTheme.textPrimary)
        .lineLimit(1)

    if let alias = Config.voiceAlias(for: chat.id) {
        Text(alias)
            .font(.system(size: 12))
            .foregroundColor(TelegramTheme.textSecondary)
            .italic()
            .lineLimit(1)
    }
}
```

Note: The timestamp should remain in the same HStack, to the right of this VStack.

**Step 5: Add listening indicator to toolbar**

Add a trailing toolbar item showing voice control state. Add to the existing `toolbar`:

```swift
ToolbarItem(placement: .topBarTrailing) {
    if Config.voiceControlEnabled {
        VoiceListeningIndicator(state: voiceCommandService.state)
    }
}
```

Create the indicator view at the bottom of ChatListView.swift:

```swift
struct VoiceListeningIndicator: View {
    let state: VoiceCommandState

    var body: some View {
        switch state {
        case .listening, .awaitingResponse:
            Image(systemName: "mic.fill")
                .font(.system(size: 14))
                .foregroundColor(TelegramTheme.accent)
                .symbolEffect(.pulse)
        case .paused:
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 14))
                .foregroundColor(TelegramTheme.textSecondary)
        case .announcing:
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 14))
                .foregroundColor(TelegramTheme.accent)
        case .transitioning:
            ProgressView()
                .scaleEffect(0.7)
        case .idle:
            EmptyView()
        }
    }
}
```

**Step 6: Verify it compiles**

Run: `cd /Users/vs/workspace/telegrowl && xcodebuild -scheme Telegrowl -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 7: Commit**

```bash
git add Telegrowl/Views/ChatListView.swift
git commit -m "feat: add voice alias context menu and listening indicator to ChatListView"
```

---

### Task 8: Add Voice Control Settings Section

**Files:**
- Modify: `Telegrowl/Views/SettingsView.swift`

**Step 1: Add @State properties for new settings**

Add after the existing `@State` properties:

```swift
@State private var voiceControlEnabled = Config.voiceControlEnabled
@State private var speechLocale = Config.speechLocale
@State private var exitCommand = Config.exitCommand
@State private var chatWithPrefix = Config.chatWithPrefix
@State private var playCommand = Config.playCommand
@State private var chatCommand = Config.chatCommand
@State private var closeCommand = Config.closeCommand
@State private var pauseCommand = Config.pauseCommand
@State private var resumeCommand = Config.resumeCommand
@State private var readTextMessages = Config.readTextMessages
@State private var announceCrossChat = Config.announceCrossChat
```

**Step 2: Add the Voice Control section to the Form**

Add a new section between `voiceChatSection` and `aboutSection` in the Form body:

```swift
voiceControlSection
```

**Step 3: Create the section view**

Add the section computed property:

```swift
// MARK: - Voice Control Section

private var voiceControlSection: some View {
    Section {
        Toggle("Voice Control", isOn: $voiceControlEnabled)

        if voiceControlEnabled {
            HStack {
                Text("Language")
                Spacer()
                Picker("", selection: $speechLocale) {
                    Text("English").tag("en-US")
                    Text("Russian").tag("ru-RU")
                    Text("Spanish").tag("es-ES")
                    Text("German").tag("de-DE")
                    Text("French").tag("fr-FR")
                }
                .pickerStyle(.menu)
            }

            Toggle("Read Text Messages", isOn: $readTextMessages)
            Toggle("Announce Cross-Chat", isOn: $announceCrossChat)

            DisclosureGroup("Command Words") {
                commandField("Exit", text: $exitCommand)
                commandField("Chat with...", text: $chatWithPrefix)
                commandField("Play", text: $playCommand)
                commandField("Chat", text: $chatCommand)
                commandField("Close", text: $closeCommand)
                commandField("Pause", text: $pauseCommand)
                commandField("Resume", text: $resumeCommand)
            }
        }
    } header: {
        Text("Voice Control")
    } footer: {
        Text("When enabled, the app listens for voice commands from the contacts screen. Commands must be spoken with a brief pause before and after.")
    }
}

private func commandField(_ label: String, text: Binding<String>) -> some View {
    HStack {
        Text(label)
        Spacer()
        TextField(label, text: text)
            .multilineTextAlignment(.trailing)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .foregroundColor(TelegramTheme.textSecondary)
    }
}
```

**Step 4: Save the new settings**

Add to `saveSettings()`:

```swift
Config.voiceControlEnabled = voiceControlEnabled
Config.speechLocale = speechLocale
Config.exitCommand = exitCommand
Config.chatWithPrefix = chatWithPrefix
Config.playCommand = playCommand
Config.chatCommand = chatCommand
Config.closeCommand = closeCommand
Config.pauseCommand = pauseCommand
Config.resumeCommand = resumeCommand
Config.readTextMessages = readTextMessages
Config.announceCrossChat = announceCrossChat
```

**Step 5: Verify it compiles**

Run: `cd /Users/vs/workspace/telegrowl && xcodebuild -scheme Telegrowl -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add Telegrowl/Views/SettingsView.swift
git commit -m "feat: add voice control settings section with command words and locale"
```

---

### Task 9: Update Config.swift (actual file, not template)

**Files:**
- Modify: `Telegrowl/App/Config.swift`

The template was updated in Task 1. The actual `Config.swift` (gitignored) needs the same changes applied. This is identical to the template changes — copy the new keys, defaults registration, and computed properties from the template.

**Step 1: Apply the same changes from Task 1 to Config.swift**

Read the current `Config.swift`, then apply the identical additions: new Keys, new `registerDefaults` entries, new computed properties, and voice alias methods.

**Step 2: Verify it compiles**

Run: `cd /Users/vs/workspace/telegrowl && xcodebuild -scheme Telegrowl -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 3: No commit needed** (Config.swift is gitignored)

---

### Task 10: Regenerate Xcode Project & Full Build Verification

**Files:**
- Regenerate: `Telegrowl.xcodeproj` via XcodeGen

**Step 1: Regenerate**

Run: `cd /Users/vs/workspace/telegrowl && xcodegen generate`
Expected: `Generated project Telegrowl.xcodeproj`

**Step 2: Full build**

Run: `cd /Users/vs/workspace/telegrowl && xcodebuild -scheme Telegrowl -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -30`
Expected: BUILD SUCCEEDED

**Step 3: Commit project file if changed**

```bash
git add Telegrowl.xcodeproj
git commit -m "chore: regenerate Xcode project with VoiceCommandService"
```

---

### Task 11: Update CLAUDE.md Documentation

**Files:**
- Modify: `CLAUDE.md`

Update the architecture diagram, key files table, and implementation notes to reflect VoiceCommandService, voice aliases, new Config properties, and the voice control flow.

**Step 1: Update Architecture section**

Add to the Services section:

```
Services (Singletons, @MainActor):
    ├── TelegramService - TDLib client, auth state machine, chat/message management
    ├── AudioService - M4A recording, playback, silence detection, haptics
    ├── AudioConverter - M4A→OGG/Opus conversion, waveform generation, temp file cleanup
    └── VoiceCommandService - Global voice commands, TTS announcements, announcement queue
```

**Step 2: Add VoiceCommandService to Key Files table**

```
| `Telegrowl/Services/VoiceCommandService.swift` | Global voice commands: AVAudioEngine + SFSpeechRecognizer + AVSpeechSynthesizer |
```

**Step 3: Add Voice Control implementation notes**

Add a new section:

```
**Voice Control:**
- VoiceCommandService is a singleton, starts after auth + permissions on contacts view
- Silence-bounded command detection: ≥0.75s silence before and after speech = command candidate
- Contact matching: alias first (exact, case-insensitive), then chat title (substring)
- Announcement queue: deduplicated per chatId, sequential with 5s response windows
- Service handoff: VoiceCommandService stops → VoiceChatService starts (one mic owner at a time)
- TTS via AVSpeechSynthesizer, pauses mic during speech to avoid feedback
- Voice aliases stored in UserDefaults as [Int64: String] via Config
```

**Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with voice control architecture"
```

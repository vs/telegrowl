import Foundation
import AVFoundation
import Combine
import Speech
import TDLibKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Voice Chat State

enum VoiceChatState: Equatable {
    case idle
    case listening
    case recording
    case processing
    case playing
}

// MARK: - Voice Chat Service

/// Manages continuous voice chat: mic monitoring via AVAudioEngine,
/// VAD-based recording, send pipeline, and incoming message playback queue.
/// NOT a singleton — created per voice chat session by VoiceChatView.
@MainActor
class VoiceChatService: NSObject, ObservableObject {

    // MARK: - Published Properties

    @Published var state: VoiceChatState = .idle
    @Published var isMuted: Bool = false
    @Published var audioLevel: Float = -160.0

    /// Action callback for commands that require navigation (close, switch chat).
    var onAction: ((VoiceCommandAction) -> Void)?

    // Cross-chat announcements
    private var crossChatAnnouncement: (chatId: Int64, chatTitle: String, message: Message)?
    private var crossChatWindowTimer: Timer?
    private var crossChatCancellable: AnyCancellable?
    private let synthesizer = AVSpeechSynthesizer()
    private var ttsCompletion: (() -> Void)?

    // MARK: - Private Properties

    private var chatId: Int64 = 0
    private let audioEngine = AVAudioEngine()
    private var recordingURL: URL?
    private var recordingStartTime: Foundation.Date?
    private var silenceStartTime: Foundation.Date?
    private var sampleRate: Double = 48000

    private var incomingQueue: [VoiceNote] = []
    private var playbackCancellable: AnyCancellable?
    private var notificationCancellable: AnyCancellable?
    private var interruptionCancellable: AnyCancellable?
    private var maxDurationTimer: Timer?

    // Audio file for recording — accessed from audio thread, so nonisolated(unsafe)
    private nonisolated(unsafe) var audioFile: AVAudioFile?

    // MARK: - Speech Recognition
    private var speechRecognizer: SFSpeechRecognizer?
    private nonisolated(unsafe) var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRestartTimer: Timer?

    // MARK: - Public Methods

    /// Start voice chat session for a given chat.
    func start(chatId: Int64) {
        guard state == .idle else {
            print("🎙️ VoiceChat: already running, ignoring start")
            return
        }

        self.chatId = chatId
        print("🎙️ VoiceChat: starting for chat \(chatId)")

        setupAudioSession()
        startEngine()
        observeIncomingMessages()
        startSpeechRecognition()
        observeAudioInterruptions()
        observeCrossChatMessages()

        state = .listening
        haptic(.medium)
    }

    /// Stop voice chat session entirely.
    func stop() {
        print("🎙️ VoiceChat: stopping")

        stopEngine()
        discardRecording()
        incomingQueue.removeAll()
        playbackCancellable?.cancel()
        playbackCancellable = nil
        notificationCancellable?.cancel()
        notificationCancellable = nil
        interruptionCancellable?.cancel()
        interruptionCancellable = nil
        AudioService.shared.stopPlayback()
        stopSpeechRecognition()
        crossChatCancellable?.cancel()
        crossChatCancellable = nil
        crossChatWindowTimer?.invalidate()
        crossChatWindowTimer = nil
        crossChatAnnouncement = nil
        synthesizer.stopSpeaking(at: .immediate)

        state = .idle
    }

    /// Toggle mute on/off.
    func toggleMute() {
        if isMuted {
            unmute()
        } else {
            mute()
        }
    }

    /// Mute the microphone (stop recording if active, keep engine running for playback).
    func mute() {
        guard !isMuted else { return }
        isMuted = true
        print("🎙️ VoiceChat: muted")

        if state == .recording {
            discardRecording()
            state = .listening
        }

        haptic(.light)
    }

    /// Unmute the microphone.
    func unmute() {
        guard isMuted else { return }
        isMuted = false
        print("🎙️ VoiceChat: unmuted")
        haptic(.light)
        restartSpeechRecognition()
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
            print("🎙️ VoiceChat: audio session configured")
        } catch {
            print("❌ VoiceChat: audio session setup failed: \(error)")
        }
    }

    // MARK: - Audio Engine

    private func startEngine() {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        sampleRate = format.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        do {
            try audioEngine.start()
            print("🎙️ VoiceChat: engine started (sampleRate=\(sampleRate))")
        } catch {
            print("❌ VoiceChat: engine start failed: \(error)")
        }
    }

    private func stopEngine() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        print("🎙️ VoiceChat: engine stopped")
    }

    // MARK: - VAD & Buffer Processing

    /// Called on the audio thread for every buffer from the input tap.
    /// All audio I/O (recording writes) happens here to avoid buffer reuse races.
    private nonisolated func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Feed speech recognizer synchronously on audio thread (append is thread-safe)
        recognitionRequest?.append(buffer)

        // Write to recording file synchronously on audio thread (before buffer is reused)
        if let file = audioFile {
            do {
                try file.write(from: buffer)
            } catch {
                print("❌ VoiceChat: failed to write buffer: \(error)")
            }
        }

        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // Calculate RMS -> dB
        var sumOfSquares: Float = 0
        for i in 0..<frameCount {
            let sample = channelData[i]
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(frameCount))
        let db = rms > 0 ? 20 * log10(rms) : -160.0

        let threshold = Config.vadThreshold
        let silenceDuration = Config.silenceDuration
        let isVoice = db > threshold

        // Bounce only computed values to main actor for state changes
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.audioLevel = db
            self.handleVAD(isVoice: isVoice, silenceDuration: silenceDuration)
        }
    }

    /// Main actor VAD state machine. Decides transitions between listening/recording/playing.
    private func handleVAD(isVoice: Bool, silenceDuration: TimeInterval) {
        switch state {
        case .listening:
            // Announce cross-chat messages during silence
            if crossChatAnnouncement != nil && !isMuted {
                announceCrossChat()
                return
            }

            if isVoice && !isMuted {
                startRecording()
            }

        case .recording:
            if isMuted {
                discardRecording()
                state = .listening
                return
            }

            if isVoice {
                silenceStartTime = nil
            } else {
                if let silenceStart = silenceStartTime {
                    if Foundation.Date().timeIntervalSince(silenceStart) >= silenceDuration {
                        finishRecording()
                    }
                } else {
                    silenceStartTime = Foundation.Date()
                }
            }

        case .playing:
            if isVoice && !isMuted {
                print("🎙️ VoiceChat: playback interrupted by voice")
                AudioService.shared.stopPlayback()
                playbackCancellable?.cancel()
                playbackCancellable = nil
                startRecording()
            }

        case .idle, .processing:
            break
        }
    }

    // MARK: - Recording

    private func startRecording() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let filename = "vc_\(Int(Foundation.Date().timeIntervalSince1970)).m4a"
        let url = documentsPath.appendingPathComponent(filename)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            // audioFile is nonisolated(unsafe) — set it here on MainActor,
            // processAudioBuffer reads it on the audio thread to write buffers.
            audioFile = try AVAudioFile(forWriting: url, settings: settings)
            recordingURL = url
            recordingStartTime = Foundation.Date()
            silenceStartTime = nil
            state = .recording

            // Start max duration timer
            let maxDuration = Config.maxRecordingDuration
            maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.finishRecording()
                }
            }

            haptic(.medium)
            print("🎙️ VoiceChat: recording started -> \(filename)")
        } catch {
            print("❌ VoiceChat: failed to create recording file: \(error)")
        }
    }

    private func finishRecording() {
        guard let url = recordingURL,
              let startTime = recordingStartTime else {
            state = .listening
            return
        }

        let duration = Foundation.Date().timeIntervalSince(startTime)
        audioFile = nil
        recordingURL = nil
        recordingStartTime = nil
        silenceStartTime = nil
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil

        // Check minimum duration
        if duration < Config.minRecordingDuration {
            print("🎙️ VoiceChat: recording too short (\(String(format: "%.1f", duration))s), discarding")
            deleteFile(at: url)
            state = .listening
            return
        }

        print("🎙️ VoiceChat: recording finished (\(String(format: "%.1f", duration))s)")
        state = .processing
        haptic(.light)

        // Send pipeline
        let durationInt = Int(ceil(duration))
        let targetChatId = self.chatId
        Task.detached { [weak self] in
            do {
                let (oggURL, waveform) = try await AudioConverter.convertToOpus(inputURL: url)
                print("📤 VoiceChat: converted, sending...")

                try await TelegramService.shared.sendVoiceMessage(
                    audioURL: oggURL,
                    duration: durationInt,
                    waveform: waveform,
                    chatId: targetChatId
                )
                print("📤 VoiceChat: sent successfully")

                // Cleanup temp files
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: oggURL)
            } catch {
                print("❌ VoiceChat: send pipeline failed: \(error)")
            }

            // Return to listening or play queued messages
            await MainActor.run { [weak self] in
                guard let self, self.state == .processing else { return }
                if !self.incomingQueue.isEmpty {
                    self.playNext()
                } else {
                    self.state = .listening
                }
            }
        }
    }

    private func discardRecording() {
        if let url = recordingURL {
            audioFile = nil
            recordingURL = nil
            recordingStartTime = nil
            silenceStartTime = nil
            maxDurationTimer?.invalidate()
            maxDurationTimer = nil
            deleteFile(at: url)
            print("🎙️ VoiceChat: recording discarded")
        }
    }

    private func deleteFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Incoming Message Queue

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
                        print("🎧 VoiceChat: audio interruption began")
                        if self.state == .recording {
                            self.discardRecording()
                        }
                        self.stopEngine()
                        self.stopSpeechRecognition()
                        self.isMuted = true
                        self.state = .idle

                    case .ended:
                        print("🎧 VoiceChat: audio interruption ended")
                        // Stay muted — user taps unmute to resume

                    @unknown default:
                        break
                    }
                }
            }
    }

    private func observeIncomingMessages() {
        notificationCancellable = NotificationCenter.default
            .publisher(for: .newVoiceMessage)
            .sink { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleIncomingVoice(notification)
                }
            }
    }

    private func handleIncomingVoice(_ notification: Foundation.Notification) {
        guard let message = notification.object as? Message,
              message.chatId == chatId,
              !message.isOutgoing,
              case .messageVoiceNote(let voiceContent) = message.content else {
            return
        }

        let voiceNote = voiceContent.voiceNote
        print("📥 VoiceChat: incoming voice note (duration=\(voiceNote.duration)s)")

        switch state {
        case .recording, .processing:
            // Queue for later playback
            incomingQueue.append(voiceNote)
            print("📥 VoiceChat: queued (\(incomingQueue.count) in queue)")

        case .listening, .idle:
            // Play immediately (even if muted — user can hear responses)
            incomingQueue.append(voiceNote)
            playNext()

        case .playing:
            // Queue behind current playback
            incomingQueue.append(voiceNote)
            print("📥 VoiceChat: queued behind current playback (\(incomingQueue.count) in queue)")
        }
    }

    private func playNext() {
        guard !incomingQueue.isEmpty else {
            if state == .playing {
                state = .listening
            }
            return
        }

        let voiceNote = incomingQueue.removeFirst()
        state = .playing
        print("🔊 VoiceChat: playing next voice note (\(incomingQueue.count) remaining)")

        TelegramService.shared.downloadVoice(voiceNote) { [weak self] url in
            guard let self else { return }
            if let url {
                AudioService.shared.play(url: url)

                // Observe playback completion
                self.playbackCancellable?.cancel()
                self.playbackCancellable = AudioService.shared.$isPlaying
                    .dropFirst()
                    .filter { !$0 }
                    .first()
                    .sink { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            print("🔊 VoiceChat: playback finished")
                            self.playNext()
                        }
                    }
            } else {
                print("❌ VoiceChat: download failed, skipping")
                self.playNext()
            }
        }
    }

    // MARK: - Speech Recognition

    private func startSpeechRecognition() {
        speechRecognizer = SFSpeechRecognizer()
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            print("⚠️ VoiceChat: speech recognition not available")
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = true

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

        // Rolling restart every 50s to avoid Apple's ~60s session limit
        recognitionRestartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.restartSpeechRecognition()
            }
        }

        print("🗣️ VoiceChat: speech recognition started")
    }

    private func stopSpeechRecognition() {
        recognitionRestartTimer?.invalidate()
        recognitionRestartTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        speechRecognizer = nil
        print("🗣️ VoiceChat: speech recognition stopped")
    }

    private func restartSpeechRecognition() {
        stopSpeechRecognition()
        startSpeechRecognition()
    }

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

        crossChatAnnouncement = (chatId: message.chatId, chatTitle: displayName, message: message)
        print("🎧 VoiceChat: cross-chat message from \(displayName), waiting for silence to announce")
    }

    private func announceCrossChat() {
        guard let announcement = crossChatAnnouncement else { return }

        stopEngine()
        stopSpeechRecognition()

        let utterance = AVSpeechUtterance(string: "Message from \(announcement.chatTitle)")
        utterance.voice = AVSpeechSynthesisVoice(language: Config.speechLocale)

        ttsCompletion = { [weak self] in
            guard let self else { return }
            self.setupAudioSession()
            self.startEngine()
            self.startSpeechRecognition()

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

    // MARK: - Permissions

    static func requestPermissions() async -> Bool {
        // Microphone (iOS 17+ API)
        let micGranted = await AVAudioApplication.requestRecordPermission()

        // Speech recognition
        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        return micGranted && speechGranted
    }

    // MARK: - Haptics

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard Config.hapticFeedback else { return }
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
        #endif
    }

    // MARK: - Cleanup

    deinit {
        // Engine cleanup happens on stop(), but ensure tap is removed
        // Note: deinit runs on whatever thread — just nil out references
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension VoiceChatService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.ttsCompletion?()
            self.ttsCompletion = nil
        }
    }
}

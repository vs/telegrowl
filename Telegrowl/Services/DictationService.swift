import Foundation
import AVFoundation
import Combine
import Speech
import TDLibKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Dictation State

enum DictationState: Equatable {
    case idle        // Listening for trigger words only
    case dictating   // "text" triggered — capturing speech-to-text
    case recording   // "voice" triggered — recording audio + transcribing
    case sending     // Converting/enqueueing
}

// MARK: - Dictation Service

/// Manages trigger-word-based dictation within a conversation.
/// Created per conversation via @StateObject — NOT a singleton.
///
/// How it works:
/// - AVAudioEngine + SFSpeechRecognizer run continuously while conversation is open
/// - In `idle` state: recognizer watches for trigger words only — everything else ignored
/// - "text" or "text message" -> enters `dictating` state, captures speech-to-text
/// - "voice" or "voice message" -> enters `recording` state, records audio AND transcribes
/// - 3 seconds of no new recognized words = silence = command ends
/// - For voice: trim audio to ~0.5s after last spoken word (don't include the 3s silence gap)
/// - If no actual words captured after trigger, discard entirely
/// - Cancel via `cancel()` method (tap-to-cancel from UI)
@MainActor
class DictationService: ObservableObject {

    // MARK: - Published Properties

    @Published var state: DictationState = .idle
    @Published var audioLevel: Float = -160.0
    @Published var liveTranscription: String = ""
    @Published var isListening: Bool = false
    @Published var lastHeard: String = ""  // last few words heard in idle (for debug feedback)
    @Published var permissionDenied: Bool = false  // true if speech recognition permission was denied

    // MARK: - Private Properties

    private var chatId: Int64 = 0
    private let audioEngine = AVAudioEngine()
    private var sampleRate: Double = 48000

    // Speech recognition
    private var speechRecognizer: SFSpeechRecognizer?
    private nonisolated(unsafe) var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRestartTimer: Timer?

    // Trigger detection — tracks full transcript for diffing
    private var lastFullTranscript: String = ""

    // Active command state
    private var commandTranscript: String = ""

    // Recording (voice command)
    private var recordingURL: URL?
    private var recordingStartTime: Foundation.Date?
    private nonisolated(unsafe) var audioFile: AVAudioFile?
    private nonisolated(unsafe) var shouldWriteAudio = false

    // Silence detection — based on speech recognizer output stalling
    private var lastNewWordTime: Foundation.Date?
    private var lastProcessedTranscriptLength: Int = 0
    private var silenceCheckTimer: Timer?
    private let commandSilenceTimeout: TimeInterval = 3.0
    private let trailingSilenceTrim: TimeInterval = 0.5

    // Health check — detect stalled recognition
    private var recognitionStartTime: Foundation.Date?
    private var healthCheckTimer: Timer?

    // Restart debounce — prevents cascade from cancellation errors
    private var lastRestartTime: Foundation.Date?

    // Incoming voice playback queue
    private var incomingQueue: [VoiceNote] = []
    private var playbackCancellable: AnyCancellable?
    private var notificationCancellable: AnyCancellable?
    private var deferredDownloadCancellable: AnyCancellable?
    private var interruptionCancellable: AnyCancellable?

    // MARK: - Trigger Words

    /// Trigger words ordered longest-first so "text message" matches before "text".
    private let triggers: [(keyword: String, mode: DictationState)] = [
        ("text message", .dictating),
        ("voice message", .recording),
        ("text", .dictating),
        ("voice", .recording),
    ]

    // MARK: - Public Methods

    func start(chatId: Int64) {
        guard state == .idle else { return }
        self.chatId = chatId
        print("🎙️ Dictation: starting for chat \(chatId)")

        setupAudioSession()
        startEngine()
        startSpeechRecognition()
        observeIncomingMessages()
        observeAudioInterruptions()

        // Start silence check timer (runs every 0.5s)
        silenceCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkSilenceTimeout()
            }
        }
    }

    func stop() {
        print("🎙️ Dictation: stopping")
        silenceCheckTimer?.invalidate()
        silenceCheckTimer = nil
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        stopEngine()
        discardRecording()
        stopSpeechRecognition()
        notificationCancellable?.cancel()
        notificationCancellable = nil
        deferredDownloadCancellable?.cancel()
        deferredDownloadCancellable = nil
        interruptionCancellable?.cancel()
        interruptionCancellable = nil
        playbackCancellable?.cancel()
        playbackCancellable = nil
        AudioService.shared.stopPlayback()
        incomingQueue.removeAll()
        state = .idle
    }

    /// Cancel active dictation/recording, discard, return to idle.
    func cancel() {
        guard state == .dictating || state == .recording else { return }
        print("🎙️ Dictation: cancelled by user")
        discardRecording()
        resetCommandState()
        state = .idle
        restartSpeechRecognition()
    }

    // MARK: - Permissions

    enum PermissionResult {
        case granted
        case micDenied
        case speechDenied
    }

    static func requestPermissions() async -> PermissionResult {
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            print("❌ Dictation: microphone permission denied")
            return .micDenied
        }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            print("❌ Dictation: speech recognition permission denied (status: \(speechStatus.rawValue))")
            return .speechDenied
        }

        return .granted
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
            print("❌ Dictation: audio session setup failed: \(error)")
        }
    }

    // MARK: - Audio Engine

    private func startEngine() {
        let inputNode = audioEngine.inputNode

        // Prepare first so the engine resolves the actual hardware configuration
        audioEngine.prepare()

        // Use the hardware input format — NOT outputFormat, which may report a different
        // sample rate that Core Audio can't bridge (e.g. 48kHz client vs 24kHz Bluetooth HFP)
        let hwFormat = inputNode.inputFormat(forBus: 0)
        sampleRate = hwFormat.sampleRate

        print("🎙️ Dictation: hardware format: \(hwFormat.channelCount)ch, \(hwFormat.sampleRate)Hz")

        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            print("❌ Dictation: invalid hardware format — audio session may not be ready")
            return
        }

        // Create a mono format at the hardware's actual sample rate
        guard let tapFormat = AVAudioFormat(
            standardFormatWithSampleRate: hwFormat.sampleRate,
            channels: 1
        ) else {
            print("❌ Dictation: failed to create tap format")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        do {
            try audioEngine.start()
            print("🎙️ Dictation: engine started (sampleRate=\(sampleRate))")
        } catch {
            print("❌ Dictation: engine start failed: \(error)")
        }
    }

    private func stopEngine() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    /// Called on the audio thread. Feeds speech recognizer and writes recording file.
    private nonisolated func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Feed speech recognizer (append is thread-safe)
        recognitionRequest?.append(buffer)

        // Write to recording file synchronously on audio thread (AVAudioPCMBuffer is NOT Sendable)
        if let file = audioFile, shouldWriteAudio {
            do {
                try file.write(from: buffer)
            } catch {
                print("❌ Dictation: failed to write buffer: \(error)")
            }
        }

        // Calculate dB for audio level display
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

        Task { @MainActor [weak self] in
            self?.audioLevel = db
        }
    }

    // MARK: - Speech Recognition

    private func startSpeechRecognition() {
        let locale = Locale(identifier: Config.speechLocale)
        speechRecognizer = SFSpeechRecognizer(locale: locale)
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            print("⚠️ Dictation: speech recognition not available for \(Config.speechLocale)")
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }

        recognitionRequest.shouldReportPartialResults = true

        // Prefer on-device recognition but fall back to server if unavailable
        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
            print("🗣️ Dictation: using on-device recognition")
        } else {
            recognitionRequest.requiresOnDeviceRecognition = false
            print("🗣️ Dictation: on-device not available, using server recognition")
        }

        lastFullTranscript = ""
        lastProcessedTranscriptLength = 0

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let fullText = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !self.isListening {
                        self.isListening = true
                    }
                    self.handleTranscription(fullText)

                    // Recognition session ended (pause detected or limit reached) — restart immediately
                    if isFinal {
                        print("🗣️ Dictation: recognition session ended (isFinal), restarting")
                        self.restartSpeechRecognition()
                    }
                }
            }

            if let error {
                // Don't restart on cancellation errors — they're caused by our own restarts
                let nsError = error as NSError
                if nsError.code == 216 || nsError.code == 209 {
                    print("🗣️ Dictation: recognition cancelled (expected)")
                    return
                }
                print("⚠️ Dictation: speech recognition error: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.isListening = false
                    self?.restartSpeechRecognition()
                }
            }
        }

        // Rolling restart every 50s to avoid Apple's ~60s session limit
        recognitionRestartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartSpeechRecognition()
            }
        }

        // Health check — if no results after 5s, the recognizer may be stalled
        recognitionStartTime = Foundation.Date()
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isListening {
                    print("⚠️ Dictation: no recognition results after 5s — restarting engine + recognizer")
                    self.stopEngine()
                    self.stopSpeechRecognition()
                    self.setupAudioSession()
                    self.startEngine()
                    self.startSpeechRecognition()
                }
            }
        }

        print("🗣️ Dictation: speech recognition started")
    }

    private func stopSpeechRecognition() {
        recognitionRestartTimer?.invalidate()
        recognitionRestartTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        speechRecognizer = nil
        isListening = false
    }

    private func restartSpeechRecognition() {
        // Don't restart during active command — would lose transcription context
        guard state == .idle else { return }

        // Debounce: skip if restarted less than 1s ago (prevents cascade from cancellation errors)
        if let lastRestart = lastRestartTime, Foundation.Date().timeIntervalSince(lastRestart) < 1.0 {
            return
        }
        lastRestartTime = Foundation.Date()

        stopSpeechRecognition()
        startSpeechRecognition()
    }

    // MARK: - Transcription Handling

    private func handleTranscription(_ fullText: String) {
        let lowerText = fullText.lowercased()
        lastFullTranscript = lowerText

        switch state {
        case .idle:
            // Show last few words heard for debugging feedback
            let words = lowerText.split(separator: " ")
            let recent = words.suffix(4).joined(separator: " ")
            if recent != lastHeard {
                lastHeard = recent
                print("🗣️ Heard: \"\(recent)\"")
            }
            detectTrigger(in: lowerText)

        case .dictating, .recording:
            // Update last-word time (silence detection)
            let currentLength = fullText.count
            if currentLength > lastProcessedTranscriptLength {
                lastNewWordTime = Foundation.Date()
                lastProcessedTranscriptLength = currentLength
            }

            // Extract content after trigger for live preview
            updateCommandTranscript(from: lowerText)

        case .sending:
            break
        }
    }

    /// Detects trigger words in the transcription. Uses word boundary awareness
    /// to avoid false matches (e.g., "context" should not trigger on "text").
    private func detectTrigger(in text: String) {
        for trigger in triggers {
            // Search for the trigger keyword as a suffix or preceded by a word boundary
            guard let range = text.range(of: trigger.keyword, options: .backwards) else { continue }

            // Verify word boundary: trigger must be at start of text or preceded by a space
            if range.lowerBound != text.startIndex {
                let charBefore = text[text.index(before: range.lowerBound)]
                if !charBefore.isWhitespace {
                    continue
                }
            }

            let afterTrigger = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            startCommand(mode: trigger.mode, initialText: afterTrigger)
            return
        }
    }

    private func startCommand(mode: DictationState, initialText: String) {
        print("🎙️ Dictation: trigger detected -> \(mode)")

        commandTranscript = initialText
        liveTranscription = initialText
        lastHeard = ""
        lastNewWordTime = Foundation.Date()
        lastProcessedTranscriptLength = 0

        if mode == .recording {
            startAudioRecording()
        }

        state = mode
        haptic(.medium)
    }

    private func updateCommandTranscript(from lowerText: String) {
        // Use the stored trigger end offset to find content.
        // Since the recognizer may revise text, re-locate the trigger each time.
        for trigger in triggers {
            guard let range = lowerText.range(of: trigger.keyword, options: .backwards) else { continue }

            // Verify word boundary
            if range.lowerBound != lowerText.startIndex {
                let charBefore = lowerText[lowerText.index(before: range.lowerBound)]
                if !charBefore.isWhitespace {
                    continue
                }
            }

            let content = String(lowerText[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            commandTranscript = content
            liveTranscription = content
            return
        }
    }

    // MARK: - Silence Timeout

    private func checkSilenceTimeout() {
        guard state == .dictating || state == .recording else { return }
        guard let lastWord = lastNewWordTime else { return }

        let silence = Foundation.Date().timeIntervalSince(lastWord)
        if silence >= commandSilenceTimeout {
            finishCommand()
        }
    }

    // MARK: - Audio Recording (for voice commands)

    private func startAudioRecording() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let filename = "dict_\(Int(Foundation.Date().timeIntervalSince1970)).m4a"
        let url = documentsPath.appendingPathComponent(filename)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioFile = try AVAudioFile(forWriting: url, settings: settings)
            shouldWriteAudio = true
            recordingURL = url
            recordingStartTime = Foundation.Date()
            print("🎙️ Dictation: recording to \(filename)")
        } catch {
            print("❌ Dictation: failed to create recording file: \(error)")
        }
    }

    private func discardRecording() {
        shouldWriteAudio = false
        audioFile = nil
        if let url = recordingURL {
            recordingURL = nil
            recordingStartTime = nil
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Finish Command

    private func finishCommand() {
        let transcript = commandTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        // Discard if no actual words captured after trigger
        if transcript.isEmpty {
            print("🎙️ Dictation: no content captured, discarding")
            discardRecording()
            resetCommandState()
            state = .idle
            restartSpeechRecognition()
            return
        }

        let currentState = state
        state = .sending

        if currentState == .dictating {
            finishTextCommand(transcript: transcript)
        } else if currentState == .recording {
            finishVoiceCommand(transcript: transcript)
        }
    }

    private func finishTextCommand(transcript: String) {
        print("🎙️ Dictation: sending text -> \"\(transcript)\"")
        let targetChatId = self.chatId

        MessageSendQueue.shared.enqueueText(text: transcript, chatId: targetChatId)

        resetCommandState()
        state = .idle
        restartSpeechRecognition()
        flushPlaybackQueue()
    }

    private func finishVoiceCommand(transcript: String) {
        guard let url = recordingURL,
              let startTime = recordingStartTime else {
            resetCommandState()
            state = .idle
            restartSpeechRecognition()
            return
        }

        // Stop writing audio; calculate duration trimmed to ~0.5s after last spoken word
        let audioEndTime = (lastNewWordTime ?? Foundation.Date()).addingTimeInterval(trailingSilenceTrim)
        let duration = audioEndTime.timeIntervalSince(startTime)

        shouldWriteAudio = false
        audioFile = nil
        recordingURL = nil
        recordingStartTime = nil

        if duration < 0.5 {
            print("🎙️ Dictation: recording too short, discarding")
            try? FileManager.default.removeItem(at: url)
            resetCommandState()
            state = .idle
            restartSpeechRecognition()
            return
        }

        print("🎙️ Dictation: sending voice (\(String(format: "%.1f", duration))s) + caption")

        let durationInt = Int(ceil(duration))
        let targetChatId = self.chatId
        let caption = transcript

        // Trim the audio file to remove trailing silence, then convert and enqueue
        Task.detached {
            let trimmedURL = await AudioTrimmer.trim(url: url, toDuration: duration)
            let sourceURL = trimmedURL ?? url

            do {
                let (oggURL, waveform) = try await AudioConverter.convertToOpus(inputURL: sourceURL)
                await MainActor.run {
                    MessageSendQueue.shared.enqueueVoice(
                        audioURL: oggURL,
                        duration: durationInt,
                        waveform: waveform,
                        caption: caption,
                        chatId: targetChatId
                    )
                }
                // Clean up source files
                try? FileManager.default.removeItem(at: url)
                if let trimmedURL, trimmedURL != url {
                    try? FileManager.default.removeItem(at: trimmedURL)
                }
            } catch {
                print("❌ Dictation: conversion failed, sending M4A fallback")
                await MainActor.run {
                    MessageSendQueue.shared.enqueueVoice(
                        audioURL: sourceURL,
                        duration: durationInt,
                        waveform: nil,
                        caption: caption,
                        chatId: targetChatId
                    )
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.resetCommandState()
                self.state = .idle
                self.restartSpeechRecognition()
                self.flushPlaybackQueue()
            }
        }
    }

    private func resetCommandState() {
        commandTranscript = ""
        liveTranscription = ""
        lastNewWordTime = nil
        lastProcessedTranscriptLength = 0
    }

    // MARK: - Incoming Voice Playback

    private func observeIncomingMessages() {
        notificationCancellable = NotificationCenter.default
            .publisher(for: .newVoiceMessage)
            .sink { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleIncomingVoice(notification)
                }
            }

        deferredDownloadCancellable = NotificationCenter.default
            .publisher(for: .voiceDownloaded)
            .sink { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard Config.autoPlayResponses else { return }
                    if self.state == .idle, let url = notification.userInfo?["url"] as? URL {
                        AudioService.shared.play(url: url)
                    }
                }
            }
    }

    private func handleIncomingVoice(_ notification: Foundation.Notification) {
        guard Config.autoPlayResponses else { return }
        guard let message = notification.object as? Message,
              message.chatId == chatId,
              !message.isOutgoing,
              case .messageVoiceNote(let voiceContent) = message.content else { return }

        if state == .idle {
            // Play immediately
            TelegramService.shared.downloadVoice(voiceContent.voiceNote) { [weak self] url in
                guard let self else { return }
                if let url {
                    self.playAndChain(url: url)
                }
            }
        } else {
            // Queue for later
            incomingQueue.append(voiceContent.voiceNote)
        }
    }

    private func flushPlaybackQueue() {
        guard !incomingQueue.isEmpty else { return }
        playNextInQueue()
    }

    private func playNextInQueue() {
        guard !incomingQueue.isEmpty else { return }
        let voiceNote = incomingQueue.removeFirst()

        TelegramService.shared.downloadVoice(voiceNote) { [weak self] url in
            guard let self else { return }
            if let url {
                self.playAndChain(url: url)
            } else {
                // Download deferred — skip and try next
                self.playNextInQueue()
            }
        }
    }

    /// Play a voice message and chain to the next queued message when done.
    private func playAndChain(url: URL) {
        AudioService.shared.play(url: url)

        playbackCancellable?.cancel()
        playbackCancellable = AudioService.shared.$isPlaying
            .dropFirst()
            .filter { !$0 }
            .first()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.playNextInQueue()
                }
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

                    if type == .began {
                        print("🎙️ Dictation: audio interruption began")
                        if self.state == .dictating || self.state == .recording {
                            self.cancel()
                        }
                    } else if type == .ended {
                        print("🎙️ Dictation: audio interruption ended — restarting")
                        // Restart the full audio pipeline after interruption
                        self.stopEngine()
                        self.stopSpeechRecognition()
                        self.setupAudioSession()
                        self.startEngine()
                        self.startSpeechRecognition()
                    }
                }
            }
    }

    // MARK: - Haptics

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard Config.hapticFeedback else { return }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif
    }
}

// MARK: - Audio Trimmer

enum AudioTrimmer {
    /// Trim an audio file to the specified duration in seconds.
    /// Returns a new URL with trimmed audio, or nil if trimming fails or no trim is needed.
    static func trim(url: URL, toDuration targetDuration: TimeInterval) async -> URL? {
        do {
            let sourceFile = try AVAudioFile(forReading: url)
            let sampleRate = sourceFile.fileFormat.sampleRate
            let targetFrames = AVAudioFrameCount(targetDuration * sampleRate)

            // No trim needed if target is longer than source
            guard targetFrames < sourceFile.length else { return nil }

            let trimmedURL = url.deletingLastPathComponent()
                .appendingPathComponent("trimmed_\(url.lastPathComponent)")

            let settings = sourceFile.fileFormat.settings
            let outputFile = try AVAudioFile(forWriting: trimmedURL, settings: settings)

            let bufferSize: AVAudioFrameCount = 4096
            var framesWritten: AVAudioFrameCount = 0

            while framesWritten < targetFrames {
                let framesToRead = min(bufferSize, targetFrames - framesWritten)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFile.processingFormat,
                    frameCapacity: framesToRead
                ) else { break }
                try sourceFile.read(into: buffer, frameCount: framesToRead)
                try outputFile.write(from: buffer)
                framesWritten += buffer.frameLength
                if buffer.frameLength == 0 { break }
            }

            return trimmedURL
        } catch {
            print("❌ AudioTrimmer: trim failed: \(error)")
            return nil
        }
    }
}

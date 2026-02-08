# Voice Chat Mode Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement hands-free voice chat mode with VAD, speech recognition commands, and automatic message queue playback.

**Architecture:** New `VoiceChatService` orchestrates AVAudioEngine (VAD + speech recognition) and coordinates with existing `AudioService` (playback) and `TelegramService` (send/receive). New `VoiceChatView` provides minimal full-screen UI. Existing manual recording flow unchanged.

**Tech Stack:** AVAudioEngine, Speech framework (SFSpeechRecognizer), SwiftUI, TDLibKit

**Build/verify command:** `xcodebuild -project Telegrowl.xcodeproj -scheme Telegrowl -destination 'generic/platform=iOS' -allowProvisioningUpdates build 2>&1 | grep -E '(error:|BUILD SUCCEEDED|BUILD FAILED)'`

**Working directory:** `/Users/vs/workspace/telegrowl/.worktrees/voice-chat`

**No test suite exists.** Verification = code compiles. After each task, run the build command above.

---

### Task 1: Add Voice Chat settings to Config

Add new UserDefaults-backed settings for voice chat: VAD sensitivity, mute/unmute command words, minimum recording duration.

**Files:**
- Modify: `Telegrowl/App/Config.swift.template`

**Step 1: Add new Keys and defaults**

Add to the `Keys` enum:
```swift
static let vadSensitivity = "vadSensitivity"
static let muteCommand = "muteCommand"
static let unmuteCommand = "unmuteCommand"
static let minRecordingDuration = "minRecordingDuration"
```

Add to `registerDefaults()`:
```swift
Keys.vadSensitivity: 1,  // 0=Low, 1=Medium, 2=High
Keys.muteCommand: "mute",
Keys.unmuteCommand: "unmute",
Keys.minRecordingDuration: 0.5,
```

Add computed properties:
```swift
static var vadSensitivity: Int {
    get { defaults.integer(forKey: Keys.vadSensitivity) }
    set { defaults.set(newValue, forKey: Keys.vadSensitivity) }
}

static var vadThreshold: Float {
    switch vadSensitivity {
    case 0: return -30.0   // Low — only loud speech
    case 2: return -50.0   // High — picks up quiet speech
    default: return -40.0  // Medium
    }
}

static var muteCommand: String {
    get { defaults.string(forKey: Keys.muteCommand) ?? "mute" }
    set { defaults.set(newValue, forKey: Keys.muteCommand) }
}

static var unmuteCommand: String {
    get { defaults.string(forKey: Keys.unmuteCommand) ?? "unmute" }
    set { defaults.set(newValue, forKey: Keys.unmuteCommand) }
}

static var minRecordingDuration: TimeInterval {
    get { defaults.double(forKey: Keys.minRecordingDuration) }
    set { defaults.set(newValue, forKey: Keys.minRecordingDuration) }
}
```

**Step 2: Update local Config.swift**

Apply the same changes to the gitignored `Telegrowl/App/Config.swift`.

**Step 3: Build and verify**

Run: build command
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Telegrowl/App/Config.swift.template
git commit -m "feat: add voice chat settings to Config"
```

---

### Task 2: Create VoiceChatService — State machine and VAD

Create the core service with state machine, AVAudioEngine-based VAD, and recording via AVAudioFile. No speech recognition yet — that's Task 3.

**Files:**
- Create: `Telegrowl/Services/VoiceChatService.swift`

**Step 1: Create VoiceChatService with state machine**

```swift
import Foundation
import AVFoundation
import Combine
import TDLibKit

@MainActor
class VoiceChatService: ObservableObject {

    // MARK: - State

    enum ChatState: Equatable {
        case idle        // Voice chat not active
        case listening   // VAD monitoring, waiting for voice
        case recording   // User is speaking, writing to file
        case processing  // Converting + sending
        case playing     // Bot message playback
    }

    @Published var state: ChatState = .idle
    @Published var isMuted = false
    @Published var audioLevel: Float = -160

    // MARK: - Dependencies

    private let telegramService: TelegramService
    private let audioService: AudioService
    private var chatId: Int64 = 0

    // MARK: - Audio Engine

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var recordingStartTime: Date?

    // MARK: - VAD

    private var silenceStart: Date?
    private let silenceDuration: TimeInterval = 2.0

    // MARK: - Playback Queue

    private var playbackQueue: [VoiceNote] = []
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(telegramService: TelegramService = .shared,
         audioService: AudioService = .shared) {
        self.telegramService = telegramService
        self.audioService = audioService
    }

    // MARK: - Start / Stop Voice Chat

    func start(chatId: Int64) {
        self.chatId = chatId
        playbackQueue = []
        isMuted = false
        startListening()
        observeIncomingMessages()
        print("🎧 Voice chat started for chat \(chatId)")
    }

    func stop() {
        stopEngine()
        audioService.stopPlayback()
        playbackQueue = []
        cancellables.removeAll()
        state = .idle
        print("🎧 Voice chat stopped")
    }

    // MARK: - Mute / Unmute

    func toggleMute() {
        if isMuted {
            unmute()
        } else {
            mute()
        }
    }

    func mute() {
        isMuted = true
        if state == .recording {
            discardRecording()
        }
        stopEngine()
        state = .idle
        print("🔇 Muted")
    }

    func unmute() {
        isMuted = false
        startListening()
        print("🔊 Unmuted")
    }

    // MARK: - Audio Engine

    private func startEngine() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            Task { @MainActor in
                self?.processAudioBuffer(buffer)
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            print("🎧 Audio engine started")
        } catch {
            print("❌ Audio engine failed: \(error)")
        }
    }

    private func stopEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        silenceStart = nil
    }

    // MARK: - VAD Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)

        // Calculate RMS level in dB
        var sum: Float = 0
        for i in 0..<frameLength {
            sum += channelData[i] * channelData[i]
        }
        let rms = sqrt(sum / Float(frameLength))
        let db = 20 * log10(max(rms, 1e-10))
        audioLevel = db

        let threshold = Config.vadThreshold

        switch state {
        case .listening:
            if db > threshold {
                startRecording(buffer: buffer)
            }

        case .recording:
            // Write buffer to file
            writeBuffer(buffer)

            if db < threshold {
                if silenceStart == nil {
                    silenceStart = Date()
                } else if Date().timeIntervalSince(silenceStart!) >= Config.silenceDuration {
                    finishRecording()
                }
            } else {
                silenceStart = nil
            }

        case .playing:
            if db > threshold {
                // User interrupting bot playback
                audioService.stopPlayback()
                startRecording(buffer: buffer)
            }

        default:
            break
        }
    }

    // MARK: - Recording

    private func startRecording(buffer: AVAudioPCMBuffer) {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documentsPath.appendingPathComponent("vc_\(Date().timeIntervalSince1970).m4a")

        do {
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: buffer.format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            audioFile = try AVAudioFile(forWriting: url, settings: settings)
            recordingURL = url
            recordingStartTime = Date()
            silenceStart = nil
            state = .recording

            // Write the triggering buffer
            writeBuffer(buffer)

            if Config.hapticFeedback {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
            }

            print("🎙️ Voice chat recording started")
        } catch {
            print("❌ Failed to start VC recording: \(error)")
        }
    }

    private func writeBuffer(_ buffer: AVAudioPCMBuffer) {
        do {
            try audioFile?.write(from: buffer)
        } catch {
            print("❌ Write buffer failed: \(error)")
        }
    }

    private func finishRecording() {
        audioFile = nil
        silenceStart = nil

        guard let url = recordingURL else { return }
        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())

        // Discard if too short (false trigger)
        if duration < Config.minRecordingDuration {
            print("⚠️ Recording too short (\(String(format: "%.1f", duration))s), discarding")
            try? FileManager.default.removeItem(at: url)
            state = .listening
            return
        }

        if Config.hapticFeedback {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }

        print("🎙️ Voice chat recording finished (\(String(format: "%.1f", duration))s)")
        sendRecording(url: url, duration: Int(duration))
    }

    private func discardRecording() {
        audioFile = nil
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        silenceStart = nil
    }

    // MARK: - Send

    private func sendRecording(url: URL, duration: Int) {
        state = .processing
        let chatId = self.chatId
        let service = telegramService

        Task.detached {
            var audioURL = url
            var waveform: Data? = nil

            do {
                let (oggURL, wf) = try await AudioConverter.convertToOpus(inputURL: url)
                audioURL = oggURL
                waveform = wf
            } catch {
                print("❌ Conversion failed: \(error), sending M4A fallback")
            }

            do {
                try await service.sendVoiceMessage(
                    audioURL: audioURL,
                    duration: max(1, duration),
                    waveform: waveform,
                    chatId: chatId
                )
                try? FileManager.default.removeItem(at: url)
                print("📤 Voice chat message sent")
            } catch {
                print("❌ Voice chat send failed: \(error)")
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                // If VAD detected voice during processing, we're already recording
                if self.state == .processing {
                    if !self.playbackQueue.isEmpty {
                        self.playNext()
                    } else {
                        self.state = .listening
                    }
                }
            }
        }
    }

    // MARK: - Listening State

    private func startListening() {
        startEngine()
        if !playbackQueue.isEmpty {
            playNext()
        } else {
            state = .listening
        }
    }

    // MARK: - Incoming Message Queue

    private func observeIncomingMessages() {
        NotificationCenter.default.publisher(for: .newVoiceMessage)
            .compactMap { $0.object as? Message }
            .filter { !$0.isOutgoing && $0.chatId == self.chatId }
            .compactMap { message -> VoiceNote? in
                if case .messageVoiceNote(let content) = message.content {
                    return content.voiceNote
                }
                return nil
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] voiceNote in
                self?.handleIncomingVoice(voiceNote)
            }
            .store(in: &cancellables)
    }

    private func handleIncomingVoice(_ voiceNote: VoiceNote) {
        switch state {
        case .recording, .processing:
            // Queue it — don't interrupt user
            playbackQueue.append(voiceNote)
            print("📥 Queued bot voice message (\(playbackQueue.count) in queue)")

        case .listening:
            // Play immediately
            playbackQueue.append(voiceNote)
            playNext()

        case .idle:
            // Muted — play immediately
            if isMuted {
                playbackQueue.append(voiceNote)
                playNext()
            }

        case .playing:
            // Already playing — queue it
            playbackQueue.append(voiceNote)
            print("📥 Queued bot voice message (\(playbackQueue.count) in queue)")
        }
    }

    private func playNext() {
        guard !playbackQueue.isEmpty else {
            if !isMuted {
                state = .listening
            } else {
                state = .idle
            }
            return
        }

        let voiceNote = playbackQueue.removeFirst()
        state = .playing

        telegramService.downloadVoice(voiceNote) { [weak self] url in
            guard let self, let url else {
                // Download failed, skip to next
                self?.playNext()
                return
            }

            self.audioService.play(url: url)

            // Observe playback completion
            self.audioService.$isPlaying
                .dropFirst()
                .filter { !$0 }
                .first()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.playNext()
                }
                .store(in: &self.cancellables)
        }
    }
}
```

**Step 2: Regenerate Xcode project**

Run: `xcodegen generate`

**Step 3: Build and verify**

Run: build command
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Telegrowl/Services/VoiceChatService.swift
xcodegen generate
git add Telegrowl.xcodeproj/project.pbxproj project.yml
git commit -m "feat: add VoiceChatService with state machine, VAD, and message queue"
```

---

### Task 3: Add speech recognition for mute/unmute commands

Add SFSpeechRecognizer to VoiceChatService that runs in parallel with VAD, detecting "mute"/"unmute" keywords.

**Files:**
- Modify: `Telegrowl/Services/VoiceChatService.swift`

**Step 1: Add Speech import and properties**

Add at top of file:
```swift
import Speech
```

Add properties to VoiceChatService:
```swift
// MARK: - Speech Recognition
private var speechRecognizer: SFSpeechRecognizer?
private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
private var recognitionTask: SFSpeechRecognitionTask?
private var recognitionRestartTimer: Timer?
```

**Step 2: Add speech recognition methods**

```swift
// MARK: - Speech Recognition

private func startSpeechRecognition() {
    speechRecognizer = SFSpeechRecognizer()
    guard let speechRecognizer, speechRecognizer.isAvailable else {
        print("⚠️ Speech recognition not available")
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

            if text.contains(unmuteCmd) && self.isMuted {
                Task { @MainActor in
                    self.unmute()
                }
            } else if text.contains(muteCmd) && !self.isMuted {
                Task { @MainActor in
                    self.mute()
                }
            }
        }

        if error != nil {
            Task { @MainActor in
                self.restartSpeechRecognition()
            }
        }
    }

    // Schedule rolling restart every 50 seconds
    recognitionRestartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
        Task { @MainActor in
            self?.restartSpeechRecognition()
        }
    }

    print("🗣️ Speech recognition started")
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
    startSpeechRecognition()
    // Re-install tap feeding if engine is running
    // (the audio buffer tap in processAudioBuffer already feeds recognitionRequest)
}
```

**Step 3: Feed audio buffers to speech recognizer**

In `processAudioBuffer(_:)`, add at the very beginning:
```swift
recognitionRequest?.append(buffer)
```

**Step 4: Start/stop speech recognition with engine**

In `start(chatId:)`, after `observeIncomingMessages()` add:
```swift
startSpeechRecognition()
```

In `stop()`, before `state = .idle` add:
```swift
stopSpeechRecognition()
```

In `mute()` — speech recognition should keep running (listening for "unmute"), so do NOT stop it.

In `unmute()` — restart speech recognition to clear old buffer:
```swift
restartSpeechRecognition()
```

**Step 5: Add permission check**

```swift
static func requestPermissions() async -> Bool {
    // Microphone
    let micGranted = await AVAudioSession.sharedInstance().requestRecordPermission()

    // Speech recognition
    let speechGranted = await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { status in
            continuation.resume(returning: status == .authorized)
        }
    }

    return micGranted && speechGranted
}
```

Note: `AVAudioSession.requestRecordPermission()` async version requires iOS 17+, which is our minimum target.

**Step 6: Build and verify**

Run: build command
Expected: BUILD SUCCEEDED

**Step 7: Commit**

```bash
git add Telegrowl/Services/VoiceChatService.swift
git commit -m "feat: add speech recognition for mute/unmute voice commands"
```

---

### Task 4: Create VoiceChatView UI

Minimal full-screen view with state indicator, mute button, and leave button.

**Files:**
- Create: `Telegrowl/Views/VoiceChatView.swift`

**Step 1: Create the view**

```swift
import SwiftUI

struct VoiceChatView: View {
    @StateObject private var voiceChatService = VoiceChatService()
    @EnvironmentObject var telegramService: TelegramService
    @Environment(\.dismiss) var dismiss

    let chatId: Int64
    let chatTitle: String

    var body: some View {
        ZStack {
            Color(hex: "1a1a2e").ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer()
                stateVisual
                stateLabel
                    .padding(.top, 20)
                Spacer()
                muteButton
                    .padding(.bottom, 40)
            }
        }
        .onAppear {
            Task {
                let granted = await VoiceChatService.requestPermissions()
                if granted {
                    voiceChatService.start(chatId: chatId)
                } else {
                    dismiss()
                }
            }
        }
        .onDisappear {
            voiceChatService.stop()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Spacer()

            Text(chatTitle)
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)

            Spacer()
        }
        .overlay(alignment: .trailing) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .padding()
    }

    // MARK: - State Visual

    @ViewBuilder
    private var stateVisual: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(stateColor.opacity(0.15))
                .frame(width: 200, height: 200)

            // Inner circle with animation
            Circle()
                .fill(stateColor.opacity(0.3))
                .frame(width: innerCircleSize, height: innerCircleSize)
                .animation(.easeInOut(duration: 0.3), value: innerCircleSize)

            // Icon
            stateIcon
                .font(.system(size: 50))
                .foregroundColor(stateColor)
        }
    }

    private var innerCircleSize: CGFloat {
        switch voiceChatService.state {
        case .recording:
            // Pulse with audio level
            let normalized = max(0, min(1, (voiceChatService.audioLevel + 50) / 50))
            return 100 + CGFloat(normalized) * 60
        case .playing:
            return 130
        default:
            return 100
        }
    }

    private var stateColor: Color {
        if voiceChatService.isMuted {
            return .gray
        }
        switch voiceChatService.state {
        case .idle: return .gray
        case .listening: return .white
        case .recording: return TelegramTheme.recordingRed
        case .processing: return .white
        case .playing: return TelegramTheme.accent
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        if voiceChatService.isMuted {
            Image(systemName: "mic.slash.fill")
        } else {
            switch voiceChatService.state {
            case .idle:
                Image(systemName: "mic.slash.fill")
            case .listening:
                Image(systemName: "mic.fill")
            case .recording:
                Image(systemName: "waveform")
            case .processing:
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.5)
            case .playing:
                Image(systemName: "speaker.wave.3.fill")
            }
        }
    }

    // MARK: - State Label

    private var stateLabel: some View {
        Text(stateLabelText)
            .font(.title3)
            .fontWeight(.medium)
            .foregroundColor(.white.opacity(0.7))
    }

    private var stateLabelText: String {
        if voiceChatService.isMuted {
            return "Muted"
        }
        switch voiceChatService.state {
        case .idle: return "Muted"
        case .listening: return "Listening..."
        case .recording: return "Recording"
        case .processing: return "Sending..."
        case .playing: return "Bot is speaking"
        }
    }

    // MARK: - Mute Button

    private var muteButton: some View {
        Button(action: { voiceChatService.toggleMute() }) {
            HStack(spacing: 8) {
                Image(systemName: voiceChatService.isMuted ? "mic.slash.fill" : "mic.fill")
                Text(voiceChatService.isMuted ? "Unmute" : "Mute")
                    .fontWeight(.semibold)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 14)
            .background(voiceChatService.isMuted ? TelegramTheme.recordingRed : Color.white.opacity(0.2))
            .cornerRadius(25)
        }
    }
}
```

**Step 2: Regenerate Xcode project**

Run: `xcodegen generate`

**Step 3: Build and verify**

Run: build command
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Telegrowl/Views/VoiceChatView.swift
xcodegen generate
git add Telegrowl.xcodeproj/project.pbxproj
git commit -m "feat: add VoiceChatView with state visuals and mute button"
```

---

### Task 5: Wire up VoiceChatView entry point and remove driving mode

Replace driving mode with voice chat entry in the conversation toolbar. Remove all driving mode and hands-free references.

**Files:**
- Modify: `Telegrowl/Views/ContentView.swift`

**Step 1: Remove driving mode state and view**

Remove:
- `@State private var isDrivingMode = false` (line 10)
- The entire `if isDrivingMode` / `else` branch in `authenticatedView` — replace with just `navigationView`
- The entire `drivingModeView` computed property (lines 134-194)

The `authenticatedView` becomes:
```swift
private var authenticatedView: some View {
    navigationView
}
```

**Step 2: Replace car icon with voice chat button**

In `conversationDestination(chatId:)`, replace the toolbar item:

```swift
ToolbarItem(placement: .topBarTrailing) {
    Button(action: { isDrivingMode = true }) {
        Image(systemName: "car.fill")
            .foregroundColor(TelegramTheme.accent)
    }
}
```

With:

```swift
ToolbarItem(placement: .topBarTrailing) {
    NavigationLink(value: "voiceChat-\(chatId)") {
        Image(systemName: "waveform.circle.fill")
            .font(.system(size: 22))
            .foregroundColor(TelegramTheme.accent)
    }
}
```

**Step 3: Add navigation destination for VoiceChatView**

In `navigationView`, add a second `navigationDestination` for String:

```swift
.navigationDestination(for: String.self) { value in
    if value.hasPrefix("voiceChat-"),
       let chatId = Int64(value.replacingOccurrences(of: "voiceChat-", with: "")),
       let chat = telegramService.chats.first(where: { $0.id == chatId }) {
        VoiceChatView(chatId: chatId, chatTitle: chat.title)
            .navigationBarHidden(true)
    }
}
```

**Step 4: Update auth prompt text**

Change "Hands-free voice messaging for Telegram" to "Voice chat for Telegram"

**Step 5: Build and verify**

Run: build command
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add Telegrowl/Views/ContentView.swift
git commit -m "feat: replace driving mode with voice chat entry point"
```

---

### Task 6: Clean up SettingsView — remove driving mode, add voice chat settings

**Files:**
- Modify: `Telegrowl/Views/SettingsView.swift`

**Step 1: Remove driving section references**

Remove the `drivingSection` call from `body` Form, and the entire `drivingSection` computed property (lines 137-151), and the `DrivingModeInfo` struct (lines 199-226), and the `SiriShortcutsInfo` struct (lines 230-251).

**Step 2: Add voice chat section**

Add new state variables at top:
```swift
@State private var vadSensitivity = Config.vadSensitivity
@State private var muteCommand = Config.muteCommand
@State private var unmuteCommand = Config.unmuteCommand
```

Add new section after `audioSection`:
```swift
private var voiceChatSection: some View {
    Section {
        HStack {
            Text("VAD Sensitivity")
            Spacer()
            Picker("", selection: $vadSensitivity) {
                Text("Low").tag(0)
                Text("Medium").tag(1)
                Text("High").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }

        HStack {
            Text("Mute Command")
            Spacer()
            TextField("mute", text: $muteCommand)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .foregroundColor(TelegramTheme.textSecondary)
        }

        HStack {
            Text("Unmute Command")
            Spacer()
            TextField("unmute", text: $unmuteCommand)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .foregroundColor(TelegramTheme.textSecondary)
        }
    } header: {
        Text("Voice Chat")
    } footer: {
        Text("Voice commands to control mute/unmute during voice chat. VAD sensitivity controls how loud you need to speak to trigger recording.")
    }
}
```

Add `voiceChatSection` to the Form in `body`.

**Step 3: Update saveSettings()**

Add:
```swift
Config.vadSensitivity = vadSensitivity
Config.muteCommand = muteCommand
Config.unmuteCommand = unmuteCommand
```

**Step 4: Build and verify**

Run: build command
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add Telegrowl/Views/SettingsView.swift
git commit -m "feat: replace driving mode settings with voice chat settings"
```

---

### Task 7: Handle audio interruptions and edge cases

Add audio interruption handling (phone calls, Siri) to VoiceChatService.

**Files:**
- Modify: `Telegrowl/Services/VoiceChatService.swift`

**Step 1: Observe audio interruptions**

Add to `start(chatId:)`:
```swift
observeAudioInterruptions()
```

Add method:
```swift
private func observeAudioInterruptions() {
    NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            guard let self else { return }
            guard let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            switch type {
            case .began:
                print("🎧 Audio interruption began")
                if self.state == .recording {
                    self.discardRecording()
                }
                self.stopEngine()
                self.stopSpeechRecognition()
                self.isMuted = true
                self.state = .idle

            case .ended:
                print("🎧 Audio interruption ended")
                // Stay muted — user taps unmute to resume

            @unknown default:
                break
            }
        }
        .store(in: &cancellables)
}
```

**Step 2: Build and verify**

Run: build command
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Telegrowl/Services/VoiceChatService.swift
git commit -m "feat: handle audio interruptions in voice chat"
```

---

### Task 8: Regenerate Xcode project and final build

Ensure all new files are included and project builds cleanly.

**Files:**
- Modify: `project.yml` (if needed)
- Regenerate: `Telegrowl.xcodeproj`

**Step 1: Regenerate**

Run: `xcodegen generate`

**Step 2: Full build**

Run: build command
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
xcodegen generate
git add Telegrowl.xcodeproj/project.pbxproj
git commit -m "chore: regenerate Xcode project with voice chat files"
```

---

## Task Dependency Order

```
Task 1 (Config)
    ↓
Task 2 (VoiceChatService core)
    ↓
Task 3 (Speech recognition)
    ↓
Task 4 (VoiceChatView UI)
    ↓
Task 5 (Wire up + remove driving mode)
    ↓
Task 6 (Settings cleanup)
    ↓
Task 7 (Edge cases)
    ↓
Task 8 (Final build)
```

Each task builds and compiles independently. Commit after each task.

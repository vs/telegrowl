# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Telegrowl is a hands-free Telegram voice client for iOS, designed for drivers. It enables voice-based communication with Telegram AI bots through trigger-word dictation, manual recording, and typed text input. The app uses SwiftUI with iOS 17+ and TDLibKit for Telegram integration.

**Current Status:** TDLib integration complete, OGG/Opus encoding implemented, trigger-word dictation implemented, unified message send queue operational. Needs real-device testing.

## Build & Run

This is an Xcode-based Swift project using Swift Package Manager:

```bash
# Resolve dependencies
swift package resolve

# Open in Xcode
open Telegrowl.xcodeproj
```

- **Build:** Cmd+B in Xcode (iOS target only — `swift build` fails due to iOS-only APIs)
- **Run:** Cmd+R (requires iOS 17+ device/simulator)
- **Demo Mode:** Available in DEBUG builds — tap "Demo Mode" button to test UI without TDLib

**Prerequisites:**
1. Copy `Telegrowl/App/Config.swift.template` to `Config.swift` and fill in Telegram API credentials
2. Dependencies resolve automatically via SPM (TDLibKit, SwiftOGG)

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| [TDLibKit](https://github.com/Swiftgram/TDLibKit) | 1.5.2-tdlib-1.8.60 | TDLib Swift wrapper for Telegram API |
| [SwiftOGG](https://github.com/element-hq/swift-ogg) | 0.0.3 | M4A -> OGG/Opus conversion (uses libopus/libogg) |

## Architecture

```
TelegrowlApp (Entry)
    └── ContentView (Main UI Router)
            ├── AuthView (phone -> code -> 2FA flow)
            ├── ChatListView (chat selection)
            ├── ConversationDestination (per-chat wrapper)
            │       ├── ConversationView (message bubbles + waveforms)
            │       ├── InputBarView (text field + mic + dictation overlay)
            │       └── DictationService (trigger-word dictation, per-session)
            └── ToastView / ConnectionBanner (status overlays)

Services (Singletons, @MainActor):
    ├── TelegramService - TDLib client, auth state machine, chat/message management
    ├── AudioService - M4A recording, playback, silence detection, haptics
    ├── AudioConverter - M4A->OGG/Opus conversion, waveform generation, temp file cleanup
    └── MessageSendQueue - Persistent FIFO queue for text, voice, and voice+caption messages

Per-Session (@MainActor, NOT singleton):
    └── DictationService - Trigger-word detection, speech-to-text, voice recording, per-conversation
```

**Message Send Flow (all message types):**
1. All messages go through `MessageSendQueue` (text typed, text dictated, voice manual, voice dictated)
2. Text typed: user types in InputBarView text field -> `MessageSendQueue.enqueueText()`
3. Text dictated: user says "text hello" -> DictationService transcribes -> `MessageSendQueue.enqueueText()`
4. Voice manual: user taps mic in InputBarView -> AudioService records M4A -> AudioConverter -> `MessageSendQueue.enqueueVoice()`
5. Voice dictated: user says "voice hello" -> DictationService records + transcribes -> AudioConverter -> `MessageSendQueue.enqueueVoice()` with caption
6. Queue processes FIFO: sends via `TelegramService.sendTextMessage()` or `sendVoiceMessage()` (with optional caption)
7. On send failure: TDLib `resendMessages` if `canRetry`, otherwise exponential backoff retry
8. Queue persists to disk — survives app restart and connectivity loss

**Dictation Data Flow:**
1. ConversationDestination creates DictationService per chat via `@StateObject`
2. AVAudioEngine + SFSpeechRecognizer run continuously while conversation is open
3. In `idle` state: recognizer watches for trigger words only — everything else ignored
4. "text" or "text message" -> enters `dictating` state, captures speech-to-text
5. "voice" or "voice message" -> enters `recording` state, records audio AND transcribes (caption)
6. 3 seconds of no new recognized words = silence = command ends
7. For voice: audio trimmed to ~0.5s after last spoken word (removes trailing silence)
8. Converted OGG + transcript enqueued to MessageSendQueue
9. Incoming voice messages auto-play when idle, or queue for playback after current command

## Key Files

| Path | Purpose |
|------|---------|
| `Telegrowl/Services/TelegramService.swift` | TDLib client, auth states, chat/message management, photo downloads, sendTextMessage, sendVoiceMessage (with caption) |
| `Telegrowl/Services/AudioService.swift` | Recording, playback, silence detection |
| `Telegrowl/Services/AudioConverter.swift` | OGG/Opus conversion, waveform generation |
| `Telegrowl/Services/DictationService.swift` | Trigger-word detection, speech-to-text dictation, voice recording, audio trimming |
| `Telegrowl/Services/MessageSendQueue.swift` | Persistent FIFO send queue: text, voice, voice+caption with retry logic |
| `Telegrowl/Views/ContentView.swift` | Main UI router, NavigationStack, ConversationDestination wrapper, toast/connection overlays |
| `Telegrowl/Views/ConversationView.swift` | Message bubbles (text, voice, audio, photo, document), waveform display, voice playback |
| `Telegrowl/Views/InputBarView.swift` | Text field + send button, mic record button, dictation overlay with live transcription |
| `Telegrowl/Views/ToastView.swift` | Non-blocking toast banners with styles, spinner, retry |
| `Telegrowl/Views/AvatarView.swift` | Reusable avatar with photo download, minithumbnail blur, initials fallback |
| `Telegrowl/Views/ChatListView.swift` | Chat list with search, @username search |
| `Telegrowl/Views/AuthView.swift` | Phone -> code -> 2FA auth flow |
| `Telegrowl/Views/SettingsView.swift` | App settings (audio, account) |
| `Telegrowl/Views/BubbleShape.swift` | Telegram-style message bubble shape with tails |
| `Telegrowl/Views/TelegramTheme.swift` | Centralized theme constants (colors, sizes, fonts) |
| `Telegrowl/App/Config.swift.template` | API credentials + UserDefaults-backed settings (copy to Config.swift) |

## Implementation Notes

**TelegramService Auth States:** `waitTdlibParameters -> waitPhoneNumber -> waitCode -> waitPassword -> ready`

**Audio Pipeline:** Records M4A/AAC -> converts to OGG/Opus via SwiftOGG -> sends with waveform data via `sendVoiceMessage` (async throws, supports optional caption). Falls back to sending M4A if conversion fails.

**Waveform Generation:** AVFoundation PCM analysis — reads audio into AVAudioPCMBuffer, extracts peak amplitudes into 63 buckets (5-bit values 0-31) for Telegram-compatible waveform display.

**DictationService:**
- State machine: `idle -> dictating -> recording -> sending`
- Created per conversation via `@StateObject` in ConversationDestination (NOT a singleton)
- AVAudioEngine input tap feeds both SFSpeechRecognizer and optional AVAudioFile simultaneously
- Audio file writes happen synchronously on the audio thread (AVAudioPCMBuffer is NOT Sendable)
- `recognitionRequest` marked `nonisolated(unsafe)` — written on MainActor, `append()` called from audio thread (thread-safe)
- Speech recognition uses 50s rolling restart to avoid Apple's ~60s session limit
- Trigger words: "text message", "voice message", "text", "voice" (matched longest-first with word boundary awareness)
- Silence detection based on speech recognizer output stalling — 3s of no new recognized words = end of command (not dB-based)
- Audio trimming: voice recordings trimmed to ~0.5s after last spoken word via `AudioTrimmer`, removes the 3s silence gap
- Empty commands (trigger word with no content after) are silently discarded
- Audio interruptions (calls, Siri) cancel active dictation/recording
- Incoming voice messages auto-play when idle; queued during active dictation for sequential playback after

**MessageSendQueue:**
- Singleton `@MainActor` service, persisted to `Documents/send_queue/queue.json`
- Supports three message types: `.text`, `.voice`, `.voiceWithCaption`
- FIFO processing: sends one message at a time, processes next on success
- State machine per item: `pending -> sending -> awaitingConfirm -> (success | retryWait -> pending)`
- On failure: uses TDLib `resendMessages` if `canRetry`, otherwise fresh send with exponential backoff
- Connection-aware: pauses when disconnected, resumes on `connectionStateReady`
- Audio files moved into `send_queue/` directory for crash-safe persistence
- Loads persisted queue on app start, resets in-flight items to pending

**ConversationDestination:**
- Wraps ConversationView + InputBarView + DictationService for a single chat
- Created fresh per `NavigationStack` push via `.navigationDestination(for: Int64.self)`
- Owns DictationService lifecycle: starts on appear, stops on disappear
- Manual recording: tap mic -> AudioService records -> AudioConverter -> MessageSendQueue
- Text send: type in InputBarView -> MessageSendQueue.enqueueText()

**InputBarView:**
- Three visual states: normal (text field + mic/send), manual recording (duration + stop), dictation overlay (pulsing icon + live text + cancel)
- Normal state: text field with send button (when text present) or mic button (when empty)
- Dictation overlay shows live transcription and cancel button

**Notifications for Inter-Component Communication:**
- `.newVoiceMessage` - triggers auto-play in DictationService (or queues during active command)
- `.voiceDownloaded` - file ready for deferred playback
- `.messageSendSucceeded` - TDLib confirmed delivery, removes item from queue
- `.messageSendFailed` - TDLib send failed, triggers retry logic
- `.queueSendSucceeded` - queue item delivered, shows success toast in ContentView

**User Avatars:** `AvatarView` displays real Telegram profile photos in the chat list and settings. Uses a `TelegramPhoto` protocol to unify `ChatPhotoInfo` and `ProfilePhoto`. Three-state fallback: downloaded photo -> minithumbnail blur preview -> colored initials circle. Downloads via `TelegramService.downloadPhoto(file:)`, relying on TDLib's built-in file cache.

**Toast Status Feedback:** `ToastView` provides non-blocking banners with four styles (info/success/error/warning). `ToastData` supports a loading spinner and an optional Retry button. ContentView manages toast state and auto-dismiss (3s). Service errors are funneled via `.onChange(of: telegramService.error)`.

**Connection Banner:** `ConnectionBanner` shows a prominent overlay at the top of the screen when disconnected (waiting for network, connecting, updating). Displays queued message count when items are pending.

**Persistent Settings:** User preferences (auto-play, haptics, silence detection, durations) are backed by `UserDefaults` via computed properties on `Config`. Defaults are registered in `TelegrowlApp.init()` via `Config.registerDefaults()`. API credentials and TDLib paths remain compile-time constants. Dictation-specific settings: `speechLocale`, `dictationSilenceTimeout`.

**Debug Logging:** Uses print() with emoji prefixes (📱 Telegram, 🎙️ Audio, 🔄 Conversion, 📤 Send, 📥 Download, ❌ Error, 🗣️ Speech)

## Config.swift Template

Copy `Telegrowl/App/Config.swift.template` to `Config.swift` (gitignored for security). Get credentials at https://my.telegram.org/apps.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Telegrowl is a hands-free Telegram voice client for iOS, designed for drivers. It enables voice-based communication with Telegram AI bots through a one-tap recording interface. The app uses SwiftUI with iOS 17+ and TDLibKit for Telegram integration.

**Current Status:** TDLib integration complete, OGG/Opus encoding implemented. Needs real-device testing.

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
| [SwiftOGG](https://github.com/element-hq/swift-ogg) | 0.0.3 | M4A → OGG/Opus conversion (uses libopus/libogg) |

## Architecture

```
TelegrowlApp (Entry)
    └── ContentView (Main UI Router)
            ├── AuthView (phone → code → 2FA flow)
            ├── ChatListView (chat selection)
            ├── RecordButton (gesture-based, 150px circular button)
            ├── ConversationView (message bubbles + waveforms)
            └── ToastView (non-blocking status banners)

Services (Singletons, @MainActor):
    ├── TelegramService - TDLib client, auth state machine, chat/message management
    ├── AudioService - M4A recording, playback, silence detection, haptics
    └── AudioConverter - M4A→OGG/Opus conversion, waveform generation, temp file cleanup
```

**Data Flow:**
1. User holds RecordButton → AudioService records M4A
2. Release → AudioConverter converts M4A to OGG/Opus + generates waveform
3. OGG file + waveform passed to TelegramService.sendVoiceMessage() (async throws)
4. TDLib sends to Telegram, M4A temp file cleaned up
   - Toast status progression: "Converting audio..." → "Sending..." → "Voice message sent"
   - On conversion failure: M4A fallback with warning toast
   - On send failure: error toast with Retry button (reuses converted file)
5. Incoming voice messages trigger `.newVoiceMessage` notification → auto-play

## Key Files

| Path | Purpose |
|------|---------|
| `Telegrowl/Services/TelegramService.swift` | TDLib client, auth states, chat/message management, photo downloads (482 lines) |
| `Telegrowl/Services/AudioService.swift` | Recording, playback, silence detection (190 lines) |
| `Telegrowl/Services/AudioConverter.swift` | OGG/Opus conversion, waveform generation (106 lines) |
| `Telegrowl/Views/ContentView.swift` | Main UI coordinator, toast overlay, send flow (510 lines) |
| `Telegrowl/Views/ConversationView.swift` | Message bubbles, voice playback (230 lines) |
| `Telegrowl/Views/ToastView.swift` | Non-blocking toast banners with styles, spinner, retry (65 lines) |
| `Telegrowl/Views/AvatarView.swift` | Reusable avatar with photo download, minithumbnail blur, initials fallback (79 lines) |
| `Telegrowl/Views/ChatListView.swift` | Chat list with search (147 lines) |
| `Telegrowl/Views/AuthView.swift` | Phone → code → 2FA auth flow (150 lines) |
| `Telegrowl/Views/SettingsView.swift` | App settings (325 lines) |
| `Telegrowl/Views/RecordButton.swift` | Gesture-based recording button with animations (113 lines) |
| `Telegrowl/App/Config.swift.template` | API credentials + UserDefaults-backed settings (copy to Config.swift) |

## Implementation Notes

**TelegramService Auth States:** `waitTdlibParameters → waitPhoneNumber → waitCode → waitPassword → ready`

**Audio Pipeline:** Records M4A/AAC → converts to OGG/Opus via SwiftOGG → sends with waveform data via `sendVoiceMessage` (async throws). Falls back to sending M4A if conversion fails.

**Waveform Generation:** AVFoundation PCM analysis — reads audio into AVAudioPCMBuffer, extracts peak amplitudes into 63 buckets (5-bit values 0-31) for Telegram-compatible waveform display.

**Notifications for Inter-Component Communication:**
- `.newVoiceMessage` - triggers auto-play
- `.voiceDownloaded` - file ready for playback
- `.recordingAutoStopped` - silence detection triggered

**User Avatars:** `AvatarView` displays real Telegram profile photos in the chat list and settings. Uses a `TelegramPhoto` protocol to unify `ChatPhotoInfo` and `ProfilePhoto`. Three-state fallback: downloaded photo → minithumbnail blur preview → colored initials circle. Downloads via `TelegramService.downloadPhoto(file:)`, relying on TDLib's built-in file cache.

**Toast Status Feedback:** `ToastView` provides non-blocking banners with four styles (info/success/error/warning). `ToastData` supports a loading spinner and an optional Retry button. ContentView manages toast state and auto-dismiss (3s). Replaces the old blocking `.alert("Error")` modal — service errors are funneled via `.onChange(of: telegramService.error)`.

**Persistent Settings:** User preferences (auto-play, haptics, silence detection, durations, target chat) are backed by `UserDefaults` via computed properties on `Config`. Defaults are registered in `TelegrowlApp.init()` via `Config.registerDefaults()`. API credentials and TDLib paths remain compile-time constants.

**Debug Logging:** Uses print() with emoji prefixes (📱 Telegram, 🎙️ Audio, 🔄 Conversion, 📤 Send, 📥 Download, ❌ Error)

## Config.swift Template

Copy `Telegrowl/App/Config.swift.template` to `Config.swift` (gitignored for security). Get credentials at https://my.telegram.org/apps.

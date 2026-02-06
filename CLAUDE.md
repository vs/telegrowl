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
            └── ConversationView (message bubbles + waveforms)

Services (Singletons, @MainActor):
    ├── TelegramService - TDLib client, auth state machine, chat/message management
    ├── AudioService - M4A recording, playback, silence detection, haptics
    └── AudioConverter - M4A→OGG/Opus conversion, waveform generation, temp file cleanup
```

**Data Flow:**
1. User holds RecordButton → AudioService records M4A
2. Release → AudioConverter converts M4A to OGG/Opus + generates waveform
3. OGG file + waveform passed to TelegramService.sendVoiceMessage()
4. TDLib sends to Telegram, M4A temp file cleaned up
5. Incoming voice messages trigger `.newVoiceMessage` notification → auto-play

## Key Files

| Path | Purpose |
|------|---------|
| `Telegrowl/Services/TelegramService.swift` | TDLib client, auth states, chat/message management (465 lines) |
| `Telegrowl/Services/AudioService.swift` | Recording, playback, silence detection (190 lines) |
| `Telegrowl/Services/AudioConverter.swift` | OGG/Opus conversion, waveform generation (106 lines) |
| `Telegrowl/Views/ContentView.swift` | Main UI coordinator (412 lines) |
| `Telegrowl/Views/ConversationView.swift` | Message bubbles, voice playback (230 lines) |
| `Telegrowl/Views/ChatListView.swift` | Chat list with search (177 lines) |
| `Telegrowl/Views/AuthView.swift` | Phone → code → 2FA auth flow (150 lines) |
| `Telegrowl/Views/SettingsView.swift` | App settings (339 lines) |
| `Telegrowl/Views/RecordButton.swift` | Gesture-based recording button with animations (113 lines) |
| `Telegrowl/App/Config.swift.template` | API credentials template (copy to Config.swift) |

## Implementation Notes

**TelegramService Auth States:** `waitTdlibParameters → waitPhoneNumber → waitCode → waitPassword → ready`

**Audio Pipeline:** Records M4A/AAC → converts to OGG/Opus via SwiftOGG → sends with waveform data. Falls back to sending M4A if conversion fails.

**Waveform Generation:** AVFoundation PCM analysis — reads audio into AVAudioPCMBuffer, extracts peak amplitudes into 63 buckets (5-bit values 0-31) for Telegram-compatible waveform display.

**Notifications for Inter-Component Communication:**
- `.newVoiceMessage` - triggers auto-play
- `.voiceDownloaded` - file ready for playback
- `.recordingAutoStopped` - silence detection triggered

**Debug Logging:** Uses print() with emoji prefixes (📱 Telegram, 🎙️ Audio, 🔄 Conversion, 📤 Send, 📥 Download, ❌ Error)

## Config.swift Template

Copy `Telegrowl/App/Config.swift.template` to `Config.swift` (gitignored for security). Get credentials at https://my.telegram.org/apps.

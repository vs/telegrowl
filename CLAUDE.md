# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Telegrowl is a hands-free Telegram voice client for iOS, designed for drivers. It enables voice-based communication with Telegram AI bots through a one-tap recording interface. The app uses SwiftUI with iOS 17+ and requires TDLib for Telegram integration.

**Current Status:** MVP with UI complete; TDLib integration is stubbed out (all API calls are TODOs).

## Build & Run

This is an Xcode-based Swift project (no Makefile or npm scripts):

```bash
# Open in Xcode
open Telegrowl.xcodeproj
# Or create new project and add source files from Telegrowl/
```

- **Build:** Cmd+B in Xcode
- **Run:** Cmd+R (requires iOS 17+ device/simulator)
- **Demo Mode:** Available in DEBUG builds - tap "Demo Mode" button to test UI without TDLib

**Prerequisites:**
1. Create `Config.swift` with Telegram API credentials (see SETUP.md)
2. Install TDLib framework (TDLibKit via SPM or pre-built XCFramework)

## Architecture

```
TelegrowlApp (Entry)
    └── ContentView (Main UI Router)
            ├── AuthView (phone → code → 2FA flow)
            ├── RecordButton (gesture-based, 150px circular button)
            └── ConversationView (message bubbles + waveforms)

Services (Singletons, @MainActor):
    ├── TelegramService - Auth state machine, chat/message management, TDLib wrapper (TODO)
    └── AudioService - M4A recording, playback, silence detection, haptics
```

**Data Flow:**
1. User holds RecordButton → AudioService records M4A
2. Release → audio URL passed to TelegramService.sendVoiceMessage()
3. Message added optimistically to local array
4. (TODO) TDLib sends to Telegram
5. Response triggers `.newVoiceMessage` notification → auto-plays

## Key Files

| Path | Purpose |
|------|---------|
| `Telegrowl/Services/TelegramService.swift` | TDLib wrapper, auth states, message handling (456 lines) |
| `Telegrowl/Services/AudioService.swift` | Recording, playback, silence detection (194 lines) |
| `Telegrowl/Views/ContentView.swift` | Main UI coordinator (391 lines) |
| `Telegrowl/Views/RecordButton.swift` | Gesture-based recording button with animations |
| `Config.swift` | API credentials (in .gitignore, must create manually) |

## Implementation Notes

**TelegramService Auth States:** `initial → waitingPhoneNumber → waitingCode → waitingPassword → ready`

**Audio Format:** Currently records as M4A/AAC. Telegram requires Opus/OGG - conversion TODO.

**Notifications for Inter-Component Communication:**
- `.newVoiceMessage` - triggers auto-play
- `.voiceDownloaded` - file ready for playback
- `.recordingAutoStopped` - silence detection triggered

**Debug Logging:** Uses print() with emoji prefixes (📱 Telegram, 🎙️ Audio, 📤 Send, 📥 Download, ❌ Error)

## Critical TODOs

From AGENTS.md - required for production:
1. Integrate TDLib properly (all API calls are stubs)
2. Add OGG/Opus encoding (Telegram voice format requirement)
3. Implement actual message sending/receiving via TDLib
4. Handle voice message file downloads
5. Generate waveform data for visual display

## Config.swift Template

Must create this file (it's gitignored for security):

```swift
struct Config {
    static let telegramApiId: Int32 = YOUR_API_ID
    static let telegramApiHash = "YOUR_API_HASH"
    static var targetChatUsername: String = ""
    static var autoPlayResponses: Bool = true
    static var hapticFeedback: Bool = true
    static var silenceDetection: Bool = true
    static var silenceDuration: TimeInterval = 2.0
    static var maxRecordingDuration: TimeInterval = 60.0
}
```

Get credentials at https://my.telegram.org/apps

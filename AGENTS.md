# AGENTS.md - Telegrowl

## Project Overview

Telegrowl is a hands-free Telegram voice client for iOS, optimized for use while driving.

## Architecture

```
Telegrowl/
├── App/                    # App entry & config
├── Services/
│   ├── TelegramService     # TDLib wrapper for Telegram API
│   └── AudioService        # Recording & playback
├── Views/
│   ├── ContentView         # Main UI
│   ├── RecordButton        # Voice recording button
│   ├── AuthView            # Telegram login
│   └── SettingsView        # App settings
└── Resources/
    └── Info.plist          # Permissions
```

## Key Features

- **One-tap voice recording** - Hold to talk, release to send
- **Auto-play responses** - Voice messages play automatically
- **Silence detection** - Auto-stop when user stops talking
- **Background audio** - Works with screen off
- **CarPlay-friendly** - Minimal UI, large touch targets

## Setup Requirements

1. **Telegram API credentials** from https://my.telegram.org/apps
2. **TDLib framework** - Either:
   - TDLibKit via SPM
   - Pre-built TDLib.xcframework
   - Build from source: https://github.com/tdlib/td

## TODOs for Full Implementation

1. [ ] Integrate TDLib properly
2. [ ] Implement actual message sending
3. [ ] Handle voice message downloads
4. [ ] Add OGG/Opus encoding for Telegram
5. [ ] CarPlay support
6. [ ] Widget for quick access
7. [ ] Siri Shortcuts integration

## Voice Message Format

Telegram uses Opus codec in OGG container. For iOS:
1. Record as AAC/M4A
2. Convert to OGG/Opus using FFmpeg or opus-ios
3. Generate waveform data

## Testing

- Use Xcode Simulator for basic UI testing
- Physical device required for:
  - Audio recording
  - TDLib networking
  - Background audio

## Resources

- TDLib docs: https://core.telegram.org/tdlib
- TDLibKit: https://github.com/Swiftgram/TDLibKit
- Telegram API: https://core.telegram.org/api

# Telegrowl 🐯📢

Hands-free Telegram voice client for iOS. Talk to your AI assistant while driving.

![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![iOS](https://img.shields.io/badge/iOS-17.0+-blue)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

- 🎙️ One-tap voice recording
- 🔊 Auto-playback of voice responses
- 🚗 CarPlay-friendly minimal UI
- 🤖 Optimized for AI assistant conversations
- 📱 Background audio support

## Screenshots

Coming soon...

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Telegram API credentials (api_id, api_hash)
- TDLib framework (see SETUP.md)

## Setup

1. Get Telegram API credentials at https://my.telegram.org/apps
2. Clone the repo and open in Xcode
3. Add your credentials to `Config.swift`
4. Build and run

## Architecture

```
Telegrowl/
├── App/
│   ├── TelegrowlApp.swift       # App entry point
│   └── Config.swift             # API credentials
├── Services/
│   ├── TelegramService.swift    # TDLib wrapper
│   ├── AudioRecorder.swift      # Voice recording
│   └── AudioPlayer.swift        # Voice playback
├── Views/
│   ├── ContentView.swift        # Main UI
│   ├── ConversationView.swift   # Chat view
│   └── RecordButton.swift       # Big record button
└── Models/
    └── Message.swift            # Message model
```

## Usage

1. Open app
2. Login to Telegram (first time only)
3. Select chat with your AI bot
4. Tap and hold to record
5. Release to send
6. Voice responses play automatically

## For Driving

- Large touch targets
- Auto-play responses
- Minimal visual UI
- Works with CarPlay audio

## License

MIT

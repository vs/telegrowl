<p align="center">
  <img src="docs/assets/logo.png" width="128" height="128" alt="Telegrowl logo">
</p>

<h1 align="center">Telegrowl</h1>

<p align="center">
  <b>A hands-free Telegram voice client for iOS, built for talking to AI bots while you drive.</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-17%2B-blue" alt="iOS 17+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/SwiftUI-✓-informational" alt="SwiftUI">
  <img src="https://img.shields.io/badge/TDLib-1.8.60-2CA5E0" alt="TDLib 1.8.60">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache_2.0-green" alt="License: Apache 2.0"></a>
</p>

<p align="center">
  <img src="docs/screenshots/conversation.png" width="300" alt="A conversation with an AI assistant: text and voice messages with transcribed captions">
</p>

## Why

Telegram bots are a convenient front end for AI assistants, but the official
apps assume you're looking at the screen. Telegrowl is a small, focused
Telegram client where you **say a trigger word and talk**:

- Say **"text …"** and your speech is transcribed and sent as a text message.
- Say **"voice …"** and a voice message is recorded, trimmed, and sent with
  its transcript as a caption.
- Incoming voice replies **play automatically**.

Recognition runs continuously while a conversation is open. Nothing is sent
unless it starts with a trigger word, and messages are queued on disk, so a
dead zone on the road doesn't lose them.

> **Status:** personal project, not on the App Store. It works end to end
> against real Telegram accounts, but it has only been tested on a handful of
> devices. See [Disclaimer](#disclaimer).

## Features

- **Trigger-word dictation** — `text` / `text message` and `voice` /
  `voice message`, matched longest-first on word boundaries. A command ends
  after 3 seconds without new recognized words (based on recognizer output,
  not microphone level, so road noise doesn't keep it open).
- **Voice messages done properly** — M4A recorded, trimmed to ~0.5 s after the
  last spoken word, converted to OGG/Opus, and sent with a Telegram-format
  waveform and the transcript as caption.
- **Auto-play** of incoming voice messages; replies that arrive mid-command are
  queued and played afterwards.
- **Persistent send queue** — text and voice messages survive connectivity loss
  and app restarts, with FIFO ordering and exponential-backoff retry
  (2 s → 60 s).
- **Driving-friendly status** — a full-width banner when the connection drops,
  with the number of messages waiting to send.
- **Telegram-style UI** — chat list with avatars and search (including
  `@username` lookup), message bubbles for text, voice, audio and documents
  (photos show as placeholders), and a text field for typing when you're
  parked.
- **Robust speech recognition** — on-device when available with server
  fallback, rolling restarts before Apple's ~60 s session limit, health checks,
  and recovery after calls or Siri interrupt audio.
- **Bluetooth / CarPlay audio** — the input tap follows the hardware sample
  rate, so car hands-free profiles (e.g. 24 kHz HFP) work.

## Screenshots

| Chats | Dictating a text | Recording a voice message | Settings |
|:---:|:---:|:---:|:---:|
| <img src="docs/screenshots/chats.png" width="200" alt="Chat list"> | <img src="docs/screenshots/dictation.png" width="200" alt="Dictation overlay with live transcription"> | <img src="docs/screenshots/voice.png" width="200" alt="Voice recording overlay"> | <img src="docs/screenshots/settings.png" width="200" alt="Settings"> |

All screenshots use fictional data from [Demo Mode](#demo-mode) and are
reproducible with `scripts/screenshots/capture.sh`.

## Quick start

**Requirements:** macOS with Xcode 16 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), an iOS 17+ device or simulator, and Telegram API
credentials. Dictation and voice recording need a real device with a
microphone; the simulator is fine for the UI.

```bash
git clone https://github.com/vs/telegrowl.git
cd telegrowl

# 1. Telegram API credentials (get them at https://my.telegram.org/apps)
cp Telegrowl/App/Config.swift.template Telegrowl/App/Config.swift
#    then set telegramApiId and telegramApiHash in Config.swift

# 2. Code signing (only needed for real devices)
cp Configs/Signing.local.xcconfig.template Configs/Signing.local.xcconfig
#    then set DEVELOPMENT_TEAM to your Apple Team ID

# 3. Generate the Xcode project and open it
xcodegen generate
open Telegrowl.xcodeproj
```

Select the **Telegrowl** scheme and run (⌘R). Swift Package Manager fetches
TDLibKit and SwiftOGG on the first build. Both `Config.swift` and
`Signing.local.xcconfig` are gitignored.

More detail, including troubleshooting, is in [docs/setup.md](docs/setup.md).

### Demo Mode

Debug builds can run without TDLib or a Telegram account:

```bash
xcrun simctl launch booted com.telegrowl.Telegrowl -demo
```

With `-demo` the welcome screen shows a **Demo Mode** button. Set
`TELEGROWL_DEMO_FIXTURES` to a JSON file (for example
[`scripts/screenshots/fixtures/demo.json`](scripts/screenshots/fixtures/demo.json))
to populate chats and messages; the other `TELEGROWL_DEMO_*` switches are
documented in [`DemoFixtures.swift`](Telegrowl/Services/DemoFixtures.swift).
Demo Mode never starts TDLib, so it makes no network requests.

## Configuration

There are no environment variables. Credentials are compile-time constants in
the gitignored `Config.swift`; user preferences are stored in `UserDefaults`
with defaults registered at launch.

| Setting | Where | Default | Used by |
|---|---|---|---|
| `telegramApiId` | `Config.swift` (required) | `0` | TDLib parameters |
| `telegramApiHash` | `Config.swift` (required) | `""` | TDLib parameters |
| `tdlibDatabasePath` | `Config.swift` | `Documents/tdlib` | TDLib database |
| `tdlibFilesPath` | `Config.swift` | `Documents/tdlib_files` | TDLib downloads |
| `DEVELOPMENT_TEAM` | `Configs/Signing.local.xcconfig` | empty | Code signing |
| Auto-play Responses | Settings screen | on | Auto-play of incoming voice |
| Haptic Feedback | Settings screen | on | Recording and dictation haptics |
| Silence Detection | Settings screen | on | Auto-stop for **manual** recordings |
| Stop after silence | Settings screen | 2 s | Manual recordings |
| Max Recording | Settings screen | 1 min | Manual recordings |
| `silenceThreshold` | `UserDefaults` only | −45 dB | Manual-recording silence level |
| `speechLocale` | `UserDefaults` only | `en-US` | Speech recognizer locale |
| `dictationSilenceTimeout` | `UserDefaults` only | 3 s | End of a dictated command |

Settings marked "`UserDefaults` only" have no UI yet; change their defaults in
`Config.registerDefaults()`.

## Architecture

```
TelegrowlApp
└── ContentView                 navigation, toasts, connection banner
    ├── AuthView                phone → code → 2FA
    ├── ChatListView            chats, search, settings
    └── ConversationDestination one per open chat
        ├── ConversationView    message bubbles, waveforms, playback
        ├── InputBarView        text field, mic, dictation overlay
        └── DictationService    trigger words, speech-to-text, recording

Singleton services (@MainActor)
├── TelegramService    TDLib client, auth state machine, chats, messages, files
├── AudioService       manual recording, playback, silence detection, haptics
├── AudioConverter     M4A → OGG/Opus, waveform generation
└── MessageSendQueue   persistent FIFO queue for text and voice messages
```

Every outgoing message, typed or dictated, text or voice, goes through
`MessageSendQueue`, which is persisted to `Documents/send_queue/queue.json`.
A failed send is retried with TDLib's `resendMessages` when possible, and
otherwise re-sent with exponential backoff. The queue pauses while offline.

`DictationService` runs one `AVAudioEngine` input tap that feeds both
`SFSpeechRecognizer` and, while recording, an `AVAudioFile`. In `idle` it only
looks for trigger words; after `text` or `voice` it captures until the
recognizer has produced nothing new for the silence timeout.

[CLAUDE.md](CLAUDE.md) has a more detailed walkthrough of the data flow and
implementation notes.

## Development

- **Project file:** `Telegrowl.xcodeproj` is generated from
  [`project.yml`](project.yml). Run `xcodegen generate` after adding or removing
  files and commit the regenerated project.
- **Build from the command line:**
  ```bash
  xcodebuild -scheme Telegrowl \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
  ```
  `swift build` does not work because the app uses iOS-only frameworks;
  `Package.swift` exists only to resolve dependencies.
- **Tests:** there is no automated test suite yet. Changes are verified by
  building and by running on a device.
- **Screenshots:** `scripts/screenshots/capture.sh` builds the app, launches it
  in Demo Mode on a simulator with a fixed status bar, and writes
  `docs/screenshots/*.png`.
- **Logging:** `print()` with emoji prefixes: 📱 Telegram, 🎙️ Audio,
  🔄 Conversion, 📤 Send, 📥 Download, 🗣️ Speech, ❌ Error.

## Documentation

| Document | Contents |
|---|---|
| [docs/setup.md](docs/setup.md) | Detailed setup, signing, and troubleshooting |
| [CLAUDE.md](CLAUDE.md) | Architecture and implementation notes (also used by AI coding agents) |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute, conventions, and the leak guard |
| [SECURITY.md](SECURITY.md) | Reporting vulnerabilities and the security model |
| [docs/plans/](docs/plans/) | Historical design docs for the voice chat and voice control modes, which were later replaced by trigger-word dictation |

## Contributing

Issues and pull requests are welcome. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) first; in particular, never commit your
`Config.swift`, Team ID, or anything from a real Telegram account.

## Disclaimer

- **Driving safety comes first.** Telegrowl is designed to reduce screen
  interaction, not to make it safe to use a phone while driving. Obey local
  laws, and don't look at or touch the screen while the vehicle is moving.
- **Unofficial client.** Telegrowl is an independent project, not affiliated
  with or endorsed by Telegram. It uses the official
  [TDLib](https://core.telegram.org/tdlib) library, and you must use your own
  API credentials in line with the
  [Telegram API Terms of Service](https://core.telegram.org/api/terms).
- **Your account, your data.** The app signs in to your real Telegram account
  and stores its session and caches on your device. Speech recognition may use
  Apple's servers when on-device recognition isn't available.
- Provided "as is", without warranty of any kind; see the license.

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE)
for attributions.

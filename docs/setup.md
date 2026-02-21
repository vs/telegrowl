# Setup

This guide covers building Telegrowl from source and running it on a
simulator or device. The [README](../README.md#quick-start) has the short
version.

## Requirements

- macOS with **Xcode 16 or later**
- **XcodeGen**: `brew install xcodegen`
- An **iOS 17+** simulator or device. Dictation and voice recording need a real
  microphone and speech recognition, so use a device for anything beyond the UI.
- **Telegram API credentials** (`api_id` and `api_hash`)
- For devices: an Apple ID signed in to Xcode (a free personal team is enough)

TDLib is not installed separately. It comes prebuilt through the
[TDLibKit](https://github.com/Swiftgram/TDLibKit) Swift package.

## 1. Get Telegram API credentials

1. Sign in at <https://my.telegram.org/apps> with your phone number.
2. Create an application (any name and platform).
3. Note the **App api_id** (a number) and **App api_hash** (a 32-character hex
   string).

These identify your build of the app to Telegram. Keep them private: don't
commit them, paste them into issues, or share screenshots that show them.

## 2. Create `Config.swift`

```bash
cp Telegrowl/App/Config.swift.template Telegrowl/App/Config.swift
```

Edit the two constants at the top:

```swift
static let telegramApiId: Int = 1234567           // your api_id
static let telegramApiHash = "0123456789abcdef…"  // your api_hash
```

`Config.swift` is gitignored. It also holds the `UserDefaults`-backed
settings, so when the template changes (for example, a new setting is added),
copy it again and re-enter your credentials.

## 3. Set up code signing (devices only)

Simulator builds don't need a team. For a device:

```bash
cp Configs/Signing.local.xcconfig.template Configs/Signing.local.xcconfig
```

Set `DEVELOPMENT_TEAM` to your 10-character Apple Team ID. You can find it in
Xcode → Settings → Accounts, or on the Membership page at
<https://developer.apple.com/account>. The file is gitignored and is included
by `Configs/Signing.xcconfig` only if it exists.

With a free personal team, change the bundle identifier prefix
(`bundleIdPrefix` in `project.yml`) to something unique if Xcode reports that
`com.telegrowl.Telegrowl` is unavailable.

## 4. Generate the project and build

```bash
xcodegen generate
open Telegrowl.xcodeproj
```

Choose the **Telegrowl** scheme and a destination, then run (⌘R). The first
build downloads the Swift packages, including a prebuilt TDLib framework
(about 1.3 GB unpacked, covering all Apple platforms).

From the command line:

```bash
xcodebuild -scheme Telegrowl \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Use any simulator listed by `xcrun simctl list devices available`.

## 5. First run

1. Tap **Start Messaging** and sign in with your phone number, the code
   Telegram sends you, and your 2FA password if you have one.
2. Allow **microphone** and **speech recognition** access when you open a chat.
3. Open the chat with your bot. Say "text, what's the weather tomorrow" or
   "voice, remind me to call the garage", then pause for 3 seconds.

## Demo Mode

Debug builds launched with `-demo` skip TDLib entirely:

```bash
xcrun simctl launch booted com.telegrowl.Telegrowl -demo
```

To see fictional chats, pass fixtures through the environment. `simctl`
forwards variables prefixed with `SIMCTL_CHILD_`:

```bash
SIMCTL_CHILD_TELEGROWL_DEMO_FIXTURES="$PWD/scripts/screenshots/fixtures/demo.json" \
SIMCTL_CHILD_TELEGROWL_DEMO_AUTOLOGIN=1 \
  xcrun simctl launch booted com.telegrowl.Telegrowl -demo
```

In Xcode, add the same variables (without the `SIMCTL_CHILD_` prefix) and the
`-demo` argument under *Edit Scheme → Run → Arguments*.

## Troubleshooting

**Stuck on "Connecting…" or "Waiting for network"**
TDLib needs to be told about network changes. The app does this with
`NWPathMonitor`, so check that the device has connectivity and that no VPN
blocks Telegram.

**Login fails immediately**
Check `telegramApiId` and `telegramApiHash` in `Config.swift`. `API_ID_INVALID`
means the pair doesn't match.

**Trigger words never fire**
Look for the ear icon and "last heard" text above the input bar. If it's
missing, speech recognition isn't running: check the permissions in iOS
Settings → Privacy. If the on-device model for your locale isn't downloaded,
the app falls back to server recognition, which needs a network connection.

**Crash or silence with Bluetooth or car audio**
Hands-free profiles run at low sample rates (for example 24 kHz). The input
tap uses the hardware format, so if this regresses, check
`DictationService.startEngine()` first.

**`swift build` fails**
This is expected. The app uses iOS-only frameworks; build with Xcode or
`xcodebuild`.

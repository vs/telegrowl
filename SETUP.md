# Telegrowl Setup Guide

## Quick Start

### 1. Get Telegram API Credentials

1. Go to https://my.telegram.org/apps
2. Login with your phone number
3. Create a new application
4. Note your `api_id` (number) and `api_hash` (string)

### 2. Clone and Open in Xcode

```bash
git clone https://github.com/vs/telegrowl.git
cd telegrowl
open Telegrowl.xcodeproj  # or create new project
```

### 3. Add Your Credentials

Edit `Telegrowl/App/Config.swift`:

```swift
static let telegramApiId: Int32 = YOUR_API_ID
static let telegramApiHash = "YOUR_API_HASH"
```

### 4. Add TDLib Framework

#### Option A: TDLibKit (Recommended)

Add to your Swift Package dependencies:
```swift
.package(url: "https://github.com/Swiftgram/TDLibKit.git", from: "3.0.0")
```

#### Option B: Pre-built Framework

1. Download TDLib.xcframework from:
   - https://github.com/nicegram/nicegram-tdlib-builder/releases
   - or build from source: https://github.com/nicegram/nicegram-tdlib-builder

2. Add to Xcode:
   - Drag `TDLib.xcframework` to your project
   - Ensure it's added to "Frameworks, Libraries, and Embedded Content"
   - Set "Embed & Sign"

### 5. Build and Run

1. Select your device (real device recommended for audio)
2. Build and run (⌘R)
3. Grant microphone permission when prompted
4. Login with your Telegram account

## Creating Xcode Project

If you're creating a fresh Xcode project:

1. File → New → Project
2. iOS → App
3. Product Name: Telegrowl
4. Interface: SwiftUI
5. Language: Swift
6. Add all files from the `Telegrowl/` folder
7. Set deployment target to iOS 17.0

### Required Capabilities

In Xcode, go to your target → Signing & Capabilities:
- Background Modes → Audio, AirPlay, and Picture in Picture
- (Optional) Siri → For future Siri Shortcuts support

### Info.plist Permissions

Make sure these are in your Info.plist:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>Telegrowl needs microphone access to record voice messages</string>

<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

## Testing

### Demo Mode (Without TDLib)

The app includes a demo mode for testing UI without TDLib:
1. Build and run
2. Tap "Demo Mode" button
3. You can now test recording and UI

### With TDLib

1. Complete setup steps above
2. Run on physical device
3. Login with your real Telegram account
4. Select a chat and start talking!

## Troubleshooting

### "No audio recorded"
- Check microphone permission in Settings
- Make sure you're not on Simulator (use real device)

### TDLib crashes
- Make sure you're using correct architecture (arm64)
- Check TDLib version compatibility

### Can't login
- Verify api_id and api_hash are correct
- Check network connection
- Try different auth method if 2FA fails

## Architecture

```
┌─────────────────────────────────────────────┐
│                ContentView                   │
│  ┌─────────────────────────────────────────┐│
│  │           RecordButton                  ││
│  │   (Hold to talk, release to send)       ││
│  └─────────────────────────────────────────┘│
│                                             │
│  ┌──────────────┐    ┌──────────────────┐  │
│  │ AudioService │    │ TelegramService  │  │
│  │ - Recording  │    │ - TDLib wrapper  │  │
│  │ - Playback   │    │ - Messages       │  │
│  │ - Waveform   │    │ - Auth           │  │
│  └──────────────┘    └──────────────────┘  │
└─────────────────────────────────────────────┘
```

## Next Steps

After basic setup works:
1. Add more chat selection features
2. Implement OGG/Opus encoding for smaller files
3. Add CarPlay support
4. Add Siri Shortcuts
5. Add Watch app

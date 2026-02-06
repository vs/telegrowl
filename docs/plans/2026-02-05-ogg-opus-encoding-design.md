# OGG/Opus Encoding Design

## Overview

Convert recorded M4A/AAC audio to OGG/Opus format required by Telegram voice messages, plus generate waveform visualization data.

## Decisions

| Decision | Choice |
|----------|--------|
| Conversion library | SwiftOGG (element-hq/swift-ogg) - lightweight M4A↔OGG/Opus converter using libopus/libogg |
| When to convert | After recording stops, before sending |
| Waveform generation | Yes, 63 bytes via AVFoundation PCM analysis |

**Note:** Originally planned FFmpegKit, but arthenica/ffmpeg-kit was archived June 2025. SwiftOGG is purpose-built for exactly this conversion and much lighter weight.

## Dependencies

**SwiftOGG via SPM:**
```swift
// Package.swift
.package(url: "https://github.com/element-hq/swift-ogg.git", from: "0.0.3")

// Target dependency
.product(name: "SwiftOGG", package: "swift-ogg")
```

Transitive dependencies: opus-swift (0.8.4), ogg-swift (0.8.3) - provides libopus/libogg XCFrameworks.

## Architecture

**New file:**
```
Telegrowl/Services/AudioConverter.swift
```

**Data flow:**
1. User releases record button
2. `stopRecording()` returns M4A URL
3. `AudioConverter.convertToOpus()` creates OGG + waveform
4. `sendVoiceMessage()` sends OGG to Telegram
5. Cleanup temp files

## AudioConverter Implementation

```swift
import Foundation
import AVFoundation
import SwiftOGG

enum ConversionError: Error {
    case inputFileNotFound
    case conversionFailed(Error)
}

class AudioConverter {

    /// Converts M4A to OGG/Opus format for Telegram
    /// Returns tuple of (outputURL, waveformData)
    static func convertToOpus(inputURL: URL) async throws -> (URL, Data) {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputFileNotFound
        }

        let outputURL = inputURL
            .deletingPathExtension()
            .appendingPathExtension("ogg")

        do {
            try OGGConverter.convertM4aFileToOpusOGG(src: inputURL, dest: outputURL)
        } catch {
            throw ConversionError.conversionFailed(error)
        }

        let waveform = generateWaveform(from: inputURL)
        return (outputURL, waveform)
    }

    /// Generates Telegram-compatible waveform (63 bytes, 5-bit values 0-31)
    /// Uses AVFoundation to read PCM samples and extract peak levels
    static func generateWaveform(from url: URL) -> Data {
        // Read audio file into PCM buffer
        // Extract peak amplitude per bucket (63 buckets)
        // Convert 0.0-1.0 amplitude to 0-31 (5-bit value)
        // Fallback: random placeholder waveform if analysis fails
    }

    /// Cleanup temporary audio files older than 1 hour
    static func cleanupTempFiles() { ... }
}
```

## Integration Points

**ContentView.sendRecording():**
```swift
private func sendRecording() {
    guard let m4aURL = audioService.stopRecording() else { return }

    let duration = Int(audioService.recordingDuration)
    guard duration > 0 else { return }

    Task {
        do {
            let (oggURL, waveform) = try await AudioConverter.convertToOpus(inputURL: m4aURL)

            telegramService.sendVoiceMessage(
                audioURL: oggURL,
                duration: duration,
                waveform: waveform
            )

            try? FileManager.default.removeItem(at: m4aURL)

        } catch {
            print("❌ Conversion failed: \(error)")
            // Fallback: send M4A anyway
            telegramService.sendVoiceMessage(
                audioURL: m4aURL,
                duration: duration,
                waveform: nil
            )
        }
    }
}
```

**TelegrowlApp.swift - cleanup on launch:**
```swift
AudioConverter.cleanupTempFiles()
```

## Error Handling

| Scenario | Fallback |
|----------|----------|
| OGGConverter fails | Send M4A anyway (Telegram may accept) |
| Waveform generation fails | Send with placeholder waveform |
| Temp file cleanup fails | Ignore, try again next launch |

## Files Modified

| File | Changes |
|------|---------|
| `Package.swift` | Add swift-ogg dependency |
| `AudioConverter.swift` | New file - conversion + waveform |
| `AudioService.swift` | Remove unused generateWaveform stub |
| `ContentView.swift` | Update sendRecording() for async conversion |
| `TelegrowlApp.swift` | Add cleanup call on launch |

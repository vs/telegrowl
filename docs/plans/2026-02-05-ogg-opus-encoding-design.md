# OGG/Opus Encoding Design

## Overview

Convert recorded M4A/AAC audio to OGG/Opus format required by Telegram voice messages, plus generate waveform visualization data.

## Decisions

| Decision | Choice |
|----------|--------|
| Conversion library | FFmpegKit (audio variant) |
| When to convert | After recording stops, before sending |
| Waveform generation | Yes, 63 bytes via FFmpeg audio analysis |

## Dependencies

**FFmpegKit via SPM:**
```swift
// Package.swift
.package(url: "https://github.com/arthenica/ffmpeg-kit.git", from: "6.0.0")

// Target dependency - use audio-only variant (~15MB)
"ffmpeg-kit-ios-audio"
```

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
import ffmpegkit

enum ConversionError: Error {
    case ffmpegFailed
    case inputFileNotFound
    case outputWriteFailed
}

class AudioConverter {

    /// Converts M4A to OGG/Opus format for Telegram
    /// Returns tuple of (outputURL, waveformData)
    static func convertToOpus(inputURL: URL) async throws -> (URL, Data) {
        let outputURL = inputURL
            .deletingPathExtension()
            .appendingPathExtension("ogg")

        // FFmpeg command for Telegram-compatible voice
        let command = """
            -i "\(inputURL.path)" \
            -c:a libopus \
            -b:a 32k \
            -vbr on \
            -application voip \
            -ar 48000 \
            -ac 1 \
            -y "\(outputURL.path)"
            """

        return try await withCheckedThrowingContinuation { continuation in
            FFmpegKit.executeAsync(command) { session in
                if session?.getReturnCode()?.isValueSuccess() == true {
                    let waveform = Self.generateWaveform(from: outputURL)
                    continuation.resume(returning: (outputURL, waveform))
                } else {
                    continuation.resume(throwing: ConversionError.ffmpegFailed)
                }
            }
        }
    }

    /// Generates Telegram-compatible waveform (63 bytes, 5-bit values)
    static func generateWaveform(from url: URL) -> Data {
        var samples: [UInt8] = []

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("levels.txt")

        let command = """
            -i "\(url.path)" \
            -af "astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.Peak_level:file=\(tempFile.path)" \
            -f null -
            """

        let session = FFmpegKit.execute(command)

        if session?.getReturnCode()?.isValueSuccess() == true,
           let data = try? String(contentsOf: tempFile) {
            let levels = parseLevels(data)
            samples = downsample(levels, to: 63)
        }

        // Fallback: generate placeholder waveform if extraction fails
        if samples.isEmpty {
            samples = (0..<63).map { _ in UInt8.random(in: 8...24) }
        }

        try? FileManager.default.removeItem(at: tempFile)
        return Data(samples)
    }

    private static func parseLevels(_ data: String) -> [Float] {
        // Parse FFmpeg astats output for peak levels
        data.components(separatedBy: .newlines)
            .compactMap { line -> Float? in
                guard line.contains("Peak_level") else { return nil }
                let parts = line.components(separatedBy: "=")
                guard parts.count >= 2 else { return nil }
                return Float(parts[1].trimmingCharacters(in: .whitespaces))
            }
    }

    private static func downsample(_ input: [Float], to count: Int) -> [UInt8] {
        guard !input.isEmpty else { return [] }
        let chunkSize = max(1, input.count / count)

        return (0..<count).map { i in
            let start = i * chunkSize
            let end = min(start + chunkSize, input.count)
            let avg = input[start..<end].reduce(0, +) / Float(end - start)
            // Convert dB to 0-31 range (5-bit value)
            let normalized = (avg + 60) / 60  // -60dB to 0dB → 0 to 1
            return UInt8(min(31, max(0, normalized * 31)))
        }
    }

    /// Cleanup temporary audio files older than 1 hour
    static func cleanupTempFiles() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileManager = FileManager.default

        guard let files = try? fileManager.contentsOfDirectory(
            at: documentsPath,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-3600)

        for file in files where file.pathExtension == "m4a" || file.pathExtension == "ogg" {
            if let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
               created < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
```

## FFmpeg Flags Explained

| Flag | Purpose |
|------|---------|
| `-c:a libopus` | Use Opus audio codec |
| `-b:a 32k` | 32kbps bitrate (good for voice) |
| `-vbr on` | Variable bitrate for efficiency |
| `-application voip` | Optimize for speech |
| `-ar 48000` | 48kHz sample rate (Telegram standard) |
| `-ac 1` | Mono audio |
| `-y` | Overwrite output file |

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
| FFmpegKit fails | Send M4A anyway (Telegram may accept) |
| Waveform generation fails | Send with nil waveform (flat line display) |
| Temp file cleanup fails | Ignore, try again next launch |

## Files to Modify

| File | Changes |
|------|---------|
| `Package.swift` | Add ffmpeg-kit-ios-audio dependency |
| `AudioConverter.swift` | New file - conversion + waveform |
| `ContentView.swift` | Update sendRecording() for async conversion |
| `TelegrowlApp.swift` | Add cleanup call on launch |

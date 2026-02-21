import Foundation
import AVFoundation
import SwiftOGG

enum ConversionError: Error {
    case inputFileNotFound
    case conversionFailed(Error)
}

class AudioConverter {

    /// Converts M4A to OGG/Opus format for Telegram voice messages.
    /// Returns tuple of (outputURL, waveformData).
    static func convertToOpus(inputURL: URL) async throws -> (URL, Data) {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputFileNotFound
        }

        let outputURL = inputURL
            .deletingPathExtension()
            .appendingPathExtension("ogg")

        do {
            try OGGConverter.convertM4aFileToOpusOGG(src: inputURL, dest: outputURL)
            print("🔄 Converted to OGG/Opus: \(outputURL.lastPathComponent)")
        } catch {
            throw ConversionError.conversionFailed(error)
        }

        // Verify the output file actually exists
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            print("❌ OGG file not found after conversion at: \(outputURL.path)")
            throw ConversionError.inputFileNotFound
        }

        let waveform = generateWaveform(from: inputURL)
        // Return standardized URL to avoid /private prefix issues with TDLib's realpath()
        return (outputURL.standardizedFileURL, waveform)
    }

    /// Generates Telegram-compatible waveform data: 63 5-bit values (0-31), bit-packed.
    /// Analyzes audio levels from the source file using AVFoundation.
    static func generateWaveform(from url: URL) -> Data {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat
            let frameCount = AVAudioFrameCount(audioFile.length)

            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                return placeholderWaveform()
            }

            try audioFile.read(into: buffer)

            guard let channelData = buffer.floatChannelData?[0] else {
                return placeholderWaveform()
            }

            let samples = extractPeakLevels(channelData, frameCount: Int(frameCount), buckets: 63)
            return Waveform.pack(samples)
        } catch {
            print("❌ Waveform generation failed: \(error)")
            return placeholderWaveform()
        }
    }

    /// Extracts peak amplitude levels from audio samples, downsampled to the given number of buckets.
    private static func extractPeakLevels(_ data: UnsafePointer<Float>, frameCount: Int, buckets: Int) -> [UInt8] {
        let chunkSize = max(1, frameCount / buckets)

        return (0..<buckets).map { i in
            let start = i * chunkSize
            let end = min(start + chunkSize, frameCount)

            var peak: Float = 0
            for j in start..<end {
                let sample = abs(data[j])
                if sample > peak {
                    peak = sample
                }
            }

            // Convert 0.0-1.0 amplitude to 0-31 (5-bit value)
            return UInt8(min(31, max(0, Int(peak * 31))))
        }
    }

    private static func placeholderWaveform() -> Data {
        Waveform.pack((0..<63).map { _ in UInt8.random(in: 8...24) })
    }

    /// Cleanup temporary audio files older than 1 hour.
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
                print("🧹 Cleaned up: \(file.lastPathComponent)")
            }
        }
    }
}

// MARK: - Waveform Packing

/// Telegram stores voice note waveforms as a stream of 5-bit values (0-31),
/// packed least-significant bit first.
enum Waveform {
    static func pack(_ values: [UInt8]) -> Data {
        var bytes = [UInt8](repeating: 0, count: (values.count * 5 + 7) / 8)
        for (index, value) in values.enumerated() {
            let bitOffset = index * 5
            let packed = UInt16(min(value, 31)) << (bitOffset % 8)
            bytes[bitOffset / 8] |= UInt8(packed & 0xFF)
            if bitOffset / 8 + 1 < bytes.count {
                bytes[bitOffset / 8 + 1] |= UInt8(packed >> 8)
            }
        }
        return Data(bytes)
    }

    static func unpack(_ data: Data) -> [UInt8] {
        let bytes = [UInt8](data)
        return (0..<(bytes.count * 8 / 5)).map { index in
            let bitOffset = index * 5
            let low = UInt16(bytes[bitOffset / 8])
            let high = bitOffset / 8 + 1 < bytes.count ? UInt16(bytes[bitOffset / 8 + 1]) : 0
            return UInt8(((high << 8 | low) >> (bitOffset % 8)) & 31)
        }
    }

    #if DEBUG
    /// Deterministic speech-like waveform for Demo Mode fixtures.
    static func sample(seed: Int) -> [UInt8] {
        (0..<63).map { index in
            let phase = Double(index + seed * 7)
            let envelope = 0.35 + 0.65 * abs(sin(phase / 5.0))
            let detail = 0.6 + 0.4 * sin(phase * 2.1)
            return UInt8(max(3, min(31, Int(31 * envelope * detail))))
        }
    }
    #endif
}

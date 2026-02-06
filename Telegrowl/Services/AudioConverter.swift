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

        let waveform = generateWaveform(from: inputURL)
        return (outputURL, waveform)
    }

    /// Generates Telegram-compatible waveform data (63 bytes, 5-bit values 0-31).
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
            return Data(samples)
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
        Data((0..<63).map { _ in UInt8.random(in: 8...24) })
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

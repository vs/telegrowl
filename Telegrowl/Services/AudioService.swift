import Foundation
import AVFoundation
import Combine
import SwiftOGG
#if canImport(UIKit)
import UIKit
#endif

class AudioService: NSObject, ObservableObject {
    static let shared = AudioService()
    
    // MARK: - Published Properties
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var audioLevel: Float = 0
    @Published var recordedURL: URL?
    
    // MARK: - Private Properties
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingTimer: Timer?
    private var levelTimer: Timer?
    private var silenceTimer: Timer?
    
    private let audioSession = AVAudioSession.sharedInstance()
    
    // MARK: - Audio Session Setup
    
    func setupAudioSession() {
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            try audioSession.setActive(true)
            print("🎙️ Audio session configured")
        } catch {
            print("❌ Failed to setup audio session: \(error)")
        }
    }
    
    // MARK: - Recording
    
    func startRecording() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFilename = documentsPath.appendingPathComponent("voice_\(Date().timeIntervalSince1970).ogg")
        
        // Telegram uses Opus codec in OGG container, but for iOS we record as m4a and convert
        let tempFilename = documentsPath.appendingPathComponent("temp_\(Date().timeIntervalSince1970).m4a")
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: tempFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            
            isRecording = true
            recordingDuration = 0
            recordedURL = tempFilename
            
            startTimers()
            
            // Haptic feedback
            if Config.hapticFeedback {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
            }
            
            print("🎙️ Recording started")
        } catch {
            print("❌ Recording failed: \(error)")
        }
    }
    
    func stopRecording() -> URL? {
        stopTimers()
        
        audioRecorder?.stop()
        isRecording = false
        
        // Haptic feedback
        if Config.hapticFeedback {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
        
        print("🎙️ Recording stopped. Duration: \(recordingDuration)s")
        
        return recordedURL
    }
    
    private func startTimers() {
        // Duration timer
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.recordingDuration += 0.1
            
            // Auto-stop after max duration
            if self?.recordingDuration ?? 0 >= Config.maxRecordingDuration {
                _ = self?.stopRecording()
            }
        }
        
        // Audio level timer
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.audioRecorder?.updateMeters()
            self?.audioLevel = self?.audioRecorder?.averagePower(forChannel: 0) ?? -160
            
            // Check for silence (auto-stop feature)
            self?.checkSilence()
        }
    }
    
    private func stopTimers() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        levelTimer?.invalidate()
        levelTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
    }
    
    private func checkSilence() {
        guard Config.silenceDetection else { return }

        // audioLevel is in dB (from averagePower): -160 = silence, 0 = max
        // silenceThreshold is also in dB (e.g. -45.0)
        if audioLevel < Config.silenceThreshold {
            if silenceTimer == nil {
                silenceTimer = Timer.scheduledTimer(withTimeInterval: Config.silenceDuration, repeats: false) { [weak self] _ in
                    // Auto-stop after silence
                    if self?.isRecording == true {
                        print("🤫 Silence detected, auto-stopping")
                        _ = self?.stopRecording()
                        NotificationCenter.default.post(name: .recordingAutoStopped, object: nil)
                    }
                }
            }
        } else {
            silenceTimer?.invalidate()
            silenceTimer = nil
        }
    }
    
    // MARK: - Playback
    
    func play(url: URL) {
        // AVAudioPlayer doesn't support OGG container — convert to M4A first
        let ext = url.pathExtension.lowercased()
        var playableURL = url
        if ext == "oga" || ext == "ogg" {
            let m4aURL = url.deletingPathExtension().appendingPathExtension("m4a")
            if FileManager.default.fileExists(atPath: m4aURL.path) {
                playableURL = m4aURL
            } else {
                do {
                    try OGGConverter.convertOpusOGGToM4aFile(src: url, dest: m4aURL)
                    playableURL = m4aURL
                    print("🔊 Converted OGG→M4A for playback")
                } catch {
                    print("❌ OGG→M4A conversion failed: \(error)")
                    return
                }
            }
        }

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: playableURL)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            isPlaying = true
            print("🔊 Playing: \(playableURL.lastPathComponent)")
        } catch {
            print("❌ Playback failed: \(error)")
        }
    }
    
    func stopPlayback() {
        audioPlayer?.stop()
        isPlaying = false
    }
    
}

// MARK: - AVAudioRecorderDelegate

extension AudioService: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("❌ Recording finished with error")
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
        }
    }
}

// MARK: - Notifications

extension Foundation.Notification.Name {
    static let recordingAutoStopped = Foundation.Notification.Name("recordingAutoStopped")
}

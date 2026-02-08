import SwiftUI

struct VoiceChatView: View {
    @StateObject private var voiceChatService = VoiceChatService()
    @Environment(\.dismiss) var dismiss

    let chatId: Int64
    let chatTitle: String

    var body: some View {
        ZStack {
            Color(hex: "1a1a2e").ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer()
                stateVisual
                stateLabel
                    .padding(.top, 20)
                Spacer()
                muteButton
                    .padding(.bottom, 40)
            }
        }
        .task {
            let granted = await VoiceChatService.requestPermissions()
            if granted {
                voiceChatService.start(chatId: chatId)
            } else {
                dismiss()
            }
        }
        .onDisappear {
            voiceChatService.stop()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Spacer()

            Text(chatTitle)
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)

            Spacer()
        }
        .overlay(alignment: .trailing) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .padding()
    }

    // MARK: - State Visual

    @ViewBuilder
    private var stateVisual: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(stateColor.opacity(0.15))
                .frame(width: 200, height: 200)

            // Inner circle with animation
            Circle()
                .fill(stateColor.opacity(0.3))
                .frame(width: innerCircleSize, height: innerCircleSize)
                .animation(.easeInOut(duration: 0.3), value: innerCircleSize)

            // Icon
            stateIcon
                .font(.system(size: 50))
                .foregroundColor(stateColor)
        }
    }

    private var innerCircleSize: CGFloat {
        switch voiceChatService.state {
        case .recording:
            // Pulse with audio level
            let normalized = max(0, min(1, (voiceChatService.audioLevel + 50) / 50))
            return 100 + CGFloat(normalized) * 60
        case .playing:
            return 130
        default:
            return 100
        }
    }

    private var stateColor: Color {
        if voiceChatService.isMuted {
            return .gray
        }
        switch voiceChatService.state {
        case .idle: return .gray
        case .listening: return .white
        case .recording: return TelegramTheme.recordingRed
        case .processing: return .white
        case .playing: return TelegramTheme.accent
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        if voiceChatService.isMuted {
            Image(systemName: "mic.slash.fill")
        } else {
            switch voiceChatService.state {
            case .idle:
                Image(systemName: "mic.slash.fill")
            case .listening:
                Image(systemName: "mic.fill")
            case .recording:
                Image(systemName: "waveform")
            case .processing:
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.5)
            case .playing:
                Image(systemName: "speaker.wave.3.fill")
            }
        }
    }

    // MARK: - State Label

    private var stateLabel: some View {
        Text(stateLabelText)
            .font(.title3)
            .fontWeight(.medium)
            .foregroundColor(.white.opacity(0.7))
    }

    private var stateLabelText: String {
        if voiceChatService.isMuted {
            return "Muted"
        }
        switch voiceChatService.state {
        case .idle: return "Starting..."
        case .listening: return "Listening..."
        case .recording: return "Recording"
        case .processing: return "Sending..."
        case .playing: return "Bot is speaking"
        }
    }

    // MARK: - Mute Button

    private var muteButton: some View {
        Button(action: { voiceChatService.toggleMute() }) {
            HStack(spacing: 8) {
                Image(systemName: voiceChatService.isMuted ? "mic.slash.fill" : "mic.fill")
                Text(voiceChatService.isMuted ? "Unmute" : "Mute")
                    .fontWeight(.semibold)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 14)
            .background(voiceChatService.isMuted ? TelegramTheme.recordingRed : Color.white.opacity(0.2))
            .cornerRadius(25)
        }
    }
}

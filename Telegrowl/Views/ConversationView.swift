import SwiftUI
import TDLibKit

struct ConversationView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var audioService: AudioService

    @State private var scrollToBottom = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(telegramService.messages, id: \.id) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: telegramService.messages.count) { _, _ in
                withAnimation {
                    if let lastMessage = telegramService.messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message
    @EnvironmentObject var audioService: AudioService

    @State private var isPlaying = false

    var body: some View {
        HStack {
            if message.isOutgoing {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                contentView
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.isOutgoing
                            ? Color.blue
                            : Color(hex: "2a2a3e")
                    )
                    .cornerRadius(16)

                HStack(spacing: 4) {
                    Text(formatTime(Date(timeIntervalSince1970: TimeInterval(message.date))))
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))

                    if message.isOutgoing {
                        sendingStateIcon
                    }
                }
            }

            if !message.isOutgoing {
                Spacer(minLength: 60)
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch message.content {
        case .messageText(let text):
            Text(text.text.text)
                .foregroundColor(.white)

        case .messageVoiceNote(let voiceContent):
            VoiceMessageView(
                voiceNote: voiceContent.voiceNote,
                isPlaying: $isPlaying,
                isOutgoing: message.isOutgoing
            )

        case .messagePhoto:
            Image(systemName: "photo")
                .foregroundColor(.white)

        default:
            Text("[Unsupported message]")
                .foregroundColor(.white.opacity(0.5))
                .italic()
        }
    }

    @ViewBuilder
    private var sendingStateIcon: some View {
        if let sendingState = message.sendingState {
            switch sendingState {
            case .messageSendingStatePending:
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
            case .messageSendingStateFailed:
                Image(systemName: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        } else {
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Voice Message View

struct VoiceMessageView: View {
    let voiceNote: VoiceNote
    @Binding var isPlaying: Bool
    let isOutgoing: Bool

    @EnvironmentObject var audioService: AudioService
    @EnvironmentObject var telegramService: TelegramService

    var body: some View {
        HStack(spacing: 12) {
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                WaveformView(waveform: voiceNote.waveform, isPlaying: isPlaying)
                    .frame(height: 24)

                Text(formatDuration(voiceNote.duration))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .frame(width: 200)
    }

    private func togglePlayback() {
        if isPlaying {
            audioService.stopPlayback()
            isPlaying = false
        } else {
            let localPath = voiceNote.voice.local.path
            if !localPath.isEmpty {
                audioService.play(url: URL(fileURLWithPath: localPath))
                isPlaying = true
            } else {
                telegramService.downloadVoice(voiceNote) { url in
                    if let url = url {
                        audioService.play(url: url)
                        isPlaying = true
                    }
                }
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Waveform View

struct WaveformView: View {
    let waveform: Data
    let isPlaying: Bool

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(0..<30, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(isPlaying ? 0.9 : 0.5))
                        .frame(width: 3, height: getBarHeight(for: index, maxHeight: geometry.size.height))
                        .animation(
                            isPlaying
                                ? .easeInOut(duration: 0.3).repeatForever().delay(Double(index) * 0.05)
                                : .default,
                            value: isPlaying
                        )
                }
            }
        }
    }

    private func getBarHeight(for index: Int, maxHeight: CGFloat) -> CGFloat {
        // If we have waveform data, use it
        if index < waveform.count {
            let value = CGFloat(waveform[index]) / 255.0
            return max(4, value * maxHeight)
        }

        // Otherwise generate random-looking heights
        let heights: [CGFloat] = [0.3, 0.5, 0.7, 0.4, 0.8, 0.6, 0.9, 0.5, 0.7, 0.4,
                                  0.6, 0.8, 0.5, 0.7, 0.9, 0.4, 0.6, 0.8, 0.5, 0.7,
                                  0.4, 0.6, 0.8, 0.5, 0.7, 0.9, 0.4, 0.6, 0.5, 0.3]
        return max(4, heights[index % heights.count] * maxHeight)
    }
}

#Preview {
    ZStack {
        Color(hex: "1a1a2e").ignoresSafeArea()

        ConversationView()
            .environmentObject(TelegramService.shared)
            .environmentObject(AudioService.shared)
    }
}

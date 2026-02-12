import SwiftUI
import TDLibKit

struct ConversationView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var audioService: AudioService

    let chatId: Int64

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(telegramService.messages.enumerated()), id: \.element.id) { index, message in
                        let nextMessage = index + 1 < telegramService.messages.count ? telegramService.messages[index + 1] : nil
                        let prevMessage = index > 0 ? telegramService.messages[index - 1] : nil
                        let hasTail = nextMessage == nil || nextMessage!.isOutgoing != message.isOutgoing
                        let sameSenderAsPrev = prevMessage != nil && prevMessage!.isOutgoing == message.isOutgoing
                        let spacing = sameSenderAsPrev ? TelegramTheme.interMessageSameSender : TelegramTheme.interMessageDifferentSender

                        MessageBubble(message: message, hasTail: hasTail)
                            .id(message.id)
                            .padding(.top, index == 0 ? 8 : spacing)
                            .padding(.bottom, index == telegramService.messages.count - 1 ? 8 : 0)
                    }
                }
                .padding(.horizontal, 8)
            }
            .background(TelegramTheme.chatBackground)
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
    let hasTail: Bool
    @EnvironmentObject var audioService: AudioService

    @State private var isPlaying = false

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 60) }

            bubbleContent
                .background(
                    BubbleShape(isOutgoing: message.isOutgoing, hasTail: hasTail)
                        .fill(message.isOutgoing ? TelegramTheme.outgoingBubble : TelegramTheme.incomingBubble)
                        .shadow(color: .black.opacity(message.isOutgoing ? 0 : 0.06), radius: 1, y: 1)
                )
                .frame(maxWidth: UIScreen.main.bounds.width * TelegramTheme.bubbleMaxWidthRatio, alignment: message.isOutgoing ? .trailing : .leading)

            if !message.isOutgoing { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        switch message.content {
        case .messageText(let text):
            textBubble(text.text.text)

        case .messageVoiceNote(let voiceContent):
            VoiceMessageView(
                voiceNote: voiceContent.voiceNote,
                isPlaying: $isPlaying,
                isOutgoing: message.isOutgoing
            )
            .overlay(alignment: .bottomTrailing) {
                timestampRow
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
            }
            .padding(.horizontal, TelegramTheme.bubblePaddingH)
            .padding(.vertical, TelegramTheme.bubblePaddingV)

        case .messageAudio(let audioContent):
            AudioMessageView(
                audio: audioContent.audio,
                caption: audioContent.caption,
                isOutgoing: message.isOutgoing
            )
            .overlay(alignment: .bottomTrailing) {
                timestampRow
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
            }
            .padding(.horizontal, TelegramTheme.bubblePaddingH)
            .padding(.vertical, TelegramTheme.bubblePaddingV)

        case .messagePhoto:
            HStack(spacing: 4) {
                Image(systemName: "photo")
                    .foregroundColor(TelegramTheme.textSecondary)
                Text("Photo")
                    .font(TelegramTheme.messageFont)
                    .foregroundColor(TelegramTheme.textPrimary)
            }
            .overlay(alignment: .bottomTrailing) { timestampRow }
            .padding(.horizontal, TelegramTheme.bubblePaddingH + 4)
            .padding(.vertical, TelegramTheme.bubblePaddingV + 2)

        case .messageDocument(let docContent):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill")
                        .foregroundColor(TelegramTheme.accent)
                    Text(docContent.document.fileName)
                        .font(TelegramTheme.messageFont)
                        .foregroundColor(TelegramTheme.textPrimary)
                        .lineLimit(1)
                }
                if !docContent.caption.text.isEmpty {
                    Text(docContent.caption.text)
                        .font(TelegramTheme.messageFont)
                        .foregroundColor(TelegramTheme.textPrimary)
                }
            }
            .overlay(alignment: .bottomTrailing) { timestampRow }
            .padding(.horizontal, TelegramTheme.bubblePaddingH + 4)
            .padding(.vertical, TelegramTheme.bubblePaddingV + 2)

        default:
            Text("[Unsupported message]")
                .font(TelegramTheme.messageFont)
                .foregroundColor(TelegramTheme.textSecondary)
                .italic()
                .padding(.horizontal, TelegramTheme.bubblePaddingH + 4)
                .padding(.vertical, TelegramTheme.bubblePaddingV + 2)
        }
    }

    private func textBubble(_ text: String) -> some View {
        // Text + invisible timestamp spacer to ensure text wraps around the timestamp
        HStack(alignment: .bottom, spacing: 0) {
            Text(text)
                .font(TelegramTheme.messageFont)
                .foregroundColor(TelegramTheme.textPrimary)
            + Text("  \(formatTime(Date(timeIntervalSince1970: TimeInterval(message.date))))\(message.isOutgoing ? " ✓✓" : "")")
                .font(TelegramTheme.messageTimestampFont)
                .foregroundColor(.clear) // Invisible spacer
        }
        .overlay(alignment: .bottomTrailing) {
            timestampRow
        }
        .padding(.horizontal, TelegramTheme.bubblePaddingH + 4)
        .padding(.vertical, TelegramTheme.bubblePaddingV + 2)
    }

    private var timestampRow: some View {
        HStack(spacing: 2) {
            Text(formatTime(Date(timeIntervalSince1970: TimeInterval(message.date))))
                .font(TelegramTheme.messageTimestampFont)
                .foregroundColor(message.isOutgoing ? TelegramTheme.outgoingTimestamp : TelegramTheme.incomingTimestamp)

            if message.isOutgoing {
                sendingStateIcon
            }
        }
    }

    @ViewBuilder
    private var sendingStateIcon: some View {
        if let sendingState = message.sendingState {
            switch sendingState {
            case .messageSendingStatePending:
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundColor(TelegramTheme.checkSent)
            case .messageSendingStateFailed:
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 10))
                    .foregroundColor(TelegramTheme.recordingRed)
            }
        } else {
            // Sent / read indicator
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(TelegramTheme.checkRead)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TelegramTheme.checkRead)
                        .offset(x: 4)
                )
        }
    }

    private func formatTime(_ date: Foundation.Date) -> String {
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
        HStack(spacing: 10) {
            // Play button
            Button(action: togglePlayback) {
                ZStack {
                    Circle()
                        .fill(TelegramTheme.accent)
                        .frame(width: TelegramTheme.playButtonSize, height: TelegramTheme.playButtonSize)

                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .offset(x: isPlaying ? 0 : 1)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                WaveformView(waveform: voiceNote.waveform, isPlaying: isPlaying, isOutgoing: isOutgoing)
                    .frame(height: 20)

                Text(formatDuration(voiceNote.duration))
                    .font(TelegramTheme.messageTimestampFont)
                    .foregroundColor(isOutgoing ? TelegramTheme.outgoingTimestamp : TelegramTheme.incomingTimestamp)
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
    let isOutgoing: Bool

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: TelegramTheme.waveformBarSpacing) {
                ForEach(0..<TelegramTheme.waveformBarCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: TelegramTheme.waveformBarWidth / 2)
                        .fill(isPlaying ? TelegramTheme.waveformActive : TelegramTheme.waveformInactive)
                        .frame(width: TelegramTheme.waveformBarWidth, height: getBarHeight(for: index, maxHeight: geometry.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func getBarHeight(for index: Int, maxHeight: CGFloat) -> CGFloat {
        if index < waveform.count {
            let value = CGFloat(waveform[index]) / 255.0
            return max(3, value * maxHeight)
        }
        // Fallback pattern
        let heights: [CGFloat] = [0.3, 0.5, 0.7, 0.4, 0.8, 0.6, 0.9, 0.5, 0.7, 0.4,
                                  0.6, 0.8, 0.5, 0.7, 0.9, 0.4, 0.6, 0.8, 0.5, 0.7,
                                  0.4, 0.6, 0.8, 0.5, 0.7, 0.9, 0.4, 0.6, 0.5, 0.3,
                                  0.5, 0.7]
        return max(3, heights[index % heights.count] * maxHeight)
    }
}

// MARK: - Audio Message View

struct AudioMessageView: View {
    let audio: Audio
    let caption: FormattedText
    let isOutgoing: Bool

    @EnvironmentObject var audioService: AudioService
    @EnvironmentObject var telegramService: TelegramService
    @State private var isPlaying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button(action: togglePlayback) {
                    ZStack {
                        Circle()
                            .fill(TelegramTheme.accent)
                            .frame(width: TelegramTheme.playButtonSize, height: TelegramTheme.playButtonSize)
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .offset(x: isPlaying ? 0 : 1)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(TelegramTheme.textPrimary)
                        .lineLimit(1)
                    Text(formatDuration(audio.duration))
                        .font(TelegramTheme.messageTimestampFont)
                        .foregroundColor(isOutgoing ? TelegramTheme.outgoingTimestamp : TelegramTheme.incomingTimestamp)
                }
            }
            .frame(width: 200, alignment: .leading)

            if !caption.text.isEmpty {
                Text(caption.text)
                    .font(TelegramTheme.messageFont)
                    .foregroundColor(TelegramTheme.textPrimary)
            }
        }
    }

    private var displayTitle: String {
        if !audio.title.isEmpty { return audio.title }
        if !audio.fileName.isEmpty { return audio.fileName }
        return "Audio"
    }

    private func togglePlayback() {
        if isPlaying {
            audioService.stopPlayback()
            isPlaying = false
        } else {
            let localPath = audio.audio.local.path
            if !localPath.isEmpty {
                audioService.play(url: URL(fileURLWithPath: localPath))
                isPlaying = true
            } else {
                Task {
                    do {
                        let file = try await telegramService.downloadPhoto(file: audio.audio)
                        if !file.local.path.isEmpty {
                            audioService.play(url: URL(fileURLWithPath: file.local.path))
                            isPlaying = true
                        }
                    } catch {
                        print("❌ Audio download failed: \(error)")
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

#Preview {
    ConversationView(chatId: 0)
        .environmentObject(TelegramService.shared)
        .environmentObject(AudioService.shared)
}

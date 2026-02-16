import SwiftUI

struct InputBarView: View {
    // Text input
    @Binding var messageText: String
    let onSendText: () -> Void
    let onAttachment: () -> Void

    // Manual recording
    let isRecording: Bool
    let recordingDuration: TimeInterval
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void

    // Dictation overlay
    let dictationState: DictationState
    let liveTranscription: String
    let audioLevel: Float
    let isListening: Bool
    let lastHeard: String
    let onCancelDictation: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            if dictationState == .dictating || dictationState == .recording {
                dictationOverlay
            } else if isRecording {
                manualRecordingBar
            } else {
                normalBar
            }
        }
        .background(TelegramTheme.inputBarBackground)
    }

    // MARK: - Normal State

    private var normalBar: some View {
        VStack(spacing: 0) {
            // Listening indicator — shows what the recognizer hears
            if isListening && !lastHeard.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "ear")
                        .font(.system(size: 10))
                    Text(lastHeard)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .foregroundColor(TelegramTheme.textSecondary.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }

            HStack(spacing: 8) {
                Button(action: onAttachment) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 22))
                        .foregroundColor(TelegramTheme.textSecondary)
                }

                TextField("Message", text: $messageText, axis: .vertical)
                    .font(.system(size: 17))
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(TelegramTheme.inputBarBorder, lineWidth: 0.5)
                    )

                if messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: onStartRecording) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 22))
                            .foregroundColor(isListening ? TelegramTheme.accent : TelegramTheme.textSecondary)
                    }
                } else {
                    Button(action: onSendText) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(TelegramTheme.accent)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: TelegramTheme.inputBarHeight)
        }
    }

    // MARK: - Manual Recording

    private var manualRecordingBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(TelegramTheme.recordingRed)
                    .frame(width: 10, height: 10)

                Text(formatDuration(recordingDuration))
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(TelegramTheme.textPrimary)
            }

            Spacer()

            Button(action: onStopRecording) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(TelegramTheme.recordingRed)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: TelegramTheme.inputBarHeight)
    }

    // MARK: - Dictation Overlay

    private var dictationOverlay: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // Pulsing mic icon
                Image(systemName: dictationState == .recording ? "waveform" : "mic.fill")
                    .font(.system(size: 20))
                    .foregroundColor(TelegramTheme.recordingRed)
                    .symbolEffect(.pulse)

                Text(dictationState == .recording ? "Recording voice..." : "Dictating...")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(TelegramTheme.textPrimary)

                Spacer()

                Button(action: onCancelDictation) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(TelegramTheme.textSecondary)
                }
            }

            if !liveTranscription.isEmpty {
                Text(liveTranscription)
                    .font(.system(size: 15))
                    .foregroundColor(TelegramTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

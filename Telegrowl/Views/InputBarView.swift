import SwiftUI

struct InputBarView: View {
    let isRecording: Bool
    let audioLevel: Float
    let recordingDuration: TimeInterval
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isCancelled = false

    private let cancelThreshold: CGFloat = -120

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            if isRecording {
                recordingOverlay
            } else {
                normalBar
            }
        }
        .background(TelegramTheme.inputBarBackground)
    }

    // MARK: - Normal State

    private var normalBar: some View {
        HStack(spacing: 12) {
            // Attachment button
            Button(action: {}) {
                Image(systemName: "paperclip")
                    .font(.system(size: 22))
                    .foregroundColor(TelegramTheme.textSecondary)
            }

            // Message placeholder
            Text("Message")
                .font(.system(size: 17))
                .foregroundColor(Color(hex: "C7C7CC"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(TelegramTheme.inputBarBorder, lineWidth: 0.5)
                )

            // Mic button
            ZStack {
                Image(systemName: "mic.fill")
                    .font(.system(size: 22))
                    .foregroundColor(TelegramTheme.textSecondary)
            }
            .frame(width: 33, height: 33)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isRecording {
                            onStartRecording()
                        }
                        dragOffset = value.translation.width
                        if dragOffset < cancelThreshold {
                            isCancelled = true
                        }
                    }
                    .onEnded { _ in
                        if isCancelled {
                            isCancelled = false
                            dragOffset = 0
                        }
                        onStopRecording()
                        dragOffset = 0
                    }
            )
        }
        .padding(.horizontal, 8)
        .frame(height: TelegramTheme.inputBarHeight)
    }

    // MARK: - Recording Overlay

    private var recordingOverlay: some View {
        HStack(spacing: 12) {
            // Red recording dot + timer
            HStack(spacing: 6) {
                Circle()
                    .fill(TelegramTheme.recordingRed)
                    .frame(width: 10, height: 10)

                Text(formatDuration(recordingDuration))
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(TelegramTheme.textPrimary)
            }

            Spacer()

            // Slide to cancel
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.caption)
                Text("Slide to cancel")
            }
            .foregroundColor(TelegramTheme.textSecondary)
            .offset(x: min(0, dragOffset * 0.5))
            .opacity(max(0, 1 + Double(dragOffset) / Double(abs(cancelThreshold))))

            Spacer()

            // Mic icon (drag handle)
            Image(systemName: "mic.fill")
                .font(.system(size: 22))
                .foregroundColor(TelegramTheme.accent)
                .offset(x: min(0, dragOffset))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragOffset = value.translation.width
                            if dragOffset < cancelThreshold {
                                isCancelled = true
                            }
                        }
                        .onEnded { _ in
                            if isCancelled {
                                isCancelled = false
                                dragOffset = 0
                            }
                            onStopRecording()
                            dragOffset = 0
                        }
                )
        }
        .padding(.horizontal, 12)
        .frame(height: TelegramTheme.inputBarHeight)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

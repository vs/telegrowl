import SwiftUI

struct RecordButton: View {
    let isRecording: Bool
    let audioLevel: Float
    let duration: TimeInterval
    let onPress: () -> Void
    let onRelease: () -> Void
    
    @State private var isPressed = false
    
    // Convert dB level to 0-1 scale
    private var normalizedLevel: CGFloat {
        let minDb: Float = -60
        let maxDb: Float = 0
        let clamped = max(minDb, min(maxDb, audioLevel))
        return CGFloat((clamped - minDb) / (maxDb - minDb))
    }
    
    var body: some View {
        ZStack {
            // Outer pulsing ring (when recording)
            if isRecording {
                Circle()
                    .stroke(Color.red.opacity(0.3), lineWidth: 4)
                    .frame(width: 200 + normalizedLevel * 50, height: 200 + normalizedLevel * 50)
                    .animation(.easeInOut(duration: 0.1), value: normalizedLevel)
            }
            
            // Middle ring
            Circle()
                .stroke(
                    isRecording ? Color.red.opacity(0.5) : Color.white.opacity(0.2),
                    lineWidth: 3
                )
                .frame(width: 180, height: 180)
            
            // Main button
            Circle()
                .fill(
                    LinearGradient(
                        colors: isRecording 
                            ? [Color.red, Color.red.opacity(0.8)]
                            : [Color(hex: "e94560"), Color(hex: "c73e54")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 150, height: 150)
                .shadow(color: isRecording ? .red.opacity(0.5) : .black.opacity(0.3), radius: 20)
                .scaleEffect(isPressed ? 0.95 : 1.0)
            
            // Icon and duration
            VStack(spacing: 8) {
                Image(systemName: isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
                    .symbolEffect(.variableColor, isActive: isRecording)
                
                if isRecording {
                    Text(formatDuration(duration))
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        isPressed = true
                        onPress()
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    onRelease()
                }
        )
        .animation(.spring(response: 0.3), value: isRecording)
        .animation(.spring(response: 0.2), value: isPressed)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    ZStack {
        Color(hex: "1a1a2e").ignoresSafeArea()
        
        VStack(spacing: 50) {
            RecordButton(
                isRecording: false,
                audioLevel: -40,
                duration: 0,
                onPress: {},
                onRelease: {}
            )
            
            RecordButton(
                isRecording: true,
                audioLevel: -20,
                duration: 5.5,
                onPress: {},
                onRelease: {}
            )
        }
    }
}

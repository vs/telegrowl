import SwiftUI

// MARK: - Telegram "Day Classic" Theme Constants

enum TelegramTheme {
    // MARK: Colors
    static let accent = Color(hex: "007AFF")
    static let outgoingBubble = Color(hex: "E1FFC7")
    static let incomingBubble = Color.white
    static let chatBackground = Color(hex: "C6DEDD")
    static let textPrimary = Color.black
    static let textSecondary = Color(hex: "8E8E93")
    static let timestamp = Color(hex: "8E8E93")
    static let unreadBadge = Color(hex: "007AFF")
    static let recordingRed = Color(hex: "FF3B30")
    static let waveformActive = Color(hex: "007AFF")
    static let waveformInactive = Color(hex: "93C8EC")
    static let outgoingTimestamp = Color(hex: "4DA84B")
    static let incomingTimestamp = Color(hex: "8E8E93")
    static let checkRead = Color(hex: "4DA84B")
    static let checkSent = Color(hex: "8E8E93")
    static let inputBarBackground = Color(hex: "F6F6F6")
    static let inputBarBorder = Color(hex: "E0E0E0")
    static let separator = Color(hex: "C8C7CC")

    // MARK: Layout
    static let chatListRowHeight: CGFloat = 76
    static let chatListAvatarSize: CGFloat = 54
    static let messageAvatarSize: CGFloat = 36
    static let bubbleCornerRadius: CGFloat = 17
    static let bubbleTailRadius: CGFloat = 4
    static let bubbleMaxWidthRatio: CGFloat = 0.75
    static let bubblePaddingH: CGFloat = 8
    static let bubblePaddingV: CGFloat = 6
    static let interMessageSameSender: CGFloat = 2
    static let interMessageDifferentSender: CGFloat = 8
    static let inputBarHeight: CGFloat = 44
    static let playButtonSize: CGFloat = 33
    static let waveformBarWidth: CGFloat = 2
    static let waveformBarSpacing: CGFloat = 1.5
    static let waveformBarCount: Int = 32
    static let chatListAvatarInset: CGFloat = 10

    // MARK: Fonts
    static let titleFont = Font.system(size: 17, weight: .semibold)
    static let previewFont = Font.system(size: 16)
    static let timestampFont = Font.system(size: 14)
    static let messageFont = Font.system(size: 17)
    static let messageTimestampFont = Font.system(size: 11)
    static let badgeFont = Font.system(size: 12, weight: .bold)

    // MARK: Avatar Colors (Telegram's 7 default colors)
    static let avatarColors: [(Color, Color)] = [
        (Color(hex: "FF885E"), Color(hex: "FF516A")), // red-orange
        (Color(hex: "FCD884"), Color(hex: "FFA85C")), // yellow
        (Color(hex: "B0F07C"), Color(hex: "67D661")), // green
        (Color(hex: "6FC4F2"), Color(hex: "37AEE2")), // blue
        (Color(hex: "C9B2F7"), Color(hex: "9B7CF7")), // purple
        (Color(hex: "F7B0C0"), Color(hex: "F2749A")), // pink
        (Color(hex: "FFB2B2"), Color(hex: "FF6767")), // red
    ]
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

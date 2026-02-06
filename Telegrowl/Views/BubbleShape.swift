import SwiftUI

struct BubbleShape: Shape {
    let isOutgoing: Bool
    let hasTail: Bool

    func path(in rect: CGRect) -> Path {
        let r = TelegramTheme.bubbleCornerRadius
        let tailR = TelegramTheme.bubbleTailRadius
        let tailWidth: CGFloat = 6

        if !hasTail {
            return Path(roundedRect: rect, cornerRadius: r)
        }

        var path = Path()

        if isOutgoing {
            // Tail on bottom-right
            let tailX = rect.maxX

            // Start at top-left + radius
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            // Top edge
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            // Top-right corner
            path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                        radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            // Right edge down to tail start
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - tailR - 2))
            // Tail curve outward
            path.addQuadCurve(
                to: CGPoint(x: tailX + tailWidth, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            // Tail curve back in
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - tailR * 2, y: rect.maxY - tailR),
                control: CGPoint(x: rect.maxX - tailR, y: rect.maxY)
            )
            // Bottom edge
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY - tailR))
            // Bottom-left corner
            path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - tailR - r),
                        radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            // Left edge
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            // Top-left corner
            path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                        radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        } else {
            // Tail on bottom-left
            let tailX = rect.minX

            // Start at top-left + radius
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            // Top edge
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            // Top-right corner
            path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                        radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            // Right edge
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - tailR - r))
            // Bottom-right corner
            path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - tailR - r),
                        radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            // Bottom edge to tail
            path.addLine(to: CGPoint(x: rect.minX + tailR * 2, y: rect.maxY - tailR))
            // Tail curve outward
            path.addQuadCurve(
                to: CGPoint(x: tailX - tailWidth, y: rect.maxY),
                control: CGPoint(x: rect.minX + tailR, y: rect.maxY)
            )
            // Tail curve back up
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - tailR - 2),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            // Left edge up
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            // Top-left corner
            path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                        radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }

        path.closeSubpath()
        return path
    }
}

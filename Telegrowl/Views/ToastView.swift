import SwiftUI

enum ToastStyle {
    case info, success, error, warning

    var color: Color {
        switch self {
        case .info: .blue
        case .success: .green
        case .error: .red
        case .warning: .orange
        }
    }
}

struct ToastData: Equatable {
    let message: String
    let style: ToastStyle
    let icon: String
    var isLoading: Bool = false
    var hasRetry: Bool = false
    // Retry action stored externally (closures aren't Equatable)

    static func == (lhs: ToastData, rhs: ToastData) -> Bool {
        lhs.message == rhs.message && lhs.icon == rhs.icon && lhs.isLoading == rhs.isLoading && lhs.hasRetry == rhs.hasRetry
    }
}

struct ToastView: View {
    let toast: ToastData
    var onDismiss: () -> Void = {}
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if toast.isLoading {
                ProgressView()
                    .tint(.white)
            } else {
                Image(systemName: toast.icon)
                    .font(.body.weight(.semibold))
            }

            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            Spacer()

            if toast.hasRetry, let onRetry {
                Button("Retry") {
                    onRetry()
                }
                .font(.subheadline.weight(.bold))
                .foregroundColor(.white)
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(toast.style.color.opacity(0.9))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .padding(.horizontal, 16)
        .onTapGesture { onDismiss() }
    }
}

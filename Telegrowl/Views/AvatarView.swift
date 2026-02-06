import SwiftUI
import TDLibKit

/// Protocol to unify ChatPhotoInfo and ProfilePhoto, which share the same photo fields.
protocol TelegramPhoto {
    var small: File { get }
    var minithumbnail: Minithumbnail? { get }
}

extension ChatPhotoInfo: TelegramPhoto {}
extension ProfilePhoto: TelegramPhoto {}

struct AvatarView: View {
    let photo: (any TelegramPhoto)?
    let title: String
    let size: CGFloat

    @EnvironmentObject var telegramService: TelegramService
    @State private var downloadedPath: String?

    var body: some View {
        Group {
            if let path = downloadedPath, let uiImage = UIImage(contentsOfFile: path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if let data = photo?.minithumbnail?.data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 2)
            } else {
                ZStack {
                    Circle()
                        .fill(avatarGradient)
                    Text(avatarInitials)
                        .font(size > 40 ? .headline : .caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: photo?.small.id) {
            guard let photo else { return }
            if photo.small.local.isDownloadingCompleted, !photo.small.local.path.isEmpty {
                downloadedPath = photo.small.local.path
            } else {
                do {
                    let file = try await telegramService.downloadPhoto(file: photo.small)
                    withAnimation(.easeIn(duration: 0.2)) {
                        downloadedPath = file.local.path
                    }
                } catch {
                    print("❌ Avatar download failed: \(error)")
                }
            }
        }
    }

    private var avatarGradient: LinearGradient {
        let index = abs(title.hashValue) % TelegramTheme.avatarColors.count
        let colors = TelegramTheme.avatarColors[index]
        return LinearGradient(
            colors: [colors.0, colors.1],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var avatarInitials: String {
        let words = title.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(title.prefix(2)).uppercased()
    }
}

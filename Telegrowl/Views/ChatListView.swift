import SwiftUI
import TDLibKit

struct ChatListView: View {
    @EnvironmentObject var telegramService: TelegramService

    @State private var searchText = ""
    @State private var showingSettings = false

    var filteredChats: [Chat] {
        if searchText.isEmpty {
            return telegramService.chats
        }
        // @username search
        if searchText.hasPrefix("@") {
            return telegramService.chats
        }
        return telegramService.chats.filter { chat in
            chat.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            ForEach(filteredChats, id: \.id) { chat in
                NavigationLink(value: chat.id) {
                    ChatRow(chat: chat)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: TelegramTheme.chatListAvatarInset, bottom: 0, trailing: 16))
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search")
        .onSubmit(of: .search) {
            if searchText.hasPrefix("@") {
                let username = String(searchText.dropFirst())
                telegramService.searchChat(username: username)
            }
        }
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeft) {
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gear")
                        .foregroundColor(TelegramTheme.accent)
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onAppear {
            telegramService.loadChats()
        }
    }
}

// MARK: - Chat Row

struct ChatRow: View {
    let chat: Chat

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(photo: chat.photo, title: chat.title, size: TelegramTheme.chatListAvatarSize)

            VStack(alignment: .leading, spacing: 3) {
                // Top line: title + timestamp
                HStack {
                    Text(chat.title)
                        .font(TelegramTheme.titleFont)
                        .foregroundColor(TelegramTheme.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    if let lastMessage = chat.lastMessage {
                        Text(formatTime(Date(timeIntervalSince1970: TimeInterval(lastMessage.date))))
                            .font(TelegramTheme.timestampFont)
                            .foregroundColor(chat.unreadCount > 0 ? TelegramTheme.accent : TelegramTheme.timestamp)
                    }
                }

                // Bottom line: preview + unread badge
                HStack {
                    Text(messagePreview(for: chat))
                        .font(TelegramTheme.previewFont)
                        .foregroundColor(TelegramTheme.textSecondary)
                        .lineLimit(1)

                    Spacer()

                    if chat.unreadCount > 0 {
                        Text("\(chat.unreadCount)")
                            .font(TelegramTheme.badgeFont)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(TelegramTheme.unreadBadge)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .frame(height: TelegramTheme.chatListRowHeight - 8) // Account for cell padding
    }

    private func messagePreview(for chat: Chat) -> String {
        guard let content = chat.lastMessage?.content else { return "" }
        switch content {
        case .messageText(let text):
            return text.text.text
        case .messageVoiceNote:
            return "🎤 Voice message"
        case .messagePhoto:
            return "📷 Photo"
        case .messageVideo:
            return "📹 Video"
        case .messageDocument:
            return "📎 Document"
        case .messageSticker(let sticker):
            return "\(sticker.sticker.emoji) Sticker"
        case .messageAnimation:
            return "GIF"
        default:
            return "Message"
        }
    }

    private func formatTime(_ date: Foundation.Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            return formatter.string(from: date)
        }
    }
}

#Preview {
    NavigationStack {
        ChatListView()
            .environmentObject(TelegramService.shared)
    }
}

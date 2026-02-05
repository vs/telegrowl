import SwiftUI
import TDLibKit

struct ChatListView: View {
    @EnvironmentObject var telegramService: TelegramService
    @Environment(\.dismiss) var dismiss
    
    @State private var searchText = ""
    @State private var isSearching = false
    
    var filteredChats: [Chat] {
        if searchText.isEmpty {
            return telegramService.chats
        }
        return telegramService.chats.filter { chat in
            chat.title.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationView {
            List {
                // Search by username section
                Section {
                    HStack {
                        TextField("@username", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        
                        if !searchText.isEmpty && searchText.hasPrefix("@") {
                            Button("Search") {
                                let username = String(searchText.dropFirst())
                                telegramService.searchChat(username: username)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text("Search by Username")
                }
                
                // Recent chats
                Section {
                    if filteredChats.isEmpty {
                        Text("No chats found")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(filteredChats, id: \.id) { chat in
                            ChatRow(chat: chat)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    telegramService.selectChat(chat)
                                    dismiss()
                                }
                        }
                    }
                } header: {
                    Text("Recent Chats")
                }
            }
            .navigationTitle("Select Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                telegramService.loadChats()
            }
        }
    }
}

// MARK: - Chat Row

struct ChatRow: View {
    let chat: Chat

    var body: some View {
        HStack(spacing: 12) {
            chatAvatar

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(chat.title)
                        .fontWeight(.medium)

                    Spacer()

                    if let lastMessage = chat.lastMessage {
                        Text(formatTime(Date(timeIntervalSince1970: TimeInterval(lastMessage.date))))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    Spacer()

                    if chat.unreadCount > 0 {
                        Text("\(chat.unreadCount)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private var chatAvatar: some View {
        ZStack {
            Circle()
                .fill(avatarGradient)
                .frame(width: 50, height: 50)
            
            Text(avatarInitials)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
        }
    }
    
    private var avatarGradient: LinearGradient {
        let colors: [Color] = [
            .red, .orange, .yellow, .green, .blue, .purple, .pink
        ]
        let index = abs(chat.id.hashValue) % colors.count
        return LinearGradient(
            colors: [colors[index], colors[(index + 1) % colors.count]],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    private var avatarInitials: String {
        let words = chat.title.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(chat.title.prefix(2)).uppercased()
    }
    
    private func formatTime(_ date: Date) -> String {
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
    ChatListView()
        .environmentObject(TelegramService.shared)
}

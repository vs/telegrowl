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
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
        AvatarView(photo: chat.photo, title: chat.title, size: 50)
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
    ChatListView()
        .environmentObject(TelegramService.shared)
}

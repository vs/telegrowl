import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var telegramService: TelegramService
    @Environment(\.dismiss) var dismiss

    @State private var autoPlay = Config.autoPlayResponses
    @State private var haptics = Config.hapticFeedback
    @State private var silenceDetection = Config.silenceDetection
    @State private var silenceDuration = Config.silenceDuration
    @State private var maxRecordingDuration = Config.maxRecordingDuration

    @State private var showingLogoutConfirm = false

    var body: some View {
        NavigationView {
            Form {
                accountSection
                audioSection
                aboutSection
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveSettings()
                        dismiss()
                    }
                }
            }
            .alert("Logout?", isPresented: $showingLogoutConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Logout", role: .destructive) {
                    telegramService.logout()
                }
            } message: {
                Text("You'll need to login again to use Telegrowl.")
            }
            .tint(TelegramTheme.accent)
        }
    }

    // MARK: - Account Section

    private var accountSection: some View {
        Section {
            if telegramService.isAuthenticated {
                if let user = telegramService.currentUser {
                    HStack {
                        AvatarView(photo: user.profilePhoto, title: user.firstName, size: 50)

                        VStack(alignment: .leading) {
                            Text("\(user.firstName) \(user.lastName)".trimmingCharacters(in: .whitespaces))
                                .fontWeight(.medium)

                            if let username = user.usernames?.activeUsernames.first {
                                Text("@\(username)")
                                    .font(.caption)
                                    .foregroundColor(TelegramTheme.textSecondary)
                            }
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color(hex: "4DA84B"))
                        Text("Connected to Telegram")
                    }
                }

                Button("Logout", role: .destructive) {
                    showingLogoutConfirm = true
                }
            } else {
                HStack {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(TelegramTheme.recordingRed)
                    Text("Not connected")
                        .foregroundColor(TelegramTheme.textSecondary)
                }
            }
        } header: {
            Text("Account")
        }
    }

    // MARK: - Audio Section

    private var audioSection: some View {
        Section {
            Toggle("Auto-play Responses", isOn: $autoPlay)

            Toggle("Haptic Feedback", isOn: $haptics)

            Toggle("Silence Detection", isOn: $silenceDetection)

            if silenceDetection {
                HStack {
                    Text("Stop after silence")
                    Spacer()
                    Picker("", selection: $silenceDuration) {
                        Text("1s").tag(1.0)
                        Text("1.5s").tag(1.5)
                        Text("2s").tag(2.0)
                        Text("3s").tag(3.0)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }

            HStack {
                Text("Max Recording")
                Spacer()
                Picker("", selection: $maxRecordingDuration) {
                    Text("30s").tag(30.0)
                    Text("1m").tag(60.0)
                    Text("2m").tag(120.0)
                    Text("5m").tag(300.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("Silence detection automatically stops recording when you stop talking.")
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text("1.0.0 MVP")
                    .foregroundColor(TelegramTheme.textSecondary)
            }

            Link(destination: URL(string: "https://github.com/vs/telegrowl")!) {
                HStack {
                    Text("GitHub")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .foregroundColor(TelegramTheme.textSecondary)
                }
            }

            Link(destination: URL(string: "https://t.me/telegrowl")!) {
                HStack {
                    Text("Telegram Channel")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .foregroundColor(TelegramTheme.textSecondary)
                }
            }
        } header: {
            Text("About")
        }
    }

    // MARK: - Save

    private func saveSettings() {
        Config.autoPlayResponses = autoPlay
        Config.hapticFeedback = haptics
        Config.silenceDetection = silenceDetection
        Config.silenceDuration = silenceDuration
        Config.maxRecordingDuration = maxRecordingDuration
    }
}

// MARK: - Info Row

struct InfoRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(TelegramTheme.accent)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundColor(TelegramTheme.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    SettingsView()
        .environmentObject(TelegramService.shared)
}

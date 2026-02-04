import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var telegramService: TelegramService
    @Environment(\.dismiss) var dismiss
    
    @State private var targetUsername = Config.targetChatUsername
    @State private var autoPlay = Config.autoPlayResponses
    @State private var haptics = Config.hapticFeedback
    @State private var silenceDetection = Config.silenceDetection
    @State private var silenceDuration = Config.silenceDuration
    @State private var maxRecordingDuration = Config.maxRecordingDuration
    
    @State private var showingLogoutConfirm = false
    
    var body: some View {
        NavigationView {
            Form {
                // Account
                accountSection
                
                // Chat Settings
                chatSection
                
                // Audio Settings
                audioSection
                
                // Driving Mode
                drivingSection
                
                // About
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
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
        }
    }
    
    // MARK: - Account Section
    
    private var accountSection: some View {
        Section {
            if telegramService.isAuthenticated {
                if let user = telegramService.currentUser {
                    HStack {
                        // Avatar
                        ZStack {
                            Circle()
                                .fill(LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .frame(width: 50, height: 50)
                            
                            Text(String(user.firstName.prefix(1)))
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                        }
                        
                        VStack(alignment: .leading) {
                            Text(user.displayName)
                                .fontWeight(.medium)
                            
                            if let username = user.username {
                                Text("@\(username)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Connected to Telegram")
                    }
                }
                
                Button("Logout", role: .destructive) {
                    showingLogoutConfirm = true
                }
            } else {
                HStack {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text("Not connected")
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Account")
        }
    }
    
    // MARK: - Chat Section
    
    private var chatSection: some View {
        Section {
            if let chat = telegramService.selectedChat {
                HStack {
                    Text("Current Chat")
                    Spacer()
                    Text(chat.title)
                        .foregroundColor(.secondary)
                }
            }
            
            HStack {
                Text("Default Bot")
                Spacer()
                TextField("@username", text: $targetUsername)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Chat")
        } footer: {
            Text("Set the default chat for voice messages. You can always change it from the main screen.")
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
    
    // MARK: - Driving Section
    
    private var drivingSection: some View {
        Section {
            NavigationLink(destination: DrivingModeInfo()) {
                Label("Driving Mode Tips", systemImage: "car.fill")
            }
            
            NavigationLink(destination: SiriShortcutsInfo()) {
                Label("Siri Shortcuts", systemImage: "waveform")
            }
        } header: {
            Text("Hands-Free")
        } footer: {
            Text("Tips for using Telegrowl while driving safely.")
        }
    }
    
    // MARK: - About Section
    
    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text("1.0.0 MVP")
                    .foregroundColor(.secondary)
            }
            
            Link(destination: URL(string: "https://github.com/vs/telegrowl")!) {
                HStack {
                    Text("GitHub")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .foregroundColor(.secondary)
                }
            }
            
            Link(destination: URL(string: "https://t.me/telegrowl")!) {
                HStack {
                    Text("Telegram Channel")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("About")
        }
    }
    
    // MARK: - Save
    
    private func saveSettings() {
        Config.targetChatUsername = targetUsername
        Config.autoPlayResponses = autoPlay
        Config.hapticFeedback = haptics
        Config.silenceDetection = silenceDetection
        Config.silenceDuration = silenceDuration
        Config.maxRecordingDuration = maxRecordingDuration
    }
}

// MARK: - Driving Mode Info

struct DrivingModeInfo: View {
    var body: some View {
        List {
            Section {
                InfoRow(icon: "hand.tap", title: "Large Touch Target", 
                       description: "The record button is big and easy to tap without looking")
                
                InfoRow(icon: "speaker.wave.3.fill", title: "Auto-Play Responses",
                       description: "Voice responses play automatically through your car speakers")
                
                InfoRow(icon: "waveform", title: "Silence Detection",
                       description: "Recording stops automatically when you stop talking")
                
                InfoRow(icon: "airpods", title: "AirPods/CarPlay",
                       description: "Works with Bluetooth audio devices and CarPlay")
            }
            
            Section {
                Text("⚠️ Safety First")
                    .fontWeight(.bold)
                
                Text("Only use Telegrowl when it's safe to do so. Pull over if you need to look at your phone.")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Driving Mode")
    }
}

// MARK: - Siri Shortcuts Info

struct SiriShortcutsInfo: View {
    var body: some View {
        List {
            Section {
                Text("Coming soon: Siri integration!")
                    .foregroundColor(.secondary)
                
                Text("You'll be able to say \"Hey Siri, Telegrowl\" to start recording.")
                    .foregroundColor(.secondary)
            }
            
            Section {
                InfoRow(icon: "mic.fill", title: "Voice Activation",
                       description: "Start recording with your voice")
                
                InfoRow(icon: "bell.fill", title: "Announce Messages",
                       description: "Siri can announce incoming messages")
            }
        }
        .navigationTitle("Siri Shortcuts")
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
                .foregroundColor(.blue)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fontWeight(.medium)
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    SettingsView()
        .environmentObject(TelegramService.shared)
}

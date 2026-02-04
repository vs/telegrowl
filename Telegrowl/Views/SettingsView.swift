import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var telegramService: TelegramService
    @Environment(\.dismiss) var dismiss
    
    @AppStorage("targetChatUsername") private var targetUsername = ""
    @AppStorage("autoPlayResponses") private var autoPlay = true
    @AppStorage("hapticFeedback") private var haptics = true
    @AppStorage("silenceDetection") private var silenceDetection = true
    @AppStorage("silenceDuration") private var silenceDuration = 1.5
    
    var body: some View {
        NavigationView {
            Form {
                // Chat Settings
                Section("Chat") {
                    HStack {
                        Text("Bot Username")
                        Spacer()
                        TextField("@username", text: $targetUsername)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.secondary)
                    }
                    
                    if !targetUsername.isEmpty {
                        Button("Select This Chat") {
                            telegramService.selectChat(username: targetUsername)
                        }
                    }
                }
                
                // Audio Settings
                Section("Audio") {
                    Toggle("Auto-play Responses", isOn: $autoPlay)
                    Toggle("Haptic Feedback", isOn: $haptics)
                    Toggle("Silence Detection", isOn: $silenceDetection)
                    
                    if silenceDetection {
                        HStack {
                            Text("Silence Duration")
                            Spacer()
                            Picker("", selection: $silenceDuration) {
                                Text("1s").tag(1.0)
                                Text("1.5s").tag(1.5)
                                Text("2s").tag(2.0)
                                Text("3s").tag(3.0)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 200)
                        }
                    }
                }
                
                // Account
                Section("Account") {
                    if telegramService.isAuthenticated {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Connected to Telegram")
                        }
                        
                        Button("Logout", role: .destructive) {
                            // TODO: Implement logout
                        }
                    } else {
                        Text("Not connected")
                            .foregroundColor(.secondary)
                    }
                }
                
                // About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0 MVP")
                            .foregroundColor(.secondary)
                    }
                    
                    Link("GitHub", destination: URL(string: "https://github.com/vs/telegrowl")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(TelegramService.shared)
}

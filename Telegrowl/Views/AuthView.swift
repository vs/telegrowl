import SwiftUI
import TDLibKit

struct AuthView: View {
    @EnvironmentObject var telegramService: TelegramService
    @Environment(\.dismiss) var dismiss

    @State private var phoneNumber = ""
    @State private var code = ""
    @State private var password = ""

    var body: some View {
        NavigationView {
            Form {
                if let state = telegramService.authorizationState {
                    switch state {
                    case .authorizationStateWaitPhoneNumber:
                        phoneSection

                    case .authorizationStateWaitCode:
                        codeSection

                    case .authorizationStateWaitPassword:
                        passwordSection

                    case .authorizationStateReady:
                        successSection

                    default:
                        ProgressView("Connecting...")
                    }
                } else {
                    ProgressView("Initializing...")
                }

                if let error = telegramService.error {
                    errorSection(error.localizedDescription)
                }
            }
            .navigationTitle("Your Phone")
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
            .tint(TelegramTheme.accent)
        }
    }

    // MARK: - Phone Number Section

    private var phoneSection: some View {
        Section {
            TextField("Phone Number", text: $phoneNumber)
                #if os(iOS)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                #endif

            Button("Send Code") {
                telegramService.sendPhoneNumber(phoneNumber)
            }
            .disabled(phoneNumber.isEmpty)
            .foregroundColor(phoneNumber.isEmpty ? TelegramTheme.textSecondary : TelegramTheme.accent)
        } header: {
            VStack(spacing: 12) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 40))
                    .foregroundColor(TelegramTheme.accent)
                Text("Enter your phone number")
                    .font(.subheadline)
                    .foregroundColor(TelegramTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } footer: {
            Text("Include country code, e.g., +7 999 123 4567")
        }
    }

    // MARK: - Code Section

    private var codeSection: some View {
        Section {
            TextField("Verification Code", text: $code)
                #if os(iOS)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                #endif

            Button("Verify") {
                telegramService.sendCode(code)
            }
            .disabled(code.isEmpty)
            .foregroundColor(code.isEmpty ? TelegramTheme.textSecondary : TelegramTheme.accent)
        } header: {
            Text("Enter the code from Telegram")
        }
    }

    // MARK: - Password Section

    private var passwordSection: some View {
        Section {
            SecureField("Password", text: $password)
                .textContentType(.password)

            Button("Submit") {
                telegramService.sendPassword(password)
            }
            .disabled(password.isEmpty)
            .foregroundColor(password.isEmpty ? TelegramTheme.textSecondary : TelegramTheme.accent)
        } header: {
            Text("Two-Factor Authentication")
        } footer: {
            Text("Enter your 2FA password")
        }
    }

    // MARK: - Success Section

    private var successSection: some View {
        Section {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Color(hex: "4DA84B"))
                Text("Successfully logged in!")
            }

            Button("Done") {
                dismiss()
            }
            .foregroundColor(TelegramTheme.accent)
        }
    }

    // MARK: - Error Section

    private func errorSection(_ message: String) -> some View {
        Section {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(TelegramTheme.recordingRed)
                Text(message)
            }

            Button("Try Again") {
                telegramService.error = nil
            }
            .foregroundColor(TelegramTheme.accent)
        }
    }
}

#Preview {
    AuthView()
        .environmentObject(TelegramService.shared)
}

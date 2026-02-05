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
                        // Handle other states (initial, closing, etc.)
                        ProgressView("Connecting...")
                    }
                } else {
                    ProgressView("Initializing...")
                }

                // Show error if present
                if let error = telegramService.error {
                    errorSection(error.localizedDescription)
                }
            }
            .navigationTitle("Login to Telegram")
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
        } header: {
            Text("Enter your phone number")
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
                    .foregroundColor(.green)
                Text("Successfully logged in!")
            }
            
            Button("Done") {
                dismiss()
            }
        }
    }
    
    // MARK: - Error Section

    private func errorSection(_ message: String) -> some View {
        Section {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(message)
            }

            Button("Try Again") {
                telegramService.error = nil
            }
        }
    }
}

#Preview {
    AuthView()
        .environmentObject(TelegramService.shared)
}

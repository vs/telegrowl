import SwiftUI

struct AuthView: View {
    @EnvironmentObject var telegramService: TelegramService
    @Environment(\.dismiss) var dismiss
    
    @State private var phoneNumber = ""
    @State private var code = ""
    @State private var password = ""
    
    var body: some View {
        NavigationView {
            Form {
                switch telegramService.authState {
                case .initial, .waitingPhoneNumber:
                    phoneSection
                    
                case .waitingCode:
                    codeSection
                    
                case .waitingPassword:
                    passwordSection
                    
                case .ready:
                    successSection
                    
                case .error(let message):
                    errorSection(message)
                }
            }
            .navigationTitle("Login to Telegram")
            .navigationBarTitleDisplayMode(.inline)
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
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
            
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
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            
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
                telegramService.authState = .waitingPhoneNumber
            }
        }
    }
}

#Preview {
    AuthView()
        .environmentObject(TelegramService.shared)
}

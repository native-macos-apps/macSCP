//
//  SettingsView.swift
//  macSCP
//
//  Application settings view (Cmd+, shortcut via Settings scene)
//

import SwiftUI

struct SettingsView: View {
    @State private var appLockManager = AppLockManager.shared
    @State private var transferSettings = TransferSettings.shared
    private let biometricService: BiometricAuthServiceProtocol = BiometricAuthService.shared

    private var isBiometricAvailable: Bool {
        biometricService.isBiometricAvailable()
    }

    private var isEnabled: Bool {
        appLockManager.isBiometricLockEnabled
    }

    var body: some View {
        Form {
            transfersSection
            securitySection
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Security Section

    @ViewBuilder
    private var securitySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { appLockManager.isBiometricLockEnabled },
                set: { newValue in
                    if newValue {
                        appLockManager.enableBiometricLock()
                    } else {
                        Task {
                            await appLockManager.disableBiometricLock()
                        }
                    }
                }
            )) {
                Label("Require Touch ID", systemImage: "touchid")
            }
            .disabled(!isBiometricAvailable)

            if !isBiometricAvailable {
                Text("Touch ID is not available on this Mac. Use a Mac with Touch ID or an Apple Watch to enable this feature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isEnabled {
                Toggle(isOn: Bindable(appLockManager).lockOnAppResume) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lock when switching apps")
                        Text("Require authentication when returning to macSCP")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: Bindable(appLockManager).lockBeforeConnection) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Require before each connection")
                        Text("Authenticate before connecting to any server")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Toggle(isOn: Bindable(appLockManager).lockAfterInactivity) {
                        Text("Lock after inactivity")
                    }

                    Spacer()

                    Picker("", selection: Bindable(appLockManager).inactivityTimeout) {
                        ForEach(InactivityTimeout.allCases) { timeout in
                            Text(timeout.label).tag(timeout)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!appLockManager.lockAfterInactivity)
                }
            }
        } header: {
            Text("Security")
        } footer: {
            if isEnabled {
                Text("The app always requires authentication on launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Transfers Section

    @ViewBuilder
    private var transfersSection: some View {
        Section {
            Picker("Concurrent transfers", selection: Bindable(transferSettings).maxConcurrentTransfers) {
                ForEach(1...8, id: \.self) { count in
                    Text("\(count) \(count == 1 ? "stream" : "streams")").tag(count)
                }
            }
        } header: {
            Text("Transfers")
        } footer: {
            Text("Controls how many files are uploaded or downloaded simultaneously when transferring directories or multiple files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SettingsView()
}

//
//  SettingsView.swift
//  macSCP
//
//  Application settings view (Cmd+, shortcut via Settings scene)
//

import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case transfers = "transfers"
    case sshKeys = "sshKeys"
    case knownHosts = "knownHosts"
    case security = "security"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transfers: return "Transfers"
        case .sshKeys: return "SSH Keys"
        case .knownHosts: return "Known Hosts"
        case .security: return "Security"
        }
    }

    var systemImage: String {
        switch self {
        case .transfers: return "arrow.up.arrow.down"
        case .sshKeys: return "key.fill"
        case .knownHosts: return "server.rack"
        case .security: return "lock.shield"
        }
    }
}

struct SettingsView: View {
    private struct KnownHostEntry: Identifiable {
        let identifier: String
        let fingerprint: String
        var id: String { identifier }
    }

    @State private var selectedTab: SettingsTab = .transfers
    @State private var appLockManager = AppLockManager.shared
    @State private var transferSettings = TransferSettings.shared
    @State private var sshKeys: [SSHKeyItem] = []
    @State private var knownHosts: [KnownHostEntry] = []
    @State private var showingImportKeySheet: Bool = false
    @State private var keyToDelete: SSHKeyItem? = nil
    @State private var showingDeleteConfirmation: Bool = false
    private let biometricService: BiometricAuthServiceProtocol = BiometricAuthService.shared

    private var isBiometricAvailable: Bool {
        biometricService.isBiometricAvailable()
    }

    private var isEnabled: Bool {
        appLockManager.isBiometricLockEnabled
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            transfersTab
                .tabItem {
                    Label(SettingsTab.transfers.title, systemImage: SettingsTab.transfers.systemImage)
                }
                .tag(SettingsTab.transfers)

            sshKeysTab
                .tabItem {
                    Label(SettingsTab.sshKeys.title, systemImage: SettingsTab.sshKeys.systemImage)
                }
                .tag(SettingsTab.sshKeys)

            knownHostsTab
                .tabItem {
                    Label(SettingsTab.knownHosts.title, systemImage: SettingsTab.knownHosts.systemImage)
                }
                .tag(SettingsTab.knownHosts)

            securityTab
                .tabItem {
                    Label(SettingsTab.security.title, systemImage: SettingsTab.security.systemImage)
                }
                .tag(SettingsTab.security)
        }
        .frame(width: 560, height: 420)
        .onAppear {
            reloadKeys()
        }
        .sheet(isPresented: $showingImportKeySheet) {
            ImportKeySheet(
                onKeyImported: { _ in
                    reloadKeys()
                    showingImportKeySheet = false
                },
                onCancel: {
                    showingImportKeySheet = false
                }
            )
        }
        .confirmationDialog(
            "Delete SSH Key",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let key = keyToDelete {
                    deleteKey(key)
                }
                keyToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                keyToDelete = nil
            }
        } message: {
            if let key = keyToDelete {
                Text("Are you sure you want to delete '\(key.name)' from Keychain? Connections using this key will need a new key.")
            }
        }
    }

    // MARK: - Transfers Tab

    @ViewBuilder
    private var transfersTab: some View {
        Form {
            Section {
                Picker("Concurrent transfers:", selection: Bindable(transferSettings).maxConcurrentTransfers) {
                    ForEach(1...8, id: \.self) { count in
                        Text("\(count) \(count == 1 ? "stream" : "streams")").tag(count)
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text("Controls how many files are uploaded or downloaded simultaneously when transferring directories or multiple files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }

    // MARK: - SSH Keys Tab

    @ViewBuilder
    private var sshKeysTab: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SSH Keys")
                        .font(.headline)
                    Text("Private keys are encrypted and stored securely in macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingImportKeySheet = true
                } label: {
                    Label("Import Key…", systemImage: "plus")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if sshKeys.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("No SSH Keys Added")
                        .font(.headline)
                    Text("Import private keys to connect securely to remote SFTP servers.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Import SSH Key…") {
                        showingImportKeySheet = true
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                List {
                    ForEach(sshKeys) { key in
                        HStack(spacing: 12) {
                            Image(systemName: "key.fill")
                                .font(.title2)
                                .foregroundStyle(.blue)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(key.name)
                                        .font(.body)
                                        .fontWeight(.medium)
                                    Text(key.keyType)
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.12))
                                        .foregroundStyle(.blue)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                Text(key.shortFingerprint)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            Spacer()

                            if let pub = key.publicKeyString {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(pub, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Copy Public Key")
                            }

                            Button(role: .destructive) {
                                keyToDelete = key
                                showingDeleteConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .help("Delete Key from Keychain")
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    // MARK: - Known Hosts Tab

    @ViewBuilder
    private var knownHostsTab: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Known Hosts")
                        .font(.headline)
                    Text("Server host keys saved during previous connections.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if knownHosts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("No Known Hosts")
                        .font(.headline)
                    Text("Server keys are automatically remembered when you connect.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                List {
                    ForEach(knownHosts) { host in
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(host.identifier)
                                    .font(.body)
                                    .fontWeight(.medium)
                                Text(host.fingerprint)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            Button(role: .destructive) {
                                KnownHostsManager.shared.removeHost(identifier: host.identifier)
                                reloadKeys()
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .help("Forget this host key")
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("If a server was reinstalled and its host key changed (causing a MITM warning), delete it here to reconnect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        }
    }

    // MARK: - Security Tab

    @ViewBuilder
    private var securityTab: some View {
        Form {
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
            } footer: {
                if isEnabled {
                    Text("The app always requires authentication on launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }

    // MARK: - Helpers

    private func reloadKeys() {
        sshKeys = SSHKeyStorageService.shared.getAllKeys()
        knownHosts = KnownHostsManager.shared.allHosts().map {
            KnownHostEntry(identifier: $0.identifier, fingerprint: $0.fingerprint)
        }
    }

    private func deleteKey(_ key: SSHKeyItem) {
        try? SSHKeyStorageService.shared.deleteKey(id: key.id)
        reloadKeys()
    }
}

#Preview {
    SettingsView()
}

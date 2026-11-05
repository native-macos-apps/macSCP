//
//  ImportKeySheet.swift
//  macSCP
//
//  Sheet for importing an SSH private key into App Keychain
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportKeySheet: View {
    let onKeyImported: (SSHKeyItem) -> Void
    let onCancel: () -> Void

    @State private var importSource: ImportSource = .file
    @State private var keyName: String = ""
    @State private var rawKeyContent: String = ""
    @State private var selectedFilePath: String = ""
    @State private var inspectError: String? = nil
    @State private var inspectedMetadata: SSHKeyParser.KeyMetadata? = nil
    @State private var isSaving: Bool = false
    @State private var errorMessage: String? = nil

    enum ImportSource: String, CaseIterable {
        case file = "From File"
        case paste = "Paste Key"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Import SSH Private Key")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Form {
                Section {
                    Picker("Source", selection: $importSource) {
                        ForEach(ImportSource.allCases, id: \.self) { source in
                            Text(source.rawValue).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 4)
                }

                if importSource == .file {
                    Section("Private Key File") {
                        HStack {
                            TextField("File path", text: $selectedFilePath)
                                .textFieldStyle(.roundedBorder)
                                .disabled(true)

                            Button("Browse...") {
                                browseForFile()
                            }
                        }
                    }
                } else {
                    Section("Paste Private Key Text") {
                        TextEditor(text: $rawKeyContent)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 120)
                            .onChange(of: rawKeyContent) { _, newValue in
                                validateKey(newValue)
                            }
                    }
                }

                // Inspection info card
                if let meta = inspectedMetadata {
                    Section("Key Details") {
                        LabeledContent("Type", value: meta.keyType)
                        LabeledContent("Fingerprint", value: meta.fingerprint)
                            .textSelection(.enabled)

                        TextField("Key Name in App", text: $keyName)
                            .textFieldStyle(.roundedBorder)
                    }
                } else if let inspectError = inspectError {
                    Section {
                        Label(inspectError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                if let errorMessage = errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)

                Button("Import Key") {
                    saveKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(inspectedMetadata == nil || isSaving)
            }
            .padding()
        }
        .frame(width: 500, height: 460)
    }

    // MARK: - Actions

    private func browseForFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")

        if panel.runModal() == .OK, let url = panel.url {
            selectedFilePath = url.path
            if keyName.isEmpty {
                keyName = url.lastPathComponent
            }

            do {
                let data = try Data(contentsOf: url)
                guard let content = String(data: data, encoding: .utf8) else {
                    inspectError = "File is not valid UTF-8 text."
                    inspectedMetadata = nil
                    return
                }
                rawKeyContent = content
                validateKey(content)
            } catch {
                inspectError = "Failed to read file: \(error.localizedDescription)"
                inspectedMetadata = nil
            }
        }
    }

    private func validateKey(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            inspectError = nil
            inspectedMetadata = nil
            return
        }

        do {
            let meta = try SSHKeyParser.inspectKey(from: trimmed)
            inspectedMetadata = meta
            inspectError = nil
            if keyName.isEmpty {
                keyName = meta.keyType + " Key"
            }
        } catch {
            inspectedMetadata = nil
            inspectError = error.localizedDescription
        }
    }

    private func saveKey() {
        guard inspectedMetadata != nil else { return }
        isSaving = true
        errorMessage = nil

        do {
            let item = try SSHKeyStorageService.shared.saveKey(
                name: keyName.isEmpty ? "SSH Key" : keyName,
                privateKeyContent: rawKeyContent
            )
            isSaving = false
            onKeyImported(item)
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }
}

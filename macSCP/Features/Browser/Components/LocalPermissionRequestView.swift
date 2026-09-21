//
//  LocalPermissionRequestView.swift
//  macSCP
//
//  Friendly onboarding view requesting App Sandbox permission for the local Home directory
//

import SwiftUI
import AppKit

struct LocalPermissionRequestView: View {
    var viewModel: FileBrowserViewModel

    var body: some View {
        VStack(spacing: 22) {
            // Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.18), .cyan.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)

                Image(systemName: "house.circle.fill")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.blue)
            }

            // Title & Description
            VStack(spacing: 8) {
                Text("Access Your Home Folder")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Because macSCP runs in Apple's App Sandbox, one-time permission is required to browse files in your Home directory (~).\n\nAfter granting access, macSCP will remember it automatically.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 380)
            }

            // Action Buttons
            VStack(spacing: 12) {
                Button {
                    grantHomeAccess()
                } label: {
                    Label("Grant Access to Home…", systemImage: "house.fill")
                        .font(.system(size: 13, weight: .medium))
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    Task {
                        await viewModel.navigateTo(LocalFileRepository.downloadsDirectory)
                    }
                } label: {
                    Label("Browse Downloads Instead", systemImage: "arrow.down.circle")
                        .font(.system(size: 12, weight: .regular))
                        .frame(minWidth: 200)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    chooseAnotherFolder()
                } label: {
                    Label("Choose Another Folder…", systemImage: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func grantHomeAccess() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Grant Access"
        panel.message = "Select your Home folder to allow macSCP to browse your files"
        panel.directoryURL = URL(fileURLWithPath: LocalFileRepository.userHomeDirectory)

        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try LocalBookmarkService.shared.saveBookmark(for: url)
                    Task {
                        await viewModel.navigateTo(url.path)
                    }
                } catch {
                    logError("Failed to save security-scoped bookmark: \(error)", category: .app)
                    Task {
                        await viewModel.navigateTo(url.path)
                    }
                }
            }
        }
    }

    private func chooseAnotherFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Folder"
        panel.directoryURL = URL(fileURLWithPath: LocalFileRepository.userHomeDirectory)

        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try LocalBookmarkService.shared.saveBookmark(for: url)
                } catch {
                    logError("Failed to save bookmark for custom folder: \(error)", category: .app)
                }
                Task {
                    await viewModel.navigateTo(url.path)
                }
            }
        }
    }
}

//
//  CommanderPaneHeaderView.swift
//  macSCP
//
//  Header bar for each pane in the dual-pane Commander view (Transmit 5 style)
//

import SwiftUI

struct CommanderPaneHeaderView: View {
    @Bindable var commanderViewModel: CommanderViewModel
    let pane: CommanderPaneState

    @State private var isShowingSearch = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // Source Selector Menu
                sourcePickerMenu

                Spacer(minLength: 4)

                if pane.browserViewModel == nil {
                    // Servers mode: Search input on the right
                    serverSearchBar
                } else {
                    // Actions
                    actionButtons
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.bar)

            if isShowingSearch, let browserVM = pane.browserViewModel {
                Divider()
                searchBar(for: browserVM)
            }

            Divider()
        }
    }

    // MARK: - Source Selector Menu

    @ViewBuilder
    private var sourcePickerMenu: some View {
        switch pane.contentType {
        case .servers:
            Button {
                commanderViewModel.switchToLocal(in: pane.position)
            } label: {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Switch to Local Mac")

        case .local:
            HStack(spacing: 6) {
                Button {
                    commanderViewModel.switchToServers(in: pane.position)
                } label: {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Disconnect and return to Servers")

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 2)

                Text("Local Mac")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }

        case .remote(let conn):
            HStack(spacing: 6) {
                Button {
                    commanderViewModel.disconnect(in: pane.position)
                } label: {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Disconnect")

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 2)

                Text(conn.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 4) {
            if let browserVM = pane.browserViewModel {
                // New Folder
                Button {
                    browserVM.isShowingNewFolderSheet = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Folder")

                // Hidden files toggle
                Button {
                    browserVM.showHiddenFiles.toggle()
                } label: {
                    Image(systemName: browserVM.showHiddenFiles ? "eye.fill" : "eye.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(browserVM.showHiddenFiles ? Color.accentColor : Color.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(browserVM.showHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files")

                // Search toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isShowingSearch.toggle()
                        if isShowingSearch {
                            isSearchFocused = true
                        }
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(isShowingSearch ? Color.accentColor : Color.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Search in Pane")

                // Quick Look toggle
                Button {
                    browserVM.toggleQuickLook()
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 12))
                        .foregroundStyle(browserVM.isShowingQuickLook ? Color.accentColor : Color.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Toggle Preview Panel")

                // Refresh
                Button {
                    Task { await browserVM.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
        }
    }

    // MARK: - Server Search Bar (Servers Mode)

    private var serverSearchBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Search servers…", text: Bindable(pane).serverSearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))

            if !pane.serverSearchText.isEmpty {
                Button {
                    pane.serverSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
        .frame(maxWidth: 200)
    }

    // MARK: - Search Bar

    private func searchBar(for browserVM: FileBrowserViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))

            TextField("Search in current directory…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }

            Button("Done") {
                withAnimation {
                    isShowingSearch = false
                    searchText = ""
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.03))
    }
}

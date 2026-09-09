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

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 2)

                // Navigation Controls (if in file browser)
                if let browserVM = pane.browserViewModel {
                    navigationButtons(for: browserVM)

                    Divider()
                        .frame(height: 16)
                        .padding(.horizontal, 2)

                    // Path / Breadcrumb Bar
                    BreadcrumbView(
                        components: browserVM.pathComponents,
                        onNavigate: { path in
                            Task { await browserVM.navigateTo(path) }
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Servers mode: Search input directly in header (saves 1 whole row!)
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
                    .frame(maxWidth: 240)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 4)

                // Actions
                actionButtons
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

    private var sourcePickerMenu: some View {
        Menu {
            Button {
                commanderViewModel.switchToLocal(in: pane.position)
            } label: {
                Label("Local Mac", systemImage: "laptopcomputer")
            }

            Button {
                commanderViewModel.switchToServers(in: pane.position)
            } label: {
                Label("Servers", systemImage: "server.rack")
            }

            if !commanderViewModel.connectionListViewModel.connections.isEmpty {
                Divider()

                Menu("Connect to...") {
                    ForEach(commanderViewModel.connectionListViewModel.connections) { connection in
                        Button {
                            commanderViewModel.connect(to: connection, in: pane.position)
                        } label: {
                            Label(connection.name, systemImage: connection.connectionType.iconName)
                        }
                    }
                }
            }

            if case .remote = pane.contentType {
                Divider()
                Button(role: .destructive) {
                    commanderViewModel.disconnect(in: pane.position)
                } label: {
                    Label("Disconnect", systemImage: "power")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: pane.contentType.iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)

                Text(pane.contentType.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Navigation Buttons

    @ViewBuilder
    private func navigationButtons(for browserVM: FileBrowserViewModel) -> some View {
        HStack(spacing: 2) {
            Button {
                Task { await browserVM.goBack() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!browserVM.canGoBack)
            .help("Back")

            Button {
                Task { await browserVM.goForward() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!browserVM.canGoForward)
            .help("Forward")

            Button {
                Task { await browserVM.goUp() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!browserVM.canGoUp)
            .help("Enclosing Folder")
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
                }
                .buttonStyle(.plain)
                .help("Toggle Preview Panel")
            }

            // Refresh
            Button {
                if let browserVM = pane.browserViewModel {
                    Task { await browserVM.refresh() }
                } else {
                    Task { await commanderViewModel.connectionListViewModel.loadData() }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
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

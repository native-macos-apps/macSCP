//
//  CommanderPaneView.swift
//  macSCP
//
//  Container view for a single Commander pane
//

import SwiftUI

struct CommanderPaneView: View {
    @Bindable var commanderViewModel: CommanderViewModel
    let pane: CommanderPaneState

    private var isActive: Bool {
        commanderViewModel.activePanePosition == pane.position
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pane Header
            CommanderPaneHeaderView(
                commanderViewModel: commanderViewModel,
                pane: pane
            )

            // Pane Content
            Group {
                if let browserVM = pane.browserViewModel {
                    CommanderFileBrowserPaneView(
                        viewModel: browserVM,
                        commanderViewModel: commanderViewModel,
                        pane: pane
                    )
                } else {
                    CommanderServersPaneView(
                        commanderViewModel: commanderViewModel,
                        pane: pane
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isActive ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .onTapGesture {
            commanderViewModel.activePanePosition = pane.position
        }
    }
}

//
//  SwiftTermRepresentable.swift
//  macSCP
//
//  NSViewRepresentable wrapper around SwiftTerm's AppKit TerminalView.
//

import SwiftUI
import AppKit
import SwiftTerm

struct SwiftTermRepresentable: NSViewRepresentable {
    @Bindable var viewModel: TerminalViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> TerminalView {
        let terminalView = TerminalView(frame: .zero)
        terminalView.terminalDelegate = context.coordinator
        terminalView.font = NSFont.monospacedSystemFont(ofSize: viewModel.fontSize, weight: .regular)
        terminalView.nativeForegroundColor = NSColor(calibratedWhite: 0.92, alpha: 1.0)
        terminalView.nativeBackgroundColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
        terminalView.caretColor = NSColor(calibratedWhite: 0.92, alpha: 0.85)
        terminalView.optionAsMetaKey = true

        context.coordinator.terminalView = terminalView
        context.coordinator.bindCallbacks()

        // Focus the terminal once attached to its window
        DispatchQueue.main.async {
            terminalView.window?.makeFirstResponder(terminalView)
        }

        return terminalView
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.viewModel = viewModel
        context.coordinator.bindCallbacks()

        let currentSize = nsView.font.pointSize
        if abs(currentSize - viewModel.fontSize) > 0.1 {
            nsView.font = NSFont.monospacedSystemFont(ofSize: viewModel.fontSize, weight: .regular)
        }
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        var viewModel: TerminalViewModel
        weak var terminalView: TerminalView?

        init(viewModel: TerminalViewModel) {
            self.viewModel = viewModel
        }

        func bindCallbacks() {
            viewModel.onOutput = { [weak self] bytes in
                guard let terminalView = self?.terminalView, !bytes.isEmpty else { return }
                terminalView.feed(byteArray: bytes[...])
            }

            viewModel.onClearScreen = { [weak self] in
                guard let terminalView = self?.terminalView else { return }
                // CSI 3 J (clear scrollback) + CSI 2 J (clear screen) + CSI H (cursor home)
                terminalView.feed(text: "\u{1b}[3J\u{1b}[2J\u{1b}[H")
            }
        }

        // MARK: - TerminalViewDelegate

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor [weak self] in
                self?.viewModel.resize(cols: newCols, rows: newRows)
            }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {
            Task { @MainActor [weak self] in
                self?.viewModel.updateTitle(title)
            }
        }

        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // Optional OSC 7 update; no-op for now
        }

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            Task { @MainActor [weak self] in
                self?.viewModel.sendInput(bytes)
            }
        }

        nonisolated func scrolled(source: TerminalView, position: Double) {}

        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            Task { @MainActor in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }

        nonisolated func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
            Task { @MainActor in
                request.openDefault()
            }
        }
    }
}
